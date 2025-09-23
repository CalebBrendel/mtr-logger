import argparse
import asyncio
import os
import sys
import time
from pathlib import Path

from .tracer import trace
from .stats import Circuit
from .render import render_table
from .util import resolve_host


async def mtr_loop(target, interval=1.0, max_hops=30, nprobes=3,
                   proto="icmp", dns_mode="auto", duration=None,
                   count=None, export=False, outfile=None,
                   ascii=False, no_screen=False, order=None,
                   wide=False, log_hourly=False, log_dir=None):

    circuit = Circuit()

    start_time = time.time()
    sent = 0

    while True:
        # break conditions
        if count and sent >= count:
            break
        if duration and (time.time() - start_time) >= duration:
            break

        hops = await trace(target, max_hops=max_hops, nprobes=nprobes,
                           proto=proto, dns_mode=dns_mode)

        circuit.update(hops)
        sent += 1

        table = render_table(circuit, order=order, wide=wide,
                             ascii=ascii, no_screen=no_screen)

        if not export:
            if not no_screen:
                # Interactive mode, clear screen
                sys.stdout.write("\033[H\033[J")
            print(table)
        else:
            # Export mode → file
            if outfile == "auto":
                ts = time.strftime("%m-%d-%Y-%H-%M-%S")
                base = Path.home() / "mtr" / "logs"
                base.mkdir(parents=True, exist_ok=True)
                outfile_path = base / f"mtr-{ts}.txt"
            else:
                outfile_path = Path(outfile)

            with open(outfile_path, "w") as f:
                f.write(table + "\n")

        if interval:
            await asyncio.sleep(interval)

    return circuit


def main(argv=None):
    ap = argparse.ArgumentParser(prog="mtr-logger")

    ap.add_argument("target", help="Target host or IP address")
    ap.add_argument("-i", "--interval", type=float, default=1.0,
                    help="Interval between probes in seconds")
    ap.add_argument("--max-hops", type=int, default=30,
                    help="Maximum number of hops")
    ap.add_argument("-p", "--probes", type=int, default=3,
                    help="Probes per hop")
    ap.add_argument("--proto", choices=["icmp", "udp", "tcp"],
                    default="icmp", help="Probe protocol")
    ap.add_argument("--dns", choices=["auto", "on", "off"],
                    default="auto", help="DNS resolution mode")
    ap.add_argument("--fps", type=int, default=6,
                    help="TUI refresh rate (interactive only)")
    ap.add_argument("--ascii", action="store_true",
                    help="Use ASCII borders (less flicker)")
    ap.add_argument("--no-screen", action="store_true",
                    help="Disable alternate screen")
    ap.add_argument("--count", type=int,
                    help="Stop after sending COUNT probes")
    ap.add_argument("--duration", type=int,
                    help="Stop after running DURATION seconds")
    ap.add_argument("--order", choices=["loss", "avg", "best", "wrst", "snt"],
                    help="Sort order for display/export")
    ap.add_argument("--wide", action="store_true",
                    help="Wide output (don’t truncate addresses)")
    ap.add_argument("--export", action="store_true",
                    help="Export logs to file instead of live TUI")
    ap.add_argument("--outfile", type=str, default=None,
                    help="Export file path (use 'auto' for timestamped)")
    ap.add_argument("--log-hourly", action="store_true",
                    help="Log every hour to timestamped file automatically")
    ap.add_argument(
        "--log-dir", type=str,
        help="Override log directory (defaults to ~/mtr/logs or %%USERPROFILE%%/mtr/logs)"
    )

    args = ap.parse_args(argv)

    try:
        asyncio.run(
            mtr_loop(
                args.target,
                interval=args.interval,
                max_hops=args.max_hops,
                nprobes=args.probes,
                proto=args.proto,
                dns_mode=args.dns,
                duration=args.duration,
                count=args.count,
                export=args.export or args.outfile or args.log_hourly,
                outfile=args.outfile,
                ascii=args.ascii,
                no_screen=args.no_screen,
                order=args.order,
                wide=args.wide,
                log_hourly=args.log_hourly,
                log_dir=args.log_dir,
            )
        )
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

run = main
