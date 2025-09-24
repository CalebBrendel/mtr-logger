from __future__ import annotations

import argparse
import asyncio
import signal
import sys
from time import perf_counter
from typing import Dict, List, Tuple, Optional

from .tracer import resolve_tracer, run_tracer_round
from .stats import Circuit
from .render import console, build_table
from .util import resolve_host, default_log_dir, ensure_dir, timestamp_filename
from .export import write_text_report

from rich.live import Live


# -------------------- helpers --------------------

def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        description="Interactive MTR-like TUI + logging",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("target", help="Hostname or IP to trace (e.g. google.ca, 8.8.8.8)")

    ap.add_argument("-i", "--interval", type=float, default=0.1, help="Seconds between rounds")
    ap.add_argument("--timeout", type=float, default=0.2, help="Per-round subprocess timeout (sec)")
    ap.add_argument("--max-hops", type=int, default=30, help="Maximum TTL hops")
    ap.add_argument("-p", "--probes", type=int, default=3, help="Probes per TTL per round")
    ap.add_argument("--proto", choices=("udp", "icmp", "tcp"), default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="Live screen refresh rate")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII table borders")
    ap.add_argument("--no-screen", action="store_true", help="Disable alternate screen mode")
    ap.add_argument("--dns", choices=("auto", "on", "off"), default="auto", help="Name resolution mode")

    # termination controls
    ap.add_argument("--count", type=int, default=0, help="Stop after N rounds (0 = infinite)")
    ap.add_argument("--duration", type=float, default=0.0, help="Stop after seconds (0 = infinite)")

    # rendering options
    ap.add_argument("--order", choices=("linear",), default="linear", help="Row ordering (reserved)")
    ap.add_argument("--wide", action="store_true", help="Wider numeric columns")

    # logging options
    ap.add_argument("--export", action="store_true", help="Write a text report at end")
    ap.add_argument("--outfile", default="auto", help='Output path or "auto" to name by timestamp')
    ap.add_argument("--log-dir", type=str, help="Override log directory (defaults to ~/mtr/logs)")

    return ap.parse_args(argv)


def _should_quit(started: float, max_rounds: int, rounds_done: int, max_seconds: float) -> bool:
    if max_rounds > 0 and rounds_done >= max_rounds:
        return True
    if max_seconds > 0.0 and (perf_counter() - started) >= max_seconds:
        return True
    return False


def _collect_loss_events(circuit: Circuit) -> List[Tuple[int, int]]:
    """Return list of (ttl, lost_count) for any hop with loss > 0."""
    events: List[Tuple[int, int]] = []
    for row in circuit.rows():  # row has ttl, sent, recv, address, etc.
        if row.sent and (row.sent - row.recv) > 0:
            events.append((row.ttl, row.sent - row.recv))
    return events


# -------------------- core loop --------------------

async def mtr_loop(
    target: str,
    interval: float,
    timeout: float,
    max_hops: int,
    probes: int,
    proto: str,
    fps: int,
    use_ascii: bool,
    use_screen: bool,
    dns_mode: str,
    round_limit: int,
    duration_limit: float,
    export_flag: bool,
    outfile: str,
    log_dir_override: Optional[str],
    order: str,
    wide: bool,
) -> Optional[str]:
    # Resolve target (address + display name according to DNS mode)
    resolved = resolve_host(target, dns_mode=dns_mode)  # expects .ip and .display
    display_target = resolved.display

    tr_path = resolve_tracer()  # path to traceroute / tracert

    # TUI setup
    circuit = Circuit()
    started = perf_counter()
    table = build_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)

    # signal handling: allow Ctrl+C to stop cleanly
    stop = asyncio.Event()

    def _sigint(*_):
        stop.set()

    loop = asyncio.get_event_loop()
    try:
        loop.add_signal_handler(signal.SIGINT, _sigint)
    except NotImplementedError:
        # e.g. on Windows
        pass

    rounds_done = 0
    max_seen_ttl = max_hops

    # Live display
    with Live(
        table,
        console=console,
        refresh_per_second=max(1, int(fps)),
        transient=not use_screen,
        auto_refresh=False,
    ) as live:
        while True:
            # A single "round": run traceroute once with current max TTL
            try:
                rtts_by_ttl, ok = await asyncio.wait_for(
                    run_tracer_round(tr_path, resolved.ip, max_seen_ttl, timeout, proto, probes),
                    timeout=timeout + 5.0,  # outer guard
                )
            except asyncio.TimeoutError:
                rtts_by_ttl, ok = {}, False

            # Update the circuit with returned RTT samples
            # Expect rtts_by_ttl: {ttl: [rtt_ms, ...]} (empty list if no reply)
            for ttl in range(1, max_seen_ttl + 1):
                samples = rtts_by_ttl.get(ttl, [])
                # we don't have per-hop address text here (parsed from tracer module),
                # pass None so the row keeps its previous address (resolver/render can fill)
                circuit.update_hop_samples(ttl, None, samples)

            # Re-render table
            new_table = build_table(circuit, display_target, started, ascii_mode=use_ascii, wide=wide)
            live.update(new_table, refresh=True)

            rounds_done += 1
            if stop.is_set() or _should_quit(started, round_limit, rounds_done, duration_limit):
                break

            # pacing
            await asyncio.sleep(max(0.01, float(interval)))

    # export (write after loop ends)
    if export_flag:
        out_dir = log_dir_override or default_log_dir()
        ensure_dir(out_dir)
        if outfile == "auto":
            path = f"{out_dir}/{timestamp_filename(prefix='mtr', ext='.txt')}"
        else:
            path = outfile if outfile.startswith("/") else f"{out_dir}/{outfile}"

        loss_events = _collect_loss_events(circuit)
        final_path = write_text_report(path, circuit, display_target, started, loss_events)
        return final_path

    return None


# -------------------- entry --------------------

def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)

    # map CLI to loop params
    try:
        out_path = asyncio.run(
            mtr_loop(
                target=args.target,
                interval=float(args.interval),
                timeout=float(args.timeout),
                max_hops=int(args.max_hops),
                probes=int(args.probes),
                proto=str(args.proto),
                fps=int(args.fps),
                use_ascii=bool(args.ascii),
                use_screen=not bool(args.no_screen),
                dns_mode=str(args.dns),
                round_limit=int(args.count),
                duration_limit=float(args.duration),
                export_flag=bool(args.export),
                outfile=str(args.outfile),
                log_dir_override=args.log_dir,
                order=str(args.order),
                wide=bool(args.wide),
            )
        )
    except KeyboardInterrupt:
        return 130

    if out_path:
        # print the path so the setup script self-test can capture it
        print(out_path)
    return 0


def run() -> None:
    raise SystemExit(main())


if __name__ == "__main__":
    run()
