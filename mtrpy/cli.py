from __future__ import annotations
import argparse
import asyncio
import ipaddress
from time import perf_counter
from pathlib import Path
from typing import Optional, List
from rich.live import Live

from .tracer import trace, Hop
from .stats import Circuit
from .render import build_table, console
from .export import render_report
from .util import default_log_dir, ensure_dir, timestamp_filename


def _collapse_at_destination(hops: List[Hop], target_ip: Optional[str] = None) -> List[Hop]:
    """
    Stop at the first occurrence of the destination; drop any duplicate trailing hops.
    """
    if not target_ip:
        return hops
    out: List[Hop] = []
    for h in hops:
        out.append(h)
        # Support both address (IP) and display (hostname/IP)
        if (h.address and h.address == target_ip) or (getattr(h, "display", None) == target_ip):
            break
    return out


def _looks_like_ip(s: str) -> bool:
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False


async def mtr_loop(
    target: str,
    interval: float = 1.0,
    max_hops: int = 30,
    nprobes: int = 1,
    probe_timeout: float = 2.0,
    proto: str = "udp",
    fps: float = 6.0,
    ascii_mode: bool = False,
    use_screen: bool = True,
    dns_mode: str = "auto",  # "auto" | "on" | "off"
) -> Circuit:
    started = perf_counter()
    circuit = Circuit()

    dns_names = (not _looks_like_ip(target)) if dns_mode == "auto" else (dns_mode == "on")

    # Initial sample
    hops = await trace(
        target, max_hops=max_hops, nprobes=nprobes, timeout=probe_timeout, proto=proto, dns_names=dns_names
    )
    hops = _collapse_at_destination(hops)
    for h in hops:
        name = getattr(h, "display", h.address)
        circuit.update_hop_samples(h.ttl, name, h.rtts_ms)

    with Live(
        build_table(circuit, target, started, ascii_mode=ascii_mode),
        console=console,
        refresh_per_second=fps,
        screen=use_screen,
    ) as live:
        while True:
            t0 = perf_counter()

            hops = await trace(
                target, max_hops=max_hops, nprobes=nprobes, timeout=probe_timeout, proto=proto, dns_names=dns_names
            )
            hops = _collapse_at_destination(hops)
            for h in hops:
                name = getattr(h, "display", h.address)
                circuit.update_hop_samples(h.ttl, name, h.rtts_ms)

            live.update(build_table(circuit, target, started, ascii_mode=ascii_mode))
            await asyncio.sleep(max(0.0, interval - (perf_counter() - t0)))


async def export_once(circuit: Circuit, outfile: Optional[Path], order: str, wide: bool) -> Path:
    text = render_report(circuit, order=order, wide=wide)
    if outfile is None or str(outfile).lower() == "auto":
        outdir = ensure_dir(default_log_dir())
        outfile = outdir / timestamp_filename()
    outfile.write_text(text)
    return outfile


async def run_export_session(
    target: str,
    count: int,
    interval: float,
    order: str,
    wide: bool,
    outfile: Optional[str],
    max_hops: int = 30,
    nprobes: int = 1,
    probe_timeout: float = 2.0,
    proto: str = "udp",
    dns_mode: str = "auto",
    duration: float = 0.0,  # NEW: wall-clock seconds to sample before exporting (overrides --count)
) -> int:
    """
    Export a snapshot after either:
      - a fixed number of cycles (like mtr -c), OR
      - a fixed wall-clock duration (--duration), which takes precedence.
    """
    circuit = Circuit()
    dns_names = (not _looks_like_ip(target)) if dns_mode == "auto" else (dns_mode == "on")

    if duration and duration > 0:
        end_at = perf_counter() + duration
        while True:
            t0 = perf_counter()
            hops = await trace(
                target, max_hops=max_hops, nprobes=nprobes, timeout=probe_timeout, proto=proto, dns_names=dns_names
            )
            hops = _collapse_at_destination(hops)
            for h in hops:
                name = getattr(h, "display", h.address)
                circuit.update_hop_samples(h.ttl, name, h.rtts_ms)
            if perf_counter() >= end_at:
                break
            await asyncio.sleep(max(0.0, interval - (perf_counter() - t0)))
    else:
        cycles = max(1, count)
        for _ in range(cycles):
            t0 = perf_counter()
            hops = await trace(
                target, max_hops=max_hops, nprobes=nprobes, timeout=probe_timeout, proto=proto, dns_names=dns_names
            )
            hops = _collapse_at_destination(hops)
            for h in hops:
                name = getattr(h, "display", h.address)
                circuit.update_hop_samples(h.ttl, name, h.rtts_ms)
            await asyncio.sleep(max(0.0, interval - (perf_counter() - t0)))

    path = await export_once(circuit, Path(outfile) if outfile else None, order, wide)
    print(str(path))
    return 0


async def run_with_hourly_logs(
    target: str,
    interval: float,
    order: str,
    wide: bool,
    log_dir: Optional[str],
    max_hops: int = 30,
    nprobes: int = 1,
    probe_timeout: float = 2.0,
    proto: str = "udp",
    dns_mode: str = "auto",
) -> int:
    circuit = Circuit()
    dns_names = (not _looks_like_ip(target)) if dns_mode == "auto" else (dns_mode == "on")

    async def sampler():
        while True:
            t0 = perf_counter()
            hops = await trace(
                target, max_hops=max_hops, nprobes=nprobes, timeout=probe_timeout, proto=proto, dns_names=dns_names
            )
            hops = _collapse_at_destination(hops)
            for h in hops:
                name = getattr(h, "display", h.address)
                circuit.update_hop_samples(h.ttl, name, h.rtts_ms)
            await asyncio.sleep(max(0.0, interval - (perf_counter() - t0)))

    async def hourly_writer():
        while True:
            await asyncio.sleep(3600)
            outdir = ensure_dir(Path(log_dir) if log_dir else default_log_dir())
            path = outdir / timestamp_filename()
            path.write_text(render_report(circuit, order=order, wide=wide))

    await asyncio.gather(sampler(), hourly_writer())
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="mtrpy", description="Cross-platform MTR-style network diagnostic")
    ap.add_argument("target", help="Hostname or IP to trace")
    ap.add_argument("--interval", "-i", type=float, default=1.0, help="Seconds between refresh / sampling loop")
    ap.add_argument("--max-hops", "-m", type=int, default=30)
    ap.add_argument("--probes", "-p", type=int, default=1, help="Probes per hop for each sampling cycle")
    ap.add_argument("--timeout", "-t", type=float, default=2.0, help="Per-probe timeout (seconds)")
    ap.add_argument(
        "--proto",
        choices=["udp", "icmp", "tcp"],
        default="udp",
        help="Probe protocol (default: udp). icmp behaves like mtr; tcp often works well without root.",
    )
    ap.add_argument("--fps", type=float, default=6.0, help="UI refresh rate (frames per second)")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders (less flicker in VMs/SSH)")
    ap.add_argument("--no-screen", action="store_true", help="Don’t use the terminal’s alternate screen buffer")
    ap.add_argument(
        "--dns",
        choices=["auto", "on", "off"],
        default="auto",
        help="Hostname display: auto=hostnames for domain target, numeric for IP target; on=always names; off=numeric only.",
    )

    # Export / logging
    ap.add_argument("--count", "-c", type=int, default=0, help="Finite cycles before export (like mtr -c)")
    ap.add_argument("--duration", type=float, default=0.0, help="Wall-clock seconds to sample before exporting (overrides --count)")
    ap.add_argument("--order", "-o", type=str, default="LSRABW", help="Field order string, e.g., LSRABW")
    ap.add_argument("--wide", "-w", action="store_true", help="Wide report (text table)")
    ap.add_argument("--export", action="store_true", help="Run finite cycles and export a single report, then exit")
    ap.add_argument("--outfile", type=str, help="Export file path; use 'auto' for timestamped in default logs dir")

    # Hourly logging
    ap.add_argument("--log-hourly", action="store_true", help="Write a snapshot report every hour")
    ap.add_argument("--log-dir", type=str, help="Override log directory (defaults to ~/mtr/logs or %USERPROFILE%/mtr/logs)")

    args = ap.parse_args(argv)

    if args.export:
        return asyncio.run(
            run_export_session(
                args.target,
                args.count or 1,
                args.interval,
                args.order,
                args.wide,
                args.outfile,
                max_hops=args.max_hops,
                nprobes=args.probes,
                probe_timeout=args.timeout,
                proto=args.proto,
                dns_mode=args.dns,
                duration=args.duration,  # NEW
            )
        )

    if args.log_hourly:
        return asyncio.run(
            run_with_hourly_logs(
                args.target,
                args.interval,
                args.order,
                args.wide,
                args.log_dir,
                max_hops=args.max_hops,
                nprobes=args.probes,
                probe_timeout=args.timeout,
                proto=args.proto,
                dns_mode=args.dns,
            )
        )

    try:
        asyncio.run(
            mtr_loop(
                args.target,
                interval=args.interval,
                max_hops=args.max_hops,
                nprobes=args.probes,
                probe_timeout=args.timeout,
                proto=args.proto,
                fps=args.fps,
                ascii_mode=args.ascii,
                use_screen=not args.no_screen,
                dns_mode=args.dns,
            )
        )
    except KeyboardInterrupt:
        pass
    return 0


run = main
