from __future__ import annotations

import asyncio
import os
import re
import time
from datetime import datetime
from typing import List, Tuple, Dict

from .stats import Circuit
from .render import render_table
from .export import export_report
from .util import resolve_host, default_log_dir, ensure_dir, timestamp_filename, which


# ---------- traceroute parsing ----------
LINE_RE = re.compile(r"^\s*(\d+)\s+(.+)$")
RTT_RE  = re.compile(r"(\d+(?:\.\d+)?)\s*ms")


async def run_traceroute_round(
    tr_path: str,
    target_ip: str,
    max_hops: int,
    timeout: float,
    proto: str,
    qpr: int,
) -> Tuple[Dict[int, List[float]], bool]:
    """
    Run ONE traceroute round (-q qpr) over all hops.

    Returns: (rtts_by_ttl, ok)
      - rtts_by_ttl: {ttl: [rtt_ms, ...]}   # ttl WILL be present even if list is empty (e.g., '* * *')
      - ok: True if at least one hop line was parsed; False if output unusable/empty
    """
    qpr = max(1, int(qpr))
    cmd = [tr_path, "-n", "-q", str(qpr), "-w", f"{max(0.3, float(timeout)):.1f}", "-m", str(max_hops)]
    p = (proto or "icmp").lower()
    if p == "icmp":
        cmd.append("-I")
    elif p == "tcp":
        cmd.append("-T")  # UDP is default
    cmd.append(target_ip)

    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        out_b, _err_b = await asyncio.wait_for(proc.communicate(), timeout=float(timeout) + 2.0)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        finally:
            return {}, False

    text = (out_b or b"").decode("utf-8", "replace")

    rtts: Dict[int, List[float]] = {}
    saw_any_line = False

    for line in text.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        ttl = int(m.group(1))
        saw_any_line = True
        # Ensure ttl key exists even if no RTTs (i.e., '* * *')
        rtts.setdefault(ttl, [])
        samples = [float(x) for x in RTT_RE.findall(line)]
        if samples:
            rtts[ttl].extend(samples)

    return rtts, saw_any_line


# ---------- main loop ----------
async def mtr_loop(
    target: str,
    interval: float = 0.2,
    max_hops: int = 30,
    timeout: float = 0.5,
    proto: str = "icmp",
    fps: int = 6,
    use_ascii: bool = True,
    use_screen: bool = True,
    dns_mode: str = "auto",
    queries_per_round: int = 3,
    export_path: str | None = None,
    export_order: str = "hop",
    wide: bool = False,
    duration: float | None = None,
) -> str | None:
    resolved = await resolve_host(target, mode=dns_mode)
    display_target = resolved.display
    circuit = Circuit()

    # traceroute binary
    tr_path = which("traceroute" if os.name != "nt" else "tracert")
    if not tr_path:
        raise RuntimeError("No traceroute/tracert found on PATH. Please install it.")

    # Initialize hop entries (1..max_hops)
    for ttl in range(1, max_hops + 1):
        circuit.update_hop_samples(ttl, None, [])

    started = time.perf_counter()
    next_frame = 0.0
    end_time = None if duration is None else (time.perf_counter() + float(duration))
    dns_refresh_tick = 0
    qpr = max(1, int(queries_per_round))
    max_seen_ttl = max_hops  # keep simple; traceroute prints full ladder anyway

    async def maybe_resolve_names():
        if dns_mode == "off":
            # do nothing
            return
        # Refresh PTR names for hops with IPs
        # Kept simple for robustness: reverse only if current address is an IP
        import socket
        for ttl in sorted(circuit.hops.keys()):
            hs = circuit.hops[ttl]
            addr = hs.address
            if not addr or addr == "*":
                continue
            # if it already looks like a name (letters), skip unless dns_mode=='on'
            if dns_mode == "auto" and any(c.isalpha() for c in addr):
                continue
            try:
                name = socket.gethostbyaddr(addr)[0]
                hs.address = name
            except Exception:
                # leave as IP
                pass

    while True:
        # Stop BEFORE starting a new round to avoid partial-bookkeeping at the end
        if end_time is not None and time.perf_counter() >= end_time:
            if export_path is not None:
                path = export_report(circuit, display_target, export_path, order=export_order, wide=wide)
                return path
            return None

        # one traceroute round for all hops
        rtts_by_ttl, ok = await run_traceroute_round(
            tr_path, resolved.ip, max_seen_ttl, timeout, proto, qpr
        )

        # Only count 'sent' for TTLs that actually appeared in output
        if ok:
            present_ttls = set(rtts_by_ttl.keys())
            for ttl in present_ttls:
                samples = rtts_by_ttl.get(ttl, [])
                # Note: address is unknown here; leave None (display '*' until DNS reverse happens)
                circuit.update_hop_samples(ttl, None, samples)
        # If not ok (no parseable lines), skip counting this round entirely

        # refresh DNS names periodically
        dns_refresh_tick += 1
        if dns_refresh_tick >= max(1, int(2 / max(0.01, float(interval)))):
            dns_refresh_tick = 0
            await maybe_resolve_names()

        # draw & live alerts
        if use_screen:
            now = time.perf_counter()
            if now >= next_frame:
                table_text = render_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
                print("\x1b[2J\x1b[H", end="")  # clear + home
                print(table_text, end="")
                # Alerts (restate each tick is fine)
                tstr = datetime.now().strftime("%I:%M:%S%p").lstrip("0")
                alerts: List[str] = []
                for ttl in sorted(circuit.hops.keys()):
                    hs = circuit.hops[ttl]
                    if hs.address in (None, "*"):
                        continue
                    lost = max(0, hs.sent - hs.recv)
                    if lost > 0:
                        alerts.append(f"❌ Packet loss detected on hop {ttl} at {tstr} - {lost} packets were lost")
                if alerts:
                    print("\n\nAlerts:")
                    for line in alerts:
                        print(line)
                if fps > 0:
                    next_frame = now + (1.0 / max(1, fps))

        await asyncio.sleep(max(0.01, float(interval)))


# ---------- CLI ----------
def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(prog="mtr-logger", description="Cross-platform MTR-like tracer logger")
    ap.add_argument("target", help="Hostname or IP to trace")
    ap.add_argument("--interval", "-i", type=float, default=0.1, help="Interval between rounds (seconds)")
    ap.add_argument("--max-hops", type=int, default=30, help="Maximum hops")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Probes per hop (per round)")
    ap.add_argument("--timeout", type=float, default=0.2, help="Probe timeout (seconds)")
    ap.add_argument("--proto", choices=["udp", "icmp", "tcp"], default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="TUI refresh rate (interactive)")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders in table")
    ap.add_argument("--no-screen", action="store_true", help="Disable screen updates; print once and exit")
    ap.add_argument("--dns", choices=["auto", "on", "off"], default="auto", help="Name resolution mode")
    ap.add_argument("--count", type=int, help="(Deprecated) Ignored; use --duration instead")
    ap.add_argument("--duration", type=float, help="Run for N seconds then exit (and export if requested)")
    ap.add_argument("--order", default="hop", help="Export order (unused; reserved)")
    ap.add_argument("--wide", action="store_true", help="Wider table")
    ap.add_argument("--export", action="store_true", help="Export report when stopping")
    ap.add_argument("--outfile", default="auto", help="Export path or 'auto' for ~/mtr/logs/mtr-<timestamp>.txt")
    args = ap.parse_args(argv)

    # resolve export path
    export_path = None
    if args.export:
        export_path = args.outfile if args.outfile != "auto" else "auto"

    # choose screen mode
    use_screen = not args.no_screen

    path = asyncio.run(
        mtr_loop(
            args.target,
            interval=args.interval,
            max_hops=args.max_hops,
            timeout=args.timeout,
            proto=args.proto,
            fps=args.fps,
            use_ascii=args.ascii,
            use_screen=use_screen,
            dns_mode=args.dns,
            queries_per_round=args.probes,
            export_path=export_path,
            export_order=args.order,
            wide=args.wide,
            duration=args.duration,
        )
    )

    if path:
        print(path)
    return 0
