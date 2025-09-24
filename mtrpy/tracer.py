from __future__ import annotations

import asyncio
import contextlib
import re
from typing import Dict, List, Optional, Tuple

from .util import which

# Matches lines like:
# " 1  something ..."
_TR_PAT = re.compile(r"^\s*(\d+)\s+(.+)$")

# Extracts RTT samples like "11.1 ms" → 11.1
_RTTS_PAT = re.compile(r"([0-9]+\.[0-9]+)\s*ms")

# Very loose IPv4/IPv6 "looks like an address" check (good enough for tracer output)
def _looks_like_ip(token: str) -> bool:
    if token.count(".") == 3:
        return True
    if ":" in token:  # IPv6
        return True
    return False


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
    - rtts_by_ttl[ttl] = [rtt_ms, ...]
    - addr_by_ttl[ttl] = "ip" or None (when "*")
    - ok: True if we parsed something; False if the run clearly failed
    """
    # Map proto → traceroute flags
    if proto == "icmp":
        proto_flag = "-I"
    elif proto == "tcp":
        proto_flag = "-T"
    else:  # udp default
        proto_flag = ""

    # Use -n for numeric; we do reverse DNS in a separate step
    args = [
        tr_path,
        "-n",
        proto_flag,
        "-q", str(probes),
        "-w", str(timeout),
        "-m", str(max_hops),
        ip,
    ]
    args = [a for a in args if a]  # drop empty strings

    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )

    # Give the round a sane upper bound: per-probe timeout × probes × hops, with a little cushion
    # This keeps the round responsive and cancellable.
    round_budget = max(1.0, timeout * max(1, probes) * max(1, max_hops) * 1.2)

    try:
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=round_budget)
    except asyncio.TimeoutError:
        # If the round runs too long, kill and treat as a soft failure
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        out_b, err_b = b"", b""
    except asyncio.CancelledError:
        # If user hits Ctrl+C while we're waiting, kill the tracer and bubble up
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise

    text = out_b.decode("utf-8", "replace").splitlines()

    rtts_by_ttl: Dict[int, List[float]] = {}
    addr_by_ttl: Dict[int, Optional[str]] = {}
    ok = False  # flip True if we parse at least one TTL line

    for line in text:
        m = _TR_PAT.match(line)
        if not m:
            continue

        ok = True  # saw at least one hop line

        ttl = int(m.group(1))
        rest = m.group(2).strip()

        # All-star row like "* * *"
        if rest.startswith("*"):
            addr_by_ttl[ttl] = None
            rtts_by_ttl.setdefault(ttl, [])
            continue

        # Extract an address to store. Prefer the last IP-looking token in the row.
        addr_ip: Optional[str] = None
        # Normalize parentheses so "host (1.2.3.4)" becomes tokens we can scan
        for token in rest.replace("(", " ").replace(")", " ").split():
            if _looks_like_ip(token):
                addr_ip = token
        addr_by_ttl[ttl] = addr_ip

        # Collect RTT samples
        samples = [float(x) for x in _RTTS_PAT.findall(rest)]
        rtts_by_ttl[ttl] = samples

    return rtts_by_ttl, addr_by_ttl, ok
