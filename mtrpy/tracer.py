from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from typing import List, Optional

from .util import which, run_proc, IS_WINDOWS

TRACEROUTE_CMDS = ["traceroute"]
TRACERT_CMDS = ["tracert"]

@dataclass
class Hop:
    ttl: int
    address: Optional[str]

def resolve_tracer() -> Optional[str]:
    if IS_WINDOWS:
        return which(TRACERT_CMDS)
    return which(TRACEROUTE_CMDS)

# numeric-only parse for discovery
LINE_RE = re.compile(r"^\s*(\d+)\s+(.+)$")
ADDR_RE = re.compile(r"^\s*(\d+)\s+(\S+)")

async def trace(target_ip: str, *, max_hops: int = 30, nprobes: int = 3, timeout: float = 0.7, proto: str = "icmp") -> List[Hop]:
    """
    Run a single traceroute to discover TTLs and numeric addresses.
    We use -n (no DNS) to keep discovery fast. Caller handles display DNS.
    """
    tr = resolve_tracer()
    if not tr:
        raise RuntimeError("No traceroute/tracert found on PATH. Please install it.")

    if IS_WINDOWS:
        # Windows 'tracert' numeric: -d (no DNS), -h max_hops
        cmd = [tr, "-d", "-h", str(max_hops), target_ip]
        rc, out, err = await run_proc(cmd, timeout=timeout * max_hops + 3)
        text = out or err or ""
        hops: List[Hop] = []
        for line in text.splitlines():
            # crude parse: lines start with hop number, and possibly IP later
            m = LINE_RE.match(line)
            if not m:
                continue
            ttl = int(m.group(1))
            addr = None
            parts = line.split()
            for tok in parts[1:]:
                if tok.count(".") == 3:
                    addr = tok
                    break
            hops.append(Hop(ttl=ttl, address=addr))
        return hops

    # Unix traceroute
    cmd = [tr, "-n", "-q", str(max(1, nprobes)), "-w", f"{max(0.3, float(timeout)):.1f}", "-m", str(max_hops), target_ip]
    p = (proto or "icmp").lower()
    if p == "icmp":
        cmd.append("-I")
    elif p == "tcp":
        cmd.append("-T")

    rc, out, err = await run_proc(cmd, timeout=timeout * max_hops + 3)
    text = out or err or ""
    hops: List[Hop] = []
    for line in text.splitlines():
        m = ADDR_RE.match(line)
        if not m:
            continue
        ttl = int(m.group(1))
        addr = m.group(2)
        if addr == "*":
            addr = None
        hops.append(Hop(ttl=ttl, address=addr))
    return hops
