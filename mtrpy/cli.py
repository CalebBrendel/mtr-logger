from __future__ import annotations

import argparse
import asyncio
import os
import re
import shlex
import signal
import sys
from time import perf_counter, time
from typing import Dict, List, Optional, Tuple

from .stats import Circuit, HopStat
from .render import build_table, render_table
from .util import (
    resolve_host,
    default_log_dir,
    ensure_dir,
    timestamp_filename,
    now_local_str,
)
from .export import write_text_report


# ---------- traceroute runner + parser ----------

_HOP_RE = re.compile(
    r"""
    ^\s*(?P<ttl>\d+)\s+                                   # hop number
    (?:
        (?P<addr>\S+)\s*(?:\((?P<ip>[\d\.]+)\))?          # "name (ip)" OR just "ip"
        |
        (?P<star>\*)                                      # or a lone "*"
    )
    (?P<rest>.*)$
    """,
    re.VERBOSE,
)

_RTT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*ms")


async def _kill_proc_tree(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is not None:
        return
    try:
        proc.terminate()
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(proc.wait(), timeout=1.0)
        return
    except asyncio.TimeoutError:
        pass
    try:
        proc.kill()
    except ProcessLookupError:
        pass


def _traceroute_args(
    tr_path: str,
    target_ip: str,
    proto: str,
    nprobes: int,
    timeout: float,
    max_ttl: int,
    dns_mode: str,
) -> List[str]:
    args = [tr_path, "-q", str(nprobes), "-w", f"{timeout:.2f}", "-m", str(max_ttl)]
    if dns_mode in ("off", "disable", "no", "0"):
        args.append("-n")
    # protocol selector (Linux traceroute)
    if proto == "icmp":
        args.append("-I")
    elif proto == "tcp":
        args.append("-T")
    elif proto == "udp":
        pass  # default
    else:
        raise ValueError(f"unknown proto: {proto}")
    args.append(target_ip)
    return args


def _parse_traceroute_output(
    text: str, prefer_name: bool
) -> Tuple[Dict[int, List[float]], Dict[int, str]]:
    """
    Returns:
      rtts_by_ttl: ttl -> [rtts...]
      addr_by_ttl: ttl -> best label to display
    """
    rtts_by_ttl: Dict[int, List[float]] = {}
    addr_by_ttl: Dict[int, str] = {}

    for line in text.splitlines():
        m = _HOP_RE.match(line)
        if not m:
            continue

        ttl = int(m.group("ttl"))
        star = m.group("star")
        addr = m.group("addr")
        ip = m.group("ip")
        rest = m.group("rest") or ""

        if star:
            # no response at this hop this round
            rtts_by_ttl.setdefault(ttl, [])
            addr_by_ttl.setdefault(ttl, "*")
            continue

        label: str
        if ip and addr:
            # "name (ip)" form
            label = addr if prefer_name else ip
        else:
            # just one token; could be ip
            label = addr or "*"

        samples = [float(x) for x in _RTT_RE.findall(rest)]
        rtts_by_ttl.setdefault(ttl, [])
        rtts_by_ttl[ttl].extend(samples)
        addr_by_ttl[ttl] = label

    return rtts_by_ttl, addr_by_ttl


async def run_traceroute_round(
    tr_path: str,
    target_ip: str,
    max_ttl: int,
    timeout: float,
    proto: str,
    nprobes: int,
    dns_mode: str,
) -> Tuple[Dict[int, List[float]], Dict[int, str], bool]:
    """
    Run a single traceroute, parse output, return (rtts_by_ttl, addr_by_ttl, ok).
    """
    args = _traceroute_args(tr_path, target_ip, proto, nprobes, timeout, max_ttl, dns_mode)
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        raise RuntimeError("traceroute not found on PATH")

    try:
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=float(timeout) + 2.5)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        await _kill_proc_tree(proc)
        return {}, {}, False

    out = out_b.decode("utf-8", "replace")
    # Some distros print to stderr; merge if stdout empty
    if not out:
        out = err_b.decode("utf-8", "replace")

    prefer_name = dns_mode in ("on", "auto")
    rtts_by_ttl, addr_by_ttl = _parse_traceroute_output(out, prefer_name=prefer_name)

    ok = proc.returncode == 0 or bool(rtts_by_ttl)
    return rtts_by_ttl, addr_by_ttl, ok


# ---------- main async loop ----------

async def mtr_loop(
    target: str,
    *,
    interval: float,
    max_hops: int,
    nprobes: int,
    timeout: float,
    proto: str,
    fps: int,
    use_ascii: bool,
    use_screen: bool,
    dns_mode: str,
    duration: Optional[float],
    export_path: Optional[str],
    log_hourly: bool,
    log_dir_override: Optional[str],
    order: str,
    wide: bool,
) -> Optional[str]:
    # Resolve target up front
    resolved = resolve_host(target, dns_mode=dns_mode)  # returns object with ip and display
    display_target = resolved.display or target

    # locate traceroute
    tr_path = None
    for cand in ("traceroute", "/usr/bin/traceroute", "/usr/sbin/traceroute"):
        if os.path.exists(cand) and os.access(cand, os.X_OK):
            tr_path = cand
            break
    if not tr_path:
        raise RuntimeError("No traceroute found on PATH")

    circuit = Circuit()
    started = perf_counter()
    end_at = None if duration is None else time() + float(duration)

    # simple screen handling: we print fresh table each frame
    def print_table():
        table = build_table(circuit, f"mtr-logger → {display_target}", started, ascii_mode=use_ascii)
        sys.stdout.write("\x1b[2J\x1b[H" if use_screen else "")  # clear screen if alt screen requested
        sys.stdout.write(render_table(table))
        sys.stdout.flush()

    # run loop
    last_frame = 0.0
    while True:
        # stop condition
        if end_at is not None and time() >= end_at:
            break

        # one traceroute round
        try:
            rtts_by_ttl, addr_by_ttl, ok = await run_traceroute_round(
                tr_path,
                resolved.ip,
                max_hops,
                timeout,
                proto,
                nprobes,
                dns_mode,
            )
        except RuntimeError as e:
            print(str(e), file=sys.stderr)
            break

        # update stats ONLY for TTLs we actually saw this round
        for ttl, samples in rtts_by_ttl.items():
            addr = addr_by_ttl.get(ttl)
            if samples:
                circuit.update_hop_samples(ttl, addr, samples)
            else:
                # a miss this round still counts as a sent probe burst with 0 recv
                circuit.update_hop_samples(ttl, addr, [])

        # draw at requested fps
        now = perf_counter()
        min_frame_gap = 1.0 / max(1, fps)
        if now - last_frame >= min_frame_gap:
            print_table()
            last_frame = now

        # pacing
        await asyncio.sleep(max(0.0, float(interval)))

    # Export if requested
    if export_path or log_hourly:
        # pick dir
        if export_path and export_path != "auto":
            out_path = export_path
            ensure_dir(os.path.dirname(out_path))
        else:
            base_dir = log_dir_override or default_log_dir()
            ensure_dir(base_dir)
            fname = timestamp_filename(prefix="mtr-", suffix=".txt")
            out_path = os.path.join(base_dir, fname)
        write_text_report(out_path, circuit, display_target)
        return out_path

    return None


# ---------- CLI ----------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="mtr-logger",
        description="Cross-platform MTR-style tracer built on system traceroute.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("target", help="Hostname or IP to trace")
    ap.add_argument("--interval", "-i", type=float, default=0.1, help="Seconds between rounds")
    ap.add_argument("--max-hops", type=int, default=30, help="Max hops (traceroute -m)")
    ap.add_argument("--probes", "-p", type=int, default=3, help="Probes per hop (traceroute -q)")
    ap.add_argument("--timeout", type=float, default=0.2, help="Per-probe timeout (traceroute -w)")
    ap.add_argument("--proto", choices=["udp", "icmp", "tcp"], default="icmp", help="Probe protocol")
    ap.add_argument("--fps", type=int, default=6, help="Refresh rate for interactive display")
    ap.add_argument("--ascii", action="store_true", help="Use ASCII borders")
    ap.add_argument("--no-screen", action="store_true", help="Disable alternate/cleared screen effect")
    ap.add_argument("--dns", choices=["auto", "on", "off"], default="auto", help="Reverse DNS for hops")
    ap.add_argument("--count", type=int, default=None, help="(deprecated) number of rounds; use --duration instead")
    ap.add_argument("--duration", type=float, default=None, help="Run for N seconds and exit")
    ap.add_argument("--order", default="ttl", help="(reserved) row ordering")
    ap.add_argument("--wide", action="store_true", help="Wide layout hint")
    ap.add_argument("--export", action="store_true", help="Write a text report when done")
    ap.add_argument("--outfile", default="auto", help='Path or "auto" to write reports')
    ap.add_argument("--log-hourly", action="store_true", help="Internal: hourly cron export")
    ap.add_argument("--log-dir", default=None, help="Override log directory")

    args = ap.parse_args(argv)

    # Back-compat: translate --count to --duration ~= count * interval
    duration = args.duration
    if duration is None and args.count:
        duration = float(args.count) * float(args.interval)

    try:
        path = asyncio.run(
            mtr_loop(
                args.target,
                interval=float(args.interval),
                max_hops=int(args.max_hops),
                nprobes=int(args.probes),
                timeout=float(args.timeout),
                proto=args.proto,
                fps=int(args.fps),
                use_ascii=bool(args.ascii),
                use_screen=not bool(args.no_screen),
                dns_mode=args.dns,
                duration=duration,
                export_path=(args.outfile if args.export else None),
                log_hourly=bool(args.log_hourly),
                log_dir_override=args.log_dir,
                order=args.order,
                wide=bool(args.wide),
            )
        )
    except KeyboardInterrupt:
        # graceful stop on Ctrl+C
        return 130
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if path:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
