from __future__ import annotations

import argparse
import asyncio
import os
import signal
import sys
import time
from typing import Dict, List, Optional, Tuple

from .util import (
    resolve_host,
    default_log_dir,
    ensure_dir,
    timestamp_filename,
    now_local_str,
)

# Prefer util.atomic_write_text if present; otherwise, safe local fallback.
try:
    from .util import atomic_write_text  # type: ignore
except Exception:  # pragma: no cover
    import tempfile

    def atomic_write_text(path: str, text: str) -> None:
        """Atomic text write: write temp in same dir, fsync, rename."""
        dirpath = os.path.dirname(path) or "."
        fd, tmppath = tempfile.mkstemp(prefix=".tmp", dir=dirpath)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmppath, path)
        finally:
            try:
                if os.path.exists(tmppath):
                    os.unlink(tmppath)
            except Exception:
                pass

from .stats import Circuit  # Circuit supports .update_hop_samples(...) and .rows()
from .tracer import resolve_tracer, run_tracer_round
from .render import console, build_table  # rich Console + Table factory

# Try to import the writer from export.py; if missing, provide a tiny fallback.
try:
    from .export import write_text_report  # type: ignore
except Exception:  # pragma: no cover
    def write_text_report(
        circuit: Circuit,
        target_display: str,
        log_dir: str,
        alerts_lines: List[str],
        outfile: Optional[str] = None,
        atomic_writer=atomic_write_text,
    ) -> str:
        """Minimal writer: fixed-width table plus Alerts: block."""
        ensure_dir(log_dir)
        name = outfile or timestamp_filename(prefix="mtr", ext=".txt")
        path = name if os.path.isabs(name) else os.path.join(log_dir, name)

        # Basic header
        lines: List[str] = []
        lines.append(" Hop  Address                                     Loss%  Snt  Recv   Avg  Best   Wrst")
        lines.append(" ---  ------------------------------------------  -----  ---  ----  ----  ----  -----")

        # Circuit.rows() yields tuples: (ttl, address, loss_pct, sent, recv, avg, best, worst)
        for ttl, addr, lp, snt, rcv, avg, best, wrst in circuit.rows():
            addr_s = addr or "*"
            lp_s = f"{int(round(lp, 0))}".rjust(5)
            s_s = str(snt).rjust(4)
            r_s = str(rcv).rjust(4)
            avg_s = "-" if avg is None else f"{avg:.1f}"
            best_s = "-" if best is None else f"{best:.1f}"
            wrst_s = "-" if wrst is None else f"{wrst:.1f}"
            lines.append(
                f"{str(ttl).rjust(3)}  {addr_s:<42}  {lp_s}  {s_s}  {r_s}  {avg_s:>4}  {best_s:>4}  {wrst_s:>5}"
            )

        if alerts_lines:
            lines.append("")
            lines.append("Alerts:")
            lines.extend(alerts_lines)

        text = "\n".join(lines) + "\n"
        atomic_writer(path, text)
        return path


# -------------- CLI helpers --------------

def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        add_help=True,
        description="Minimal MTR-style tracer/monitor with logging.",
    )
    ap.add_argument("target", help="Destination hostname or IP")
    ap.add_argument("--interval", "-i", type=float, default=0.2, help="Probe interval seconds (default: 0.2)")
    ap.add_argument("--max-hops", type=int, default=30, help="Max TTL to probe (default: 30)")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Probes per TTL per round (default: 3)")
    ap.add_argument("--timeout", type=float, default=0.2, help="Per-probe timeout seconds (default: 0.2)")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="Interactive refresh FPS (default: 6)")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII box drawing")
    ap.add_argument("--no-screen", action="store_true", help="Disable alternate screen")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto", help="DNS resolution mode")
    ap.add_argument("--count", type=int, default=0, help="Stop after N rounds (0 = unlimited)")
    ap.add_argument("--duration", type=int, default=0, help="Stop after N seconds (0 = unlimited)")
    ap.add_argument("--order", choices=("ttl", "loss"), default="ttl", help="Row order")
    ap.add_argument("--wide", action="store_true", help="Wider table")
    ap.add_argument("--export", action="store_true", help="Write a text report when done")
    ap.add_argument("--outfile", default="auto", help='Output filename or "auto" (default: auto)')
    ap.add_argument("--log-hourly", action="store_true", help="(cron helper) honor hh:00 windows")
    ap.add_argument("--log-dir", type=str, help="Override log directory (default in home)")
    return ap.parse_args(argv)


def _should_ignore_for_alerts(address: Optional[str]) -> bool:
    """Ignore unroutable/unknown hops for alerting by default."""
    if not address:
        return True
    addr = address.strip()
    if addr == "*" or addr == "":
        return True
    # Could add more heuristics later (e.g., RFC1918 + recv==0), but keep it simple.
    return False


# -------------- Core async loop --------------

async def mtr_loop(
    target: str,
    proto: str,
    interval: float,
    timeout: float,
    probes: int,
    max_hops: int,
    fps: int,
    use_ascii: bool,
    use_screen: bool,
    dns_mode: str,
    count: int,
    duration: int,
    order: str,
    wide: bool,
) -> Tuple[Circuit, str, List[str]]:
    """
    Returns: (circuit, target_display, alerts_lines)
    """
    # Resolve target early (ip + pretty display). util.resolve_host handles dns_mode semantics.
    resolved = await resolve_host(target, dns_mode=dns_mode)
    display_target = resolved.display

    tr_path = resolve_tracer()
    circuit = Circuit()

    # Alert tracking: cumulative lost per TTL
    last_lost_by_ttl: Dict[int, int] = {}
    alerts_lines: List[str] = []

    # Interactive screen
    # We keep the table re-render logic here; alerts are printed AFTER the table when we exit.
    from rich.live import Live

    started = time.perf_counter()
    rounds_done = 0

    # graceful stop flags
    stop_flag = False

    def _stop(*_a):
        nonlocal stop_flag
        stop_flag = True

    # register signals
    try:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, _stop)
            except NotImplementedError:
                pass
    except RuntimeError:
        pass

    # build once; we will update its rows via rebuild on each refresh
    table = build_table(circuit, f"mtr-logger → {display_target}", started, ascii_mode=use_ascii, wide=wide)

    refresh_delay = max(1.0 / max(1, fps), 0.05)

    async def one_round() -> None:
        nonlocal circuit, last_lost_by_ttl, alerts_lines
        # tracer returns: rtts_by_ttl: Dict[int, List[float]], addr_by_ttl: Dict[int, Optional[str]], ok: bool
        rtts_by_ttl, addr_by_ttl, _ok = await run_tracer_round(
            tr_path, resolved.ip, max_hops, timeout, proto, probes
        )

        # inject samples into circuit
        for ttl in range(1, max_hops + 1):
            samples = rtts_by_ttl.get(ttl, [])
            addr = addr_by_ttl.get(ttl)
            # Count 'sent' as number of probes; recv is len(samples)
            circuit.update_hop_samples(ttl, addr, samples)

        # Alert delta per hop
        for ttl, hop in circuit.hops.items():
            lost_now = max(hop.sent - hop.recv, 0)
            prev = last_lost_by_ttl.get(ttl, 0)
            inc = lost_now - prev
            last_lost_by_ttl[ttl] = lost_now
            if inc > 0 and not _should_ignore_for_alerts(hop.address):
                ts = now_local_str("%I:%M:%S%p").lstrip("0")  # '01:02:11PM' -> '1:02:11PM'
                alerts_lines.append(f"❌ Packet loss detected on hop {ttl} at {ts} - {inc} packets were lost")

    # interactive refresh loop
    async with Live(table, console=console, transient=False, refresh_per_second=fps, screen=not use_screen):
        while True:
            await one_round()
            # refresh table content by rebuilding from the new circuit
            table = build_table(
                circuit, f"mtr-logger → {display_target}", started, ascii_mode=use_ascii, wide=wide
            )
            # Live.update with refresh=True to force a draw
            console.print(table, end="\r")
            await asyncio.sleep(interval)

            rounds_done += 1
            if count > 0 and rounds_done >= count:
                break
            if duration > 0 and (time.perf_counter() - started) >= duration:
                break
            if stop_flag:
                break

    return circuit, display_target, alerts_lines


# -------------- Entry point --------------

def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)

    # Prep: log dir, outfile path
    log_dir = args.log_dir or default_log_dir()
    ensure_dir(log_dir)

    # Run loop
    circuit: Circuit
    display_target: str
    alerts: List[str]
    circuit, display_target, alerts = asyncio.run(
        mtr_loop(
            target=args.target,
            proto=args.proto,
            interval=float(args.interval),
            timeout=float(args.timeout),
            probes=int(args.probes),
            max_hops=int(args.max_hops),
            fps=int(args.fps),
            use_ascii=bool(args.ascii),
            use_screen=bool(args.no_screen) is False,
            dns_mode=args.dns,
            count=int(args.count),
            duration=int(args.duration),
            order=args.order,
            wide=bool(args.wide),
        )
    )

    # After interactive view ends, print Alerts under the table (if any)
    if alerts:
        console.print("\n[b]Alerts:[/b]")
        for line in alerts:
            console.print(line)

    # Export on demand (and from cron)
    if args.export:
        out_name = None if args.outfile == "auto" else args.outfile
        path = write_text_report(
            circuit=circuit,
            target_display=display_target,
            log_dir=log_dir,
            alerts_lines=alerts,
            outfile=out_name,
        )
        console.print(path)

    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
