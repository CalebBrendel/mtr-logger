from __future__ import annotations

import argparse
import asyncio
import ipaddress
import sys
import time
from typing import Dict, List, Optional, Tuple

from rich.live import Live
from rich.panel import Panel
from rich.console import Group

# local modules
from .tracer import resolve_tracer, run_tracer_round
from .stats import Circuit
from .render import build_table, console
from .util import (
    resolve_host,
    default_log_dir,
    ensure_dir,
    timestamp_filename,
    now_local_str,
    atomic_write_text,
)
from .export import format_text_report


# ---------------------------
# Helpers
# ---------------------------

def is_ip_literal(text: str) -> bool:
    try:
        ipaddress.ip_address(text)
        return True
    except Exception:
        return False


def dns_mode_auto_from_target(target: str) -> str:
    """
    If the target looks like an IP, 'auto' behaves as DNS OFF for display.
    If it's a hostname, 'auto' behaves as DNS ON for display.
    """
    return "off" if is_ip_literal(target) else "on"


def should_ignore_for_alert(addr: Optional[str]) -> bool:
    """
    Ignore unresponsive ('*') hops (and None) for alert emission.
    """
    if not addr:
        return True
    if addr.strip() == "*":
        return True
    return False


def format_alert_lines(circuit: Circuit) -> List[str]:
    """
    Build alert lines from current Circuit state.
    We log a line for every hop that has any loss (>0), skipping star hops.
    """
    lines: List[str] = []
    ts = now_local_str("%-I:%M:%S%p")  # 12-hour time like 1:02:11PM
    for ttl in sorted(circuit.hops):
        hop = circuit.hops[ttl]
        lost = max(0, hop.sent - hop.recv)
        if lost > 0 and not should_ignore_for_alert(hop.address):
            lines.append(f"❌ Packet loss detected on hop {ttl} at {ts} - {lost} packets were lost")
    return lines


# ---------------------------
# Main async loop
# ---------------------------

async def mtr_loop(
    target: str,
    interval: float,
    probes: int,
    timeout: float,
    proto: str,
    fps: int,
    use_ascii: bool,
    use_alt_screen: bool,
    dns_mode: str,
    duration: Optional[int],
    count: Optional[int],
    max_hops: int,
    wide: bool,
    export_path: Optional[str],
) -> Optional[str]:
    """
    Returns the path to a written report if export_path is set; otherwise None.
    """
    # Resolve traceroute binary
    tr_path = resolve_tracer()

    # Resolve target (and decide display name via dns mode)
    # resolve_host should return an object with .ip and .display
    resolved = resolve_host(target, dns_mode if dns_mode != "auto" else dns_mode_auto_from_target(target))
    display_target = resolved.display

    circuit = Circuit()
    started = time.perf_counter()

    # Live (interactive) setup
    live_renderable = build_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
    live_ctx: Optional[Live] = None
    if sys.stdout.isatty():
        # Use alternate screen only if requested and a TTY
        live_ctx = Live(
            live_renderable,
            console=console,
            refresh_per_second=max(1, int(fps)),
            transient=False,
            screen=use_alt_screen,
        )

    rounds_done = 0
    out_path: Optional[str] = None

    # Helper to perform one tracer round
    async def one_round() -> None:
        nonlocal circuit

        # Run one traceroute round
        rtts_by_ttl, addr_by_ttl, _ok = await run_tracer_round(
            tr_path, resolved.ip, max_hops, timeout, proto, probes
        )

        # Update circuit stats
        for ttl, samples in rtts_by_ttl.items():
            circuit.update_hop_samples(ttl, addr_by_ttl.get(ttl), samples)

        # Update on-screen content (table first, alerts panel below)
        if live_ctx is not None:
            table = build_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
            alerts = format_alert_lines(circuit)
            if alerts:
                panel = Panel("\n".join(alerts), title="Alerts", border_style="red")
                group = Group(table, panel)
                live_ctx.update(group)
            else:
                live_ctx.update(table)

    # Run loop
    try:
        if live_ctx is not None:
            live_ctx.__enter__()

        # Duration or count driven loop
        if duration is not None:
            end_at = started + float(duration)
            while time.perf_counter() < end_at:
                t0 = time.perf_counter()
                await one_round()
                dt = time.perf_counter() - t0
                # Pace with interval (never negative)
                await asyncio.sleep(max(0.0, float(interval) - dt))
                rounds_done += 1
        else:
            # count-based (default to keep going if None, but we wire a default from CLI)
            target_rounds = count if count is not None else 1
            while rounds_done < target_rounds:
                t0 = time.perf_counter()
                await one_round()
                dt = time.perf_counter() - t0
                await asyncio.sleep(max(0.0, float(interval) - dt))
                rounds_done += 1

    finally:
        if live_ctx is not None:
            live_ctx.__exit__(None, None, None)

    # Export if requested
    if export_path:
        # Compose report text
        report_text = format_text_report(circuit, display_target)

        # Append alerts at the end of the report
        final_alerts = format_alert_lines(circuit)
        if final_alerts:
            report_text += "\n\nAlerts:\n" + "\n".join(final_alerts) + "\n"

        # Atomic write
        atomic_write_text(export_path, report_text)
        out_path = export_path

    return out_path


# ---------------------------
# CLI
# ---------------------------

def build_argparser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        description="MTR-like tracer/latency logger with live TUI and file export.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("target", help="Hostname or IP to trace")

    ap.add_argument("-i", "--interval", type=float, default=0.1, help="Delay between tracer rounds (seconds)")
    ap.add_argument("-p", "--probes", type=int, default=3, help="Probes per hop per round")
    ap.add_argument("--timeout", type=float, default=0.2, help="Per-probe timeout (seconds)")
    ap.add_argument("--proto", choices=["udp", "icmp", "tcp"], default="icmp", help="Probe protocol")

    ap.add_argument("--fps", type=int, default=6, help="Refresh rate for interactive TUI")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders")
    ap.add_argument("--no-screen", action="store_true", help="Do not use the alternate screen")
    ap.add_argument("--dns", choices=["auto", "on", "off"], default="auto", help="Name resolution mode for display")

    # stopping conditions
    ap.add_argument("--count", type=int, default=None, help="Stop after N rounds (ignored if --duration is set)")
    ap.add_argument("--duration", type=int, default=None, help="Total runtime (seconds)")

    # presentation
    ap.add_argument("--wide", action="store_true", help="Wider columns in table")

    # export
    ap.add_argument("--export", action="store_true", help="Write a text report when finished")
    ap.add_argument("--outfile", default="auto", help='Output file path or "auto" to timestamp in default log dir')
    ap.add_argument("--log-dir", type=str, help="Override log directory (defaults to ~/mtr/logs or %USERPROFILE%/mtr/logs)")

    # tracer caps: in case someone wants different max hops
    ap.add_argument("--max-hops", type=int, default=30, help="Max TTL (hops) to probe")

    return ap


def main(argv: Optional[List[str]] = None) -> Optional[str]:
    ap = build_argparser()
    args = ap.parse_args(argv)

    # Decide the output file path if exporting
    export_path: Optional[str] = None
    if args.export:
        if args.outfile and args.outfile != "auto":
            export_path = args.outfile
        else:
            log_dir = args.log_dir or default_log_dir()
            ensure_dir(log_dir)
            export_path = f"{log_dir}/{timestamp_filename(prefix='mtr', ext='txt')}"

    # TUI behavior flags
    use_alt_screen = not args.no_screen
    use_ascii = bool(args.ascii)

    # Run
    out_path = asyncio.run(
        mtr_loop(
            target=args.target,
            interval=float(args.interval),
            probes=int(args.probes),
            timeout=float(args.timeout),
            proto=args.proto,
            fps=int(args.fps),
            use_ascii=use_ascii,
            use_alt_screen=use_alt_screen,
            dns_mode=args.dns,
            duration=args.duration,
            count=args.count,
            max_hops=int(args.max_hops),
            wide=bool(args.wide),
            export_path=export_path,
        )
    )

    if out_path:
        print(out_path)

    return out_path


if __name__ == "__main__":
    raise SystemExit(main())
