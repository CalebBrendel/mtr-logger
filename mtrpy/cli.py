from __future__ import annotations

import argparse
import asyncio
import os
import socket
from time import perf_counter
from typing import Optional, Dict, Tuple, List

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

# ---------------- Reverse DNS cache ----------------
_rdns_cache: Dict[str, str] = {}

def is_ip(text: str) -> bool:
    try:
        socket.inet_pton(socket.AF_INET, text)
        return True
    except OSError:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, text)
        return True
    except OSError:
        return False

def reverse_dns(ip: str) -> str:
    if ip in _rdns_cache:
        return _rdns_cache[ip]
    name = ip
    try:
        name = socket.gethostbyaddr(ip)[0] or ip
    except Exception:
        name = ip
    _rdns_cache[ip] = name
    return name
# ---------------------------------------------------

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
    dns_mode: str,            # 'auto' | 'on' | 'off'
) -> Optional[str]:
    """
    Interactive loop if duration is None; otherwise run for 'duration' seconds and write a log file.
    Returns the log path in non-interactive mode; None in interactive.
    """
    resolved = resolve_host(target, dns_mode=dns_mode)  # has .ip and .display
    display_target = resolved.display
    dest_ip = resolved.ip
    tr_path = resolve_tracer()

    # Decide whether to show names or raw IPs for hop addresses:
    # - If user entered a hostname and dns_mode != 'off' -> show names (like mtr)
    # - If user entered an IP OR dns_mode == 'off' -> show IPs
    user_entered_was_ip = is_ip(target)
    want_names = (dns_mode != "off") and (not user_entered_was_ip)

    circuit = Circuit()
    started = perf_counter()
    dest_ttl_found: Optional[int] = None

    # Track printed alerts in interactive mode to avoid repeating same line every refresh
    # Signature: (ttl, lost_count_total_seen) -> already printed count
    printed_alerts: Dict[int, int] = {}

    from rich.live import Live
    table = build_table(circuit, display_target, started, ascii_mode=ascii_mode, wide=wide)

    out_path: Optional[str] = None
    end_time = None if duration is None else (perf_counter() + duration)

    try:
        with Live(table, console=console, auto_refresh=False, transient=False) as live:
            while True:
                if end_time is not None and perf_counter() >= end_time:
                    break

                try:
                    rtts_by_ttl, addr_by_ttl, _ok = await run_tracer_round(
                        tr_path, resolved.ip, max_hops, timeout, proto, probes
                    )
                except (asyncio.CancelledError, KeyboardInterrupt):
                    break

                # If we saw the destination, clamp at that TTL
                for ttl, addr in addr_by_ttl.items():
                    if addr == dest_ip:
                        if dest_ttl_found is None or ttl < dest_ttl_found:
                            dest_ttl_found = ttl

                # Fold round results into circuit
                for ttl, samples in rtts_by_ttl.items():
                    if dest_ttl_found is not None and ttl > dest_ttl_found:
                        continue
                    addr = addr_by_ttl.get(ttl)

                    # Apply reverse-DNS if desired
                    if addr and want_names:
                        addr = reverse_dns(addr)

                    circuit.update_hop_round(ttl, addr, probes, samples)

                # Rebuild and refresh the live table
                table = build_table(circuit, display_target, started, ascii_mode=ascii_mode, wide=wide)
                live.update(table, refresh=True)

                # ---- Interactive alerts (incremental lines) ----
                # For each hop currently showing loss, emit a deduped line
                # Count loss as (sent - recv) at this moment.
                now_str = now_local_str()
                for ttl, hop in circuit.hops.items():
                    lost = hop.sent - hop.recv
                    if lost > 0:
                        prev = printed_alerts.get(ttl, 0)
                        # only print when the cumulative lost has increased
                        if lost > prev:
                            console.print(
                                f"[bold red]❌ Packet loss detected on hop {ttl} at {now_str} - {lost} packets were lost[/]"
                            )
                            printed_alerts[ttl] = lost
                # ------------------------------------------------

                try:
                    await asyncio.sleep(interval)
                except asyncio.CancelledError:
                    break
    except KeyboardInterrupt:
        pass

    # Non-interactive export (atomic write at the end)
    if end_time is not None:
        from .export import write_text_report, alert_lines_for_losses

        log_dir = default_log_dir()
        ensure_dir(log_dir)
        out_path = os.path.join(log_dir, timestamp_filename(prefix="mtr", ext=".txt"))

        lines: List[str] = []
        lines.append(write_text_report(circuit))
        alerts = alert_lines_for_losses(circuit, now_local_str())
        if alerts:
            lines.append("")
            lines.append("Alerts:")
            lines.extend(alerts)

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
    ap.add_argument("--export", action="store_true", help="(compat) no-op; logs written when --duration is set")
    ap.add_argument("--outfile", default="auto", help="(compat) ignored")

    args = ap.parse_args(argv)

    out_path = asyncio.run(
        mtr_loop(
            target=args.target,
            interval=args.interval,
            max_hops=args.max_hops,
            probes=args.probes,
            timeout=args.timeout,
            proto=args.proto,
            ascii_mode=bool(args.ascii),
            wide=bool(args.wide),
            duration=args.duration,
            dns_mode=args.dns,
        )
    )
    if out_path:
        print(out_path)
    return 0
