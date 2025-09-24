from __future__ import annotations
import asyncio
import re
from typing import Dict, List, Optional

from .util import which, IS_WINDOWS

# Candidate tracer binaries by platform
TRACEROUTE_CMDS = [
    "traceroute",          # GNU/modern
    "traceroute.db",       # Debian's alternatives wrapper
    "traceproto",          # sometimes present with traceroute package
    "/usr/sbin/tcptraceroute",  # legacy tcptraceroute
]
TRACERT_CMDS = ["tracert"]


def resolve_tracer() -> str:
    """
    Return a tracer binary path or raise if not found.
    """
    if IS_WINDOWS:
        p = which(TRACERT_CMDS)
    else:
        p = which(TRACEROUTE_CMDS)
    if not p:
        raise RuntimeError("No traceroute/tracert found on PATH. Please install it.")
    return p


# --------- output parsing helpers ---------

_rt_ms = re.compile(r"([0-9]+(?:\.[0-9]+)?)\s*ms", re.IGNORECASE)
_hop_num = re.compile(r"^\s*(\d+)\s+")


def _parse_traceroute_stdout(stdout: str) -> Dict[int, List[float]]:
    """
    Parse traceroute-like output into {ttl: [rtt_ms, ...]}.
    Tolerant to different packaging formats; collects every 'NNN ms' token per hop line.
    """
    hops: Dict[int, List[float]] = {}
    for line in stdout.splitlines():
        m = _hop_num.match(line)
        if not m:
            continue
        ttl = int(m.group(1))
        rtts: List[float] = []
        for ms in _rt_ms.findall(line):
            try:
                rtts.append(float(ms))
            except ValueError:
                pass
        # '*' only lines produce zero rtts; caller will treat as all-lost for that round
        hops[ttl] = rtts
    return hops


# --------- one-round runner ---------

async def run_tracer_round(
    tracer_bin: str,
    target_ip: str,
    *,
    max_ttl: int,
    timeout: float,
    proto: str,
    qpr: int,
) -> Dict[int, List[float]]:
    """
    Execute a single traceroute pass and parse rtts.
    - proto: 'icmp' uses traceroute -I, 'tcp' -> -T, 'udp' -> default
    - qpr: queries per hop (traceroute -q)
    - timeout: per-probe timeout (traceroute -w)
    We add a small cushion to the outer wait to allow the process to exit cleanly.
    """
    if IS_WINDOWS:
        # Fallback: basic tracert (no per-probe control); still parse ms tokens
        # tracert options:
        #   -h max_ttl
        #   -w timeout_ms
        to_ms = max(1, int(float(timeout) * 1000))
        args = [tracer_bin, "-h", str(max_ttl), "-w", str(to_ms), target_ip]
    else:
        args = [tracer_bin, "-n", "-m", str(max_ttl), "-q", str(qpr), "-w", str(float(timeout))]
        if proto == "icmp":
            args.append("-I")
        elif proto == "tcp":
            args.append("-T")
        # udp => default
        args.append(target_ip)

    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        # give traceroute a small grace window beyond per-probe timeout
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=float(timeout) + 2.0)
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise
    out_s = out_b.decode(errors="replace")
    # We ignore stderr; some builds print warnings there
    return _parse_traceroute_stdout(out_s)
