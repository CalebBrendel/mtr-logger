from __future__ import annotations

import argparse
import asyncio
import os
from time import perf_counter
from typing import Optional

from .stats import Circuit
from .tracer import resolve_tracer, run_tracer_round
from .render import build_table, console
from .util import (
    resolve_host,
    default_log_dir,
    ensure_dir,
    timestamp_filename,
    now_local_str,
)

async def mtr_loop(
    target: str,
    interval: float,
    max_hops: int,
    probes: int,
    timeout: float,
    proto: str,
    ascii_mode: bool,
    wide: bool,
    duration: Optional[int],  # seconds; None => interactive forever
    dns_mode: str,
) -> Optional[str]:
    """
    Interactive loop if duration is None; otherwise run for 'duration' seconds and write a log file.
    Returns the log path in non-interactive mode; None in interactive.
    """
    resolved = resolve_host(target, dns_mode=dns_mode)  # has .ip and .display
    display_target = resolved.display
    dest_ip = resolved.ip
    tr_path = resolve_tracer()

    circuit = Circuit()
    started = perf_counter()

    # remember the first TTL that matched the destination; ignore higher TTLs afterwards
    dest_ttl_found: Optional[int] = None

    from rich.live import Live
    table = build_table(circuit, display_target, started, ascii_mode=ascii_mode, wide=wide)

    out_path: Optional[str] = None
    end_time = None if duration is None else (perf_counter() + duration)

    try:
        with Live(table, console=console, auto_refresh=False, transient=False) as live:
            while True:
                # stop condition for non-interactive
                if end_time is not None and perf_counter() >= end_time:
                    break

                # one tracer round
                rtts_by_ttl, addr_by_ttl, _ok = await run_tracer_round(
                    tr_path, resolved.ip, max_hops, timeout, proto, probes
                )

                # if we see the destination IP, lock the path length
                for ttl, addr in addr_by_ttl.items():
                    if addr == dest_ip:
                        if dest_ttl_found is None or ttl < dest_ttl_found:
                            dest_ttl_found = ttl

                # decide which TTLs to apply this round:
                # - only TTLs that produced samples (prevents phantom rows)
                # - if dest_ttl_found, ignore any TTLs beyond it (no post-destination rows)
                for ttl, samples in rtts_by_ttl.items():
                    if not samples:
                        continue
                    if dest_ttl_found is not None and ttl > dest_ttl_found:
                        continue
                    addr = addr_by_ttl.get(ttl)
                    circuit.update_hop_samples(ttl, addr, samples)

                # refresh interactive table
                table = build_table(circuit, display_target, started, ascii_mode=ascii_mode, wide=wide)
                live.update(table, refresh=True)

                # sleep until next round (wall clock)
                try:
                    await asyncio.sleep(interval)
                except asyncio.CancelledError:
                    break
    except KeyboardInterrupt:
        # clean exit on Ctrl+C (no traceback)
        pass

    # non-interactive export when duration was set
    if end_time is not None:
        from .export import write_text_report, alert_lines_for_losses

        log_dir = default_log_dir()
        ensure_dir(log_dir)
        out_path = os.path.join(log_dir, timestamp_filename(prefix="mtr", ext=".txt"))

        lines = []
        lines.append(write_text_report(circuit))
        alerts = alert_lines_for_losses(circuit, now_local_str())
        if alerts:
            lines.append("")
            lines.append("Alerts:")
            lines.extend(alerts)

        # atomic write
        tmp_path = out_path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines).rstrip() + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, out_path)

    return out_path

def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        description="Lightweight MTR-style tracer/logger (wraps system traceroute).",
    )
    ap.add_argument("target", help="Destination host or IP")
    ap.add_argument("--interval", "-i", type=float, default=0.1, help="Seconds between rounds (default 0.1)")
    ap.add_argument("--max-hops", type=int, default=30, help="Max TTL to probe (default 30)")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Probes per hop (default 3)")
    ap.add_argument("--timeout", type=float, default=0.2, help="Per-probe timeout seconds (default 0.2)")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="Interactive refresh FPS (unused but kept)")
    ap.add_argument("--ascii", action="store_true", help="ASCII borders instead of rounded")
    ap.add_argument("--no-screen", action="store_true", help="Don’t use alternate screen (keeps scrollback)")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto", help="DNS display behavior")
    ap.add_argument("--count", type=int, help="(deprecated) use --duration")
    ap.add_argument("--duration", type=int, help="Run non-interactive for N seconds and export a log")
    ap.add_argument("--order", choices=("ttl", "loss", "avg"), default="ttl")
    ap.add_argument("--wide", action="store_true", help="Wider table layout")
    ap.add_argument("--export", action="store_true", help="(kept for compatibility) — no-op; logs are written if --duration used")
    ap.add_argument("--outfile", default="auto", help="(kept for compatibility)")

    args = ap.parse_args(argv)

    use_ascii = bool(args.ascii)
    wide = bool(args.wide)
    duration = args.duration

    out_path = asyncio.run(
        mtr_loop(
            target=args.target,
            interval=args.interval,
            max_hops=args.max_hops,
            probes=args.probes,
            timeout=args.timeout,
            proto=args.proto,
            ascii_mode=use_ascii,
            wide=wide,
            duration=duration,
            dns_mode=args.dns,
        )
    )

    if out_path:
        print(out_path)
    return 0
