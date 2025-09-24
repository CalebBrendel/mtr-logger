from __future__ import annotations
import asyncio
from argparse import ArgumentParser
from pathlib import Path
from time import perf_counter, sleep
from typing import Dict, Tuple, Optional

from rich.console import Console
from rich.live import Live

from .stats import Circuit
from .tracer import resolve_tracer, run_tracer_round
from .render import build_table, render_table
from .util import (
    resolve_host,
    default_log_dir,
    ensure_dir,
    timestamp_filename,
    now_local_str,
)
from .export import IncrementalReport


console = Console(color_system="standard", force_terminal=True)


# ------------- core async tracer loop helpers -------------


async def run_traceroute_round(
    tracer_bin: str,
    target_ip: str,
    max_ttl: int,
    timeout: float,
    proto: str,
    qpr: int,
) -> Tuple[Dict[int, list], bool]:
    """
    Run one traceroute pass. Returns (rtts_by_ttl, ok).
    rtts_by_ttl: dict of ttl -> list of RTT floats (ms) collected in this round.
    ok: True if the subprocess completed within timeout margin.
    """
    # Use the helper that builds/executes the subprocess and parses stdout
    try:
        rtts_by_ttl = await run_tracer_round(
            tracer_bin, target_ip, max_ttl=max_ttl, timeout=timeout, proto=proto, qpr=qpr
        )
        return rtts_by_ttl, True
    except asyncio.TimeoutError:
        return {}, False


async def mtr_loop(
    target: str,
    interval: float,
    max_hops: int,
    nprobes: int,
    timeout: float,
    proto: str,
    fps: int,
    use_ascii: bool,
    use_alt_screen: bool,
    wide: bool,
    dns_mode: str,
    duration: Optional[int],
    export_path: Optional[Path],
) -> Optional[Path]:
    started = perf_counter()
    resolved = resolve_host(target, dns_mode=dns_mode)
    display_target = resolved.display
    target_ip = resolved.ip

    # tracer binary
    tr_path = resolve_tracer()

    # circuit accumulator
    circuit = Circuit()

    # incremental exporter?
    inc: Optional[IncrementalReport] = None
    if export_path is not None:
        inc = IncrementalReport(export_path, display_target)
        # Initial header snapshot (empty stats)
        inc.append_snapshot(circuit, now_local_str(time_only=True))

    # state for per-round loss alerts
    prev_counts: Dict[int, Tuple[int, int]] = {}  # ttl -> (sent, recv)

    # Live console rendering setup
    refresh_per_sec = max(1, int(fps))
    table = build_table(circuit, display_target, started, ascii_mode=use_ascii)
    live_ctx = Live(
        table if not use_alt_screen else console.render(table),
        console=console,
        transient=False,
        refresh_per_second=refresh_per_sec,
        screen=use_alt_screen,
    )

    max_seen_ttl = max_hops
    end_time = None if duration is None else perf_counter() + float(duration)

    with live_ctx:
        while True:
            # end condition
            if end_time is not None and perf_counter() >= end_time:
                break

            # one traceroute pass
            rtts_by_ttl, ok = await run_traceroute_round(
                tr_path, target_ip, max_seen_ttl, timeout, proto, nprobes
            )

            # integrate samples into circuit
            for ttl, samples in rtts_by_ttl.items():
                addr = circuit.hops.get(ttl).address if ttl in circuit.hops else None
                # update with samples; if addr is None, it will be kept as None '*'
                circuit.update_hop_samples(ttl, addr, samples)

            # compute alerts: per-round packet loss deltas
            alerts = []
            for ttl, hop in circuit.hops.items():
                prev_sent, prev_recv = prev_counts.get(ttl, (0, 0))
                delta_sent = hop.sent - prev_sent
                delta_recv = hop.recv - prev_recv
                lost = max(0, delta_sent - delta_recv)
                prev_counts[ttl] = (hop.sent, hop.recv)

                # skip star/unknown address hops for alerts
                addr = hop.address or "*"
                if lost > 0 and addr != "*":
                    alerts.append(
                        f"❌ Packet loss detected on hop {ttl} at {now_local_str(time_only=True)} - {lost} packets were lost"
                    )

            # write incremental snapshot + alerts (tail-able)
            if inc is not None:
                inc.append_snapshot(circuit, now_local_str(time_only=True))
                if alerts:
                    inc.append_alerts(alerts)

            # update display
            # (re-resolve display_target if dns_mode='on' and addresses got names — optional)
            table = build_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
            live_ctx.update(table)

            # respect interval
            # If a round ran long, we still sleep (cannot go negative); keeps steady-ish pacing
            sleep_interval = max(0.0, float(interval))
            # asyncio-friendly small await to yield back to event loop
            await asyncio.sleep(sleep_interval)

    # finalize exporter
    if inc is not None:
        inc.close()
        return export_path
    return None


# ------------- CLI -------------


def main(argv: Optional[list] = None) -> int:
    ap = ArgumentParser(prog="mtr-logger")
    ap.add_argument("target", help="destination hostname or IP")
    ap.add_argument("--interval", "-i", type=float, default=0.1, help="seconds between rounds (default: 0.1)")
    ap.add_argument("--max-hops", type=int, default=30)
    ap.add_argument("--probes", "-p", type=int, default=3, help="probes per hop per round")
    ap.add_argument("--timeout", type=float, default=0.2, help="per-probe timeout (seconds)")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp")
    ap.add_argument("--fps", type=int, default=6, help="UI refresh rate (interactive)")
    ap.add_argument("--ascii", action="store_true", help="use ASCII borders")
    ap.add_argument("--no-screen", action="store_true", help="avoid alternate screen mode")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto")
    ap.add_argument("--count", type=int, help="(deprecated) total rounds; prefer --duration")
    ap.add_argument("--duration", type=int, help="run for N seconds then stop")
    ap.add_argument("--order", default="default", help="unused (compat)")
    ap.add_argument("--wide", action="store_true", help="wider table")
    ap.add_argument("--export", action="store_true", help="export (incremental) log to file")
    ap.add_argument("--outfile", help='path for export; use "auto" to pick ~/mtr/logs/mtr-<timestamp>.txt')

    args = ap.parse_args(argv)

    # figure export path
    export_path: Optional[Path] = None
    if args.export or args.outfile:
        if args.outfile and args.outfile != "auto":
            export_path = Path(args.outfile).expanduser()
            ensure_dir(export_path.parent)
        else:
            log_dir = default_log_dir()
            ensure_dir(log_dir)
            export_path = log_dir / timestamp_filename(prefix="mtr", ext=".txt")

    use_ascii = bool(args.ascii)
    use_alt_screen = not bool(args.no_screen)
    wide = bool(args.wide)

    # run
    path = asyncio.run(
        mtr_loop(
            args.target,
            interval=args.interval,
            max_hops=args.max_hops,
            nprobes=args.probes,
            timeout=args.timeout,
            proto=args.proto,
            fps=args.fps,
            use_ascii=use_ascii,
            use_alt_screen=use_alt_screen,
            wide=wide,
            dns_mode=args.dns,
            duration=args.duration,
            export_path=export_path,
        )
    )

    # print path at end for cron/self-test convenience
    if path is not None:
        print(path)
    return 0


def run():  # convenience
    raise SystemExit(main())


if __name__ == "__main__":
    run()
