# src/mtrpy/cli.py
from __future__ import annotations

import argparse
import asyncio
import time
from pathlib import Path
from typing import Optional

from .pinger import ping_host
from .stats import Circuit
from .tracer import trace
from .render import render_table  # ASCII-friendly table renderer
from .export import render_report
from .util import (
    default_log_dir,
    ensure_dir,
    auto_outfile_path,
    resolve_host,
)

# ---------------- CLI + runtime ----------------

async def mtr_loop(
    target: str,
    *,
    interval: float = 1.0,
    max_hops: int = 30,
    nprobes: int = 3,
    timeout: float = 5.0,
    proto: str = "icmp",
    dns_mode: str = "auto",  # passed to display only (trace() doesn't take it)
    fps: int = 6,
    use_ascii: bool = True,
    use_screen: bool = True,
    duration: Optional[int] = None,
    export_path: Optional[str] = None,
    export_order: str = "LSRABW",
    wide: bool = False,
) -> Optional[str]:
    """
    Main loop: resolve + trace once, then continuously ping each hop, updating Circuit.
    If duration is set, run for that many seconds then export a report and return its path.
    """
    resolved = resolve_host(target)
    display_target = resolved.input if dns_mode != "off" else resolved.ip

    # initial trace (NOTE: tracer.trace does NOT accept dns_mode)
    hops = await trace(
        resolved.ip,
        max_hops=max_hops,
        nprobes=nprobes,
        timeout=timeout,
        proto=proto,
    )

    circuit = Circuit(hops=hops)
    started = time.perf_counter()

    next_frame = 0.0
    end_time = None if duration is None else (time.perf_counter() + float(duration))

    while True:
        # ping all known hops once per cycle
        await asyncio.gather(
            *[ping_host(h, proto=proto, timeout=timeout) for h in circuit.hops]
        )

        # interactive rendering unless suppressed
        if use_screen:
            now = time.perf_counter()
            if now >= next_frame:
                table_text = render_table(circuit, display_target, started, ascii_mode=use_ascii)
                print("\x1b[2J\x1b[H", end="")  # clear screen & home
                print(table_text, end="")
                if fps > 0:
                    next_frame = now + (1.0 / fps)

        # duration control (used by cron/export)
        if end_time is not None and time.perf_counter() >= end_time:
            if export_path is not None:
                path = await export_report(
                    circuit, display_target, export_path, order=export_order, wide=wide
                )
                return path
            return None

        await asyncio.sleep(max(0.01, float(interval)))

async def export_report(
    circuit: Circuit,
    target_display: str,
    outfile: str,
    *,
    order: str = "LSRABW",
    wide: bool = False,
) -> str:
    """
    Write a plain-text report of the current circuit state.
    Supports outfile == 'auto' to write to the per-user log directory with timestamped name.
    Returns the path written.
    """
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

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="mtrpy",
        description="Cross-platform MTR-like tracer/pinger/logger.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("target", help="Hostname or IP to trace")
    ap.add_argument("--interval", "-i", type=float, default=1.0, help="Seconds between ping rounds")
    ap.add_argument("--max-hops", type=int, default=30, help="Maximum hops to probe")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Probes per TTL during trace")
    ap.add_argument("--timeout", type=float, default=5.0, help="Per-probe timeout seconds")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="Interactive refresh rate (frames per second)")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders/clear; stable over SSH/VMs")
    ap.add_argument("--no-screen", action="store_true", help="Disable interactive screen updates (batch mode)")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto", help="Hop name resolution for display")
    # logging / export controls
    ap.add_argument("--count", type=int, default=None, help="(Deprecated) number of ping rounds (use --duration instead)")
    ap.add_argument("--duration", type=int, default=None, help="Run for N seconds then exit (good for cron)")
    ap.add_argument("--order", default="LSRABW", help="Export column order (L,S,R,A,B,W)")
    ap.add_argument("--wide", action="store_true", help="Wider address column in export")
    ap.add_argument("--export", action="store_true", help="Write a text report at the end (batch mode)")
    ap.add_argument("--outfile", default="auto", help='Path for report; use "auto" for timestamped file in log dir')
    ap.add_argument("--log-hourly", action="store_true", help="(Deprecated) use cron-based scheduling instead")
    ap.add_argument("--log-dir", type=str, default=None, help="Override log directory (for export 'auto')")
    return ap

def main(argv: list[str] | None = None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)

    use_screen = not args.no_screen

    export_path: Optional[str] = None
    if args.export:
        export_path = args.outfile  # "auto" or explicit path

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
