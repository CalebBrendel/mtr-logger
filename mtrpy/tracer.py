from __future__ import annotations

import asyncio
import re
import shutil
from typing import Dict, List, Tuple

# Example traceroute -n lines:
#  1  10.10.4.1  0.5 ms  0.4 ms  0.4 ms
#  2  * * *
# 10  142.251.60.19  18.7 ms  17.9 ms  20.2 ms

RTT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*ms", re.IGNORECASE)

def resolve_tracer() -> str:
    for name in ("traceroute", "traceproto", "tcptraceroute"):
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError("No traceroute-like binary found on PATH. Please install 'traceroute'.")

def _build_cmd(tr_path: str, ip: str, max_ttl: int, timeout: float, proto: str, probes: int) -> List[str]:
    base = [tr_path, "-n", "-q", str(probes), "-m", str(max_ttl), "-w", str(timeout)]
    if proto == "icmp":
        base.insert(1, "-I")
    elif proto == "tcp":
        base.insert(1, "-T")
    base.append(ip)
    return base

def _parse_traceroute_output(text: str, max_ttl: int) -> Tuple[Dict[int, List[float]], Dict[int, str]]:
    """
    Returns (rtts_by_ttl, addr_by_ttl)
      rtts_by_ttl: { ttl: [rtt_ms, ...] }  (list may be empty => no replies)
      addr_by_ttl: { ttl: "IP" }           (only set when an address is present)
    """
    rtts_by_ttl: Dict[int, List[float]] = {}
    addr_by_ttl: Dict[int, str] = {}

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        # expect first token to be TTL
        try:
            ttl = int(parts[0])
        except (ValueError, IndexError):
            continue
        if ttl < 1 or ttl > max_ttl:
            continue

        # address likely in parts[1] if not "*"
        if len(parts) > 1 and parts[1] != "*":
            addr_by_ttl[ttl] = parts[1]

        # collect RTT samples
        samples: List[float] = []
        for m in RTT_RE.finditer(line):
            try:
                samples.append(float(m.group(1)))
            except ValueError:
                pass
        rtts_by_ttl[ttl] = samples

    return rtts_by_ttl, addr_by_ttl

async def run_tracer_round(
    tr_path: str,
    ip: str,
    max_ttl: int,
    timeout: float,
    proto: str,
    probes: int,
) -> Tuple[Dict[int, List[float]], Dict[int, str], bool]:
    """
    Execute one traceroute round and return:
      ( rtts_by_ttl, addr_by_ttl, ok_flag )
    """
    cmd = _build_cmd(tr_path, ip, max_ttl, timeout, proto, probes)
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        out_b, err_b = await proc.communicate()
    except asyncio.CancelledError:
        # if the loop is interrupted (Ctrl+C), stop the subprocess cleanly
        with contextlib.suppress(Exception):
            proc.kill()
            await proc.wait()
        raise
    stdout = out_b.decode(errors="replace")
    rtts_by_ttl, addr_by_ttl = _parse_traceroute_output(stdout, max_ttl)
    ok = (proc.returncode == 0)
    return rtts_by_ttl, addr_by_ttl, ok

# local import to avoid a top-level dependency
import contextlib  # noqa: E402
