from __future__ import annotations

import asyncio
import contextlib
import re
from typing import Dict, List, Optional, Tuple

from .util import which

_TR_PAT = re.compile(
    r"^\s*(\d+)\s+(.+)$"
)

# Extracts like:
# "hostname (1.2.3.4)  11.1 ms  12.3 ms  9.9 ms"
# or "1.2.3.4  11.1 ms  12.3 ms  9.9 ms"
# or "* * *"
_RTTS_PAT = re.compile(r"([0-9]+\.[0-9]+)\s*ms")


def resolve_tracer() -> Optional[str]:
    return which(["traceroute"])


async def run_tracer_round(
    tr_path: str,
    ip: str,
    max_hops: int,
    timeout: float,
    proto: str,
    probes: int,
) -> Tuple[Dict[int, List[float]], Dict[int, Optional[str]], bool]:
    """
    Launch system traceroute for a single round and parse per-TTL RTT samples.
    Returns (rtts_by_ttl, addr_by_ttl, ok).
    """
    if proto == "icmp":
        proto_flag = "-I"
    elif proto == "tcp":
        proto_flag = "-T"
    else:  # udp default
        proto_flag = ""

    # -n for numeric (we do reverse DNS ourselves)
    args = [tr_path, "-n", proto_flag, "-q", str(probes), "-w", str(timeout), "-m", str(max_hops), ip]
    args = [a for a in args if a]  # drop empty
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )

    try:
        out_b, _err_b = await proc.communicate()
    except asyncio.CancelledError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise

    text = out_b.decode("utf-8", "replace").splitlines()

    rtts_by_ttl: Dict[int, List[float]] = {}
    addr_by_ttl: Dict[int, Optional[str]] = {}
    ok = True

    for line in text:
        m = _TR_PAT.match(line)
        if not m:
            continue
        ttl = int(m.group(1))
        rest = m.group(2).strip()

        if rest.startswith("*"):
            addr_by_ttl[ttl] = None
            rtts_by_ttl.setdefault(ttl, [])
            continue

        # first token might be "IP" or "host (IP)"
        # find the last IP-looking token in the line for address, then collect RTTs
        ip_match = None
        for token in rest.replace("(", " ").replace(")", " ").split():
            if token.count(".") == 3 or ":" in token:
                ip_match = token
        addr_by_ttl[ttl] = ip_match

        samples = [float(x) for x in _RTTS_PAT.findall(rest)]
        rtts_by_ttl[ttl] = samples

    return rtts_by_ttl, addr_by_ttl, ok
