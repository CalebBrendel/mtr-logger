from __future__ import annotations

import argparse
import asyncio
import ipaddress
import re
import socket
import time
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict

from .stats import Circuit, HopStat
from .tracer import trace, resolve_tracer           # initial discovery + tracer path
from .render import render_table                    # ASCII-friendly, returns a string
from .export import render_report
from .util import (
    default_log_dir,
    ensure_dir,
    auto_outfile_path,
    resolve_host,      # returns object with .input (user), .ip (resolved)
)

# ----- parse traceroute output (numeric) -----
LINE_RE = re.compile(r"^\s*(\d+)\s+(.+)$")
RTT_RE  = re.compile(r"(\d+(?:\.\d+)?)\s*ms")

async def run_traceroute_round(tr_path: str, target_ip: str, max_hops: int, timeout: float, proto: str) -> Dict[int, float]:
    """Run ONE traceroute (q=1) over all hops; return {ttl: rtt_ms} for responders."""
    cmd = [tr_path, "-n", "-q", "1", "-w", f"{max(0.3, float(timeout)):.1f}", "-m", str(max_hops)]
    p = (proto or "icmp").lower()
    if p == "icmp":
        cmd.append("-I")
    elif p == "tcp":
        cmd.append("-T")  # udp is default
    cmd.append(target_ip)

    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=float(timeout) + 2.0)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        finally:
            return {}

    text = (out_b or b"").decode("utf-8", "replace")
    rtts: Dict[int, float] = {}
    for line in text.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        ttl = int(m.group(1))
        if "*" in line:
            continue
        m2 = RTT_RE.search(line)
        if m2:
            try:
                rtts[ttl] = float(m2.group(1))
            except Exception:
                pass
    return rtts

# ----- DNS helpers -----
def _is_ip(s: str | None) -> bool:
    if not s: return False
    try:
        ipaddress.ip_address(s); return True
    except Exception:
        return False

async def _ptr_lookup(ip: str) -> Optional[str]:
    def _do():
        try:
            name, _aliases, _ips = socket.gethostbyaddr(ip)
            return name.rstrip(".")
        except Exception:
            return None
    return await asyncio.to_thread(_do)

class DNSCache:
    def __init__(self):
        self._map: Dict[str, Optional[str]] = {}
    def get(self, ip: str) -> Optional[str]:
        return self._map.get(ip)
    def set(self, ip: str, name: Optional[str]) -> None:
        self._map[ip] = name

# ----- main loop -----
async def mtr_loop(
    target: str,
    *,
    interval: float = 0.2,
    max_hops: int = 30,
    nprobes: int = 3,             # initial discovery only
    timeout: float = 0.7,         # small => faster rounds
    proto: str = "icmp",
    dns_mode: str = "auto",       # auto: hostname target => names, IP target => numeric
    fps: int = 6,
    use_ascii: bool = True,
    use_screen: bool = True,
    duration: Optional[int] = None,
    export_path: Optional[str] = None,
    export_order: str = "LSRABW",
    wide: bool = False,
) -> Optional[str]:
    resolved = resolve_host(target)   # .input, .ip
    target_was_ip = _is_ip(resolved.input)
    display_target = resolved.input if dns_mode != "off" else resolved.ip

    # traceroute availability
    try:
        tr_path = resolve_tracer()
    except Exception:
        tr_path = None
    if tr_path is None:
        raise RuntimeError("No 'traceroute' found; install it to run mtr-logger interactively.")

    # initial discovery: get TTLs + numeric addresses
    seed_hops = await trace(
        resolved.ip, max_hops=max_hops, nprobes=nprobes, timeout=timeout, proto=proto
    )

    circuit = Circuit()
    hopstats: List[HopStat] = []
    max_seen_ttl = 0
    for h in seed_hops:
        ttl = int(getattr(h, "ttl", 0) or 1)
        addr = getattr(h, "address", None)
        hs = HopStat(ttl=ttl, address=addr)
        circuit.hops[ttl] = hs
        hopstats.append(hs)
        max_seen_ttl = max(max_seen_ttl, ttl)

    # DNS display cache (PTR)
    dns_cache = DNSCache()
    should_resolve = (dns_mode == "on") or (dns_mode == "auto" and not target_was_ip)

    async def maybe_resolve_names():
        if not should_resolve:
            return
        targets: List[tuple[HopStat, str]] = []
        tasks = []
        for hs in hopstats:
            ip = hs.address
            if not _is_ip(ip):
                continue
            if ip in dns_cache._map:
                continue
            targets.append((hs, ip))
            tasks.append(_ptr_lookup(ip))
        if not tasks:
            return
        results = await asyncio.gather(*tasks, return_exceptions=True)
        for (hs, ip), name in zip(targets, results):
            hostname = None if isinstance(name, Exception) else name
            dns_cache.set(ip, hostname)
            if hostname:
                hs.address = hostname

    await maybe_resolve_names()

    started = time.perf_counter()
    next_frame = 0.0
    end_time = None if duration is None else (time.perf_counter() + float(duration))
    dns_refresh_tick = 0

    while True:
        # one traceroute round for all hops
        rtts = await run_traceroute_round(tr_path, resolved.ip, max_seen_ttl or max_hops, timeout, proto)

        # update stats
        for hs in hopstats:
            hs.sent += 1
            rtt = rtts.get(hs.ttl)
            if rtt is not None:
                hs.recv += 1
                hs.rtts.append(rtt)
                hs.best_ms = rtt if hs.best_ms is None else min(hs.best_ms, rtt)
                hs.worst_ms = rtt if hs.worst_ms is None else max(hs.worst_ms, rtt)
                hs.avg_ms = (sum(hs.rtts) / len(hs.rtts)) if hs.rtts else None

        # PTR refresh periodically
        dns_refresh_tick += 1
        if dns_refresh_tick >= max(1, int(2 / max(0.01, float(interval)))):
            dns_refresh_tick = 0
            await maybe_resolve_names()

        # render + ALWAYS print loss alerts each refresh
        if use_screen:
            now = time.perf_counter()
            if now >= next_frame:
                table_text = render_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
                print("\x1b[2J\x1b[H", end="")  # clear + home
                print(table_text, end="")

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
                    next_frame = now + (1.0 / fps)

        # duration/export
        if end_time is not None and time.perf_counter() >= end_time:
            if export_path is not None:
                path = await export_report(circuit, display_target, export_path, order=export_order, wide=wide)
                return path
            return None

        await asyncio.sleep(max(0.01, float(interval)))

# ----- export (batch) -----
async def export_report(
    circuit: Circuit,
    target_display: str,
    outfile: str,
    *,
    order: str = "LSRABW",
    wide: bool = False,
) -> str:
    if outfile == "auto":
        p = auto_outfile_path(default_log_dir(), prefix="mtr")
    else:
        p = Path(outfile)
        if not p.is_absolute():
            p = ensure_dir(default_log_dir()) / p.name
    p.parent.mkdir(parents=True, exist_ok=True)
    report = render_report(circuit, order=order, wide=wide)
    p.write_text(report)
    return str(p)

# ----- CLI -----
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        description="Cross-platform MTR-like tracer/pinger/logger.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("target", help="Hostname or IP to trace")
    ap.add_argument("--interval", "-i", type=float, default=0.2, help="Seconds between rounds")
    ap.add_argument("--max-hops", type=int, default=30, help="Maximum hops to probe")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Probes per TTL during initial trace")
    ap.add_argument("--timeout", type=float, default=0.7, help="Per-probe timeout seconds (smaller = faster rounds)")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp", help="Probe protocol for traceroute")
    ap.add_argument("--fps", type=int, default=6, help="Interactive refresh rate (frames per second)")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders/clear (stable over SSH/VMs)")
    ap.add_argument("--no-screen", action="store_true", help="Disable interactive screen updates (batch mode)")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto", help="DNS display policy")
    ap.add_argument("--duration", type=int, default=None, help="Run for N seconds then exit (good for cron)")
    ap.add_argument("--order", default="LSRABW", help="Export column order (L,S,R,A,B,W)")
    ap.add_argument("--wide", action="store_true", help="Wider address column in export")
    ap.add_argument("--export", action="store_true", help="Write a text report at the end (batch mode)")
    ap.add_argument("--outfile", default="auto", help='Path for report; use "auto" for timestamped file in log dir')
    ap.add_argument("--log-dir", type=str, default=None, help="Override log directory (for export 'auto')")
    return ap

def main(argv: List[str] | None = None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    use_screen = not args.no_screen
    export_path: Optional[str] = args.outfile if args.export else None
    try:
        path = asyncio.run(
            mtr_loop(
                args.target,
                interval=args.interval,
                max_hops=args.max_hops,
                nprobes=args.probes,
                timeout=args.timeout,
                proto=args.proto,
                dns_mode=args.dns,
                fps=args.fps,
                use_ascii=args.ascii,
                use_screen=use_screen,
                duration=args.duration,
                export_path=export_path,
                export_order=args.order,
                wide=args.wide,
            )
        )
        if path:
            print(path)
    except KeyboardInterrupt:
        return 130
    return 0

def run():
    raise SystemExit(main())
