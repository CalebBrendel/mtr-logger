from __future__ import annotations

import argparse
import asyncio
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .render import console, build_table
from .tracer import resolve_tracer, run_tracer_round
from .util import (
    ResolvedHost,
    ReverseDNSCache,
    default_log_dir,
    ensure_dir,
    now_local_str,
    resolve_host,
    timestamp_filename,
)

# ---------------- Data model ----------------

@dataclass
class HopStat:
    ttl: int
    address: Optional[str]
    sent: int = 0
    recv: int = 0
    best_ms: Optional[float] = None
    worst_ms: Optional[float] = None
    avg_ms: Optional[float] = None
    rtts: List[float] = field(default_factory=list)

    @property
    def loss_pct(self) -> float:
        if self.sent == 0:
            return 0.0
        return 100.0 * (1 - (self.recv / self.sent))


class Circuit:
    def __init__(self, started_at: float) -> None:
        self.hops: Dict[int, HopStat] = {}
        self.started_at = started_at
        self.filename = timestamp_filename()

    def ensure_hop(self, ttl: int, address: Optional[str]) -> HopStat:
        hop = self.hops.get(ttl)
        if not hop:
            hop = HopStat(ttl=ttl, address=address)
            self.hops[ttl] = hop
        if address and not hop.address:
            hop.address = address
        return hop

    def update_hop_samples(self, ttl: int, address: Optional[str], samples_ms: List[float]) -> None:
        hop = self.ensure_hop(ttl, address)
        sent = max(1, len(samples_ms)) if not samples_ms else len(samples_ms)
        hop.sent += sent
        for rtt in samples_ms:
            hop.recv += 1
            hop.rtts.append(rtt)
            hop.best_ms = rtt if hop.best_ms is None else min(hop.best_ms, rtt)
            hop.worst_ms = rtt if hop.worst_ms is None else max(hop.worst_ms, rtt)
        if hop.rtts:
            hop.avg_ms = sum(hop.rtts) / len(hop.rtts)


# ---------------- Core loop ----------------

async def mtr_loop(
    target: str,
    *,
    proto: str = "icmp",
    interval: float = 0.1,
    probes: int = 3,
    timeout: float = 0.2,
    duration: int = 0,                # 0 => continuous interactive
    ascii_mode: bool = False,
    dns_mode: str = "auto",           # auto|on|off
    max_hops: int = 12,               # tracer will stop at dest; we cap display
    ignore_star_hops_for_alerts: bool = True,
) -> Tuple[Circuit, str, List[Tuple[int, str, int, str]]]:
    """
    Run interactive or time-bound monitoring.
    Returns (circuit, display_target, alerts_seen).
    """
    resolved = resolve_host(target, dns_mode=dns_mode)   # sync
    display_target = resolved.display

    tr_path = resolve_tracer()
    if not tr_path:
        console.print("[red]ERROR:[/red] Could not find 'traceroute' on PATH.")
        sys.exit(2)

    started = time.perf_counter()
    circuit = Circuit(started_at=started)
    dns_cache = ReverseDNSCache()

    # (ttl, addr, lost, timestamp)
    alerts: List[Tuple[int, str, int, str]] = []
    last_alert_idx = 0

    # Track the last reported "lost" per hop to avoid duplicate alerts
    last_reported_lost: Dict[int, int] = {}

    async def one_round() -> None:
        nonlocal circuit, alerts
        rtts_by_ttl, addr_by_ttl, _ok = await run_tracer_round(
            tr_path, resolved.ip, max_hops, timeout, proto, probes
        )

        # Update circuit
        for ttl, samples in rtts_by_ttl.items():
            addr_raw = addr_by_ttl.get(ttl)
            circuit.update_hop_samples(ttl, addr_raw, samples)

        # Reverse DNS fill-in if requested
        if dns_mode != "off":
            for ttl, hop in list(circuit.hops.items()):
                if hop.address and hop.address != "*":
                    new_name = await dns_cache.lookup(hop.address)
                    hop.address = new_name or hop.address

        # Alerts: only when "lost" increases since last time
        for ttl, hop in sorted(circuit.hops.items()):
            if ignore_star_hops_for_alerts and (hop.address in (None, "*")):
                continue
            current_lost = hop.sent - hop.recv
            if current_lost <= 0:
                continue
            if current_lost > last_reported_lost.get(ttl, 0):
                last_reported_lost[ttl] = current_lost
                alerts.append((ttl, hop.address or "*", current_lost, now_local_str()))

    # Interactive print function
    def print_frame() -> None:
        table = build_table(circuit, display_target, circuit.started_at, ascii_mode=ascii_mode, wide=False)
        console.clear()
        console.print(table)
        # print any new alerts below table
        if last_alert_idx < len(alerts):
            for ttl, addr, lost, ts in alerts[last_alert_idx:]:
                console.print(f"❌ Packet loss detected on hop {ttl} ({addr}) at {ts} - {lost} packets lost")

    # Run
    if duration <= 0:
        # Interactive continuous
        try:
            while True:
                await one_round()
                print_frame()
                # we have printed everything up to current len(alerts)
                nonlocal_last = len(alerts)  # local variable to satisfy mypy thinking
                nonlocal_last  # no-op
                # update outer variable
                nonlocal last_alert_idx
                last_alert_idx = len(alerts)
                await asyncio.sleep(interval)
        except (asyncio.CancelledError, KeyboardInterrupt):
            # final frame with any alerts we haven't shown yet
            print_frame()
            return circuit, display_target, alerts
    else:
        # Timed run (non-interactive) — just loop for duration, no live printing
        try:
            deadline = time.perf_counter() + duration
            while time.perf_counter() < deadline:
                await one_round()
                await asyncio.sleep(interval)
        except (asyncio.CancelledError, KeyboardInterrupt):
            pass
        return circuit, display_target, alerts


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mtr-logger", description="Fast MTR-style path monitor/logger.")
    p.add_argument("target", help="Target hostname or IP (e.g., google.ca)")
    p.add_argument("--proto", choices=["icmp", "tcp", "udp"], default="icmp")
    p.add_argument("-i", "--interval", type=float, default=0.1, help="Interval between rounds (s)")
    p.add_argument("-p", "--probes", type=int, default=3, help="Probes per hop per round")
    p.add_argument("--timeout", type=float, default=0.2, help="Per-probe timeout (s)")
    p.add_argument("--duration", type=int, default=0, help="Seconds to run; 0 = interactive continuous")
    p.add_argument("--dns", choices=["auto", "on", "off"], default="auto", help="Reverse DNS policy")
    p.add_argument("--ascii", action="store_true", help="Use ASCII borders in TUI")
    p.add_argument("--export", action="store_true", help="Write a text log at the end (non-interactive mode)")
    p.add_argument("--outfile", default="auto", help="'auto' = timestamp in ~/mtr/logs, or explicit path")
    p.add_argument("--max-hops", type=int, default=12, help="Max hops to probe (passed to traceroute)")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    from .export import write_text_report

    args = build_arg_parser().parse_args(argv)

    try:
        circuit, display_target, alerts = asyncio.run(
            mtr_loop(
                args.target,
                proto=args.proto,
                interval=args.interval,
                probes=args.probes,
                timeout=args.timeout,
                duration=args.duration,
                ascii_mode=args.ascii,
                dns_mode=args.dns,
                max_hops=args.max_hops,
            )
        )
    except KeyboardInterrupt:
        # Should be rare now, but keep a hard guard to avoid tracebacks
        return 0

    # If interactive (duration==0): we already printed; nothing to export
    if args.duration <= 0:
        return 0

    # Non-interactive: write report (atomic handled in export.write_text_report)
    outdir = default_log_dir()
    if args.outfile != "auto":
        outdir = Path(args.outfile).expanduser().resolve().parent
    path = write_text_report(circuit, display_target, alerts, outdir, ascii_mode=args.ascii)
    console.print(f"[green]Saved:[/green] {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
