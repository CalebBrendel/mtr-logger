from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
from contextlib import nullcontext

from rich.live import Live

from .util import (
    default_log_dir,
    ensure_dir,
    resolve_host,
    timestamp_filename,
    now_local_str,
)
from .render import render_table
from .stats import Circuit
from .tracer import resolve_tracer, run_tracer_round
from .export import write_text_report


async def mtr_loop(
    target: str,
    *,
    interval: float,
    duration: float,
    max_hops: int,
    probes: int,
    timeout: float,
    proto: str,
    dns_mode: str,
    fps: int,
    use_ascii: bool,
    use_screen: bool,
    export: bool,
    outfile: str | None,
    wide: bool,
) -> str | None:
    """
    Core async loop.
    Returns path to written report (if export=True), else None.
    """
    resolved = resolve_host(target, dns_mode=dns_mode)
    display_target = resolved.display

    tr_path = resolve_tracer()

    circuit = Circuit()
    started = time.perf_counter()
    deadline = started + float(duration)

    # Initial renderable
    table = render_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)

    # alternate screen context (or no-op)
    screen_ctx = (console.screen() if use_screen else nullcontext())  # type: ignore[name-defined]

    # Prepare Live with an initial Table
    with screen_ctx:
        with Live(table, console=console, refresh_per_second=fps):  # type: ignore[name-defined]
            # Loop until duration elapses
            while True:
                now = time.perf_counter()
                if now >= deadline:
                    break

                # One traceroute "round"
                rtts_by_ttl = await run_tracer_round(
                    tr_path,
                    resolved.ip,
                    max_ttl=max_hops,
                    timeout=float(timeout),
                    proto=proto,
                    qpr=probes,
                )

                # For each hop from 1..max_hops, add samples (or count as lost if no RTTs returned)
                for ttl in range(1, max_hops + 1):
                    samples = rtts_by_ttl.get(ttl, [])
                    if samples:
                        circuit.update_hop_samples(ttl, None, samples)
                    else:
                        # no replies for this TTL this round: count sent only
                        circuit.update_hop_samples(ttl, None, [])

                # Update interactive table
                new_table = render_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
                # Live.update requires a renderable (Table). Do NOT pass console.render / strings.
                Live.get_current().update(new_table)  # type: ignore[attr-defined]

                # Sleep to honor interval
                now2 = time.perf_counter()
                to_sleep = float(interval) - max(0.0, now2 - now)
                if to_sleep > 0:
                    await asyncio.sleep(to_sleep)

    # Export if requested
    if export:
        log_dir = default_log_dir()
        ensure_dir(log_dir)
        if outfile and outfile != "auto":
            out_path = os.fspath(os.path.join(log_dir, outfile))
        else:
            out_path = os.fspath(log_dir / timestamp_filename(prefix="mtr"))
        write_text_report(out_path, circuit, display_target, started)
        return out_path

    return None


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        description="Minimal MTR-style logger with interactive TUI and text export.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("target", help="Hostname or IP to trace")
    ap.add_argument("--interval", "-i", type=float, default=0.1, help="Interval between rounds (seconds)")
    ap.add_argument("--timeout", type=float, default=0.2, help="Per-probe timeout (seconds)")
    ap.add_argument("--max-hops", type=int, default=30, help="Maximum hops (max TTL)")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Queries per hop (traceroute -q)")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="Interactive refresh rate")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders")
    ap.add_argument("--no-screen", action="store_true", help="Disable alternate screen")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto", help="DNS display mode")
    ap.add_argument("--duration", type=float, default=120.0, help="Total run time (seconds)")

    # export / logging
    ap.add_argument("--export", action="store_true", help="Write a text report at the end")
    ap.add_argument("--outfile", default="auto", help='Output filename (or "auto" for timestamped)')

    # formatting
    ap.add_argument("--order", choices=("hop", "loss", "avg", "best", "wrst"), default="hop", help="Sort order")
    ap.add_argument("--wide", action="store_true", help="Wider table (if your terminal supports it)")

    return ap


def main(argv: list[str] | None = None) -> int:
    # Delay import here so console is available to mtr_loop
    global console  # rich Console from render.py
    from .render import console as _console  # import once
    console = _console

    ap = build_parser()
    args = ap.parse_args(argv)

    # Run loop
    out_path = asyncio.run(
        mtr_loop(
            args.target,
            interval=args.interval,
            duration=args.duration,
            max_hops=args.max_hops,
            probes=args.probes,
            timeout=args.timeout,
            proto=args.proto,
            dns_mode=args.dns,
            fps=args.fps,
            use_ascii=args.ascii,
            use_screen=not args.no_screen,
            export=args.export,
            outfile=args.outfile,
            wide=args.wide,
        )
    )

    if out_path:
        print(out_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
