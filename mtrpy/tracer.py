from __future__ import annotations
import ipaddress
import re
from dataclasses import dataclass
from typing import List, Optional
from .util import IS_WINDOWS, which, run_proc

@dataclass
class Hop:
    ttl: int
    address: Optional[str]   # IP string if known
    rtts_ms: List[float]     # RTT samples in ms
    display: str             # what to render: hostname if dns_names else IP (or "*")

TRACEROUTE_CMDS = ["traceroute", "/usr/sbin/traceroute", "inetutils-traceroute"]
TRACERT_CMDS = ["tracert"]

async def resolve_tracer() -> Optional[str]:
    return await which(TRACERT_CMDS if IS_WINDOWS else TRACEROUTE_CMDS)

RTT_NUM = re.compile(r"(\d+\.?\d*)\s*ms")
PAREN_IP = re.compile(r"\(([^)]+)\)")

def _first_ip(s: str) -> Optional[str]:
    # naive extract of first IPv4/IPv6 literal in a string
    m = re.search(r"(?:(?:\d{1,3}\.){3}\d{1,3}|[0-9A-Fa-f:]{2,})", s)
    return m.group(0) if m else None

def parse_tracer_output(text: str, dns_names: bool) -> List[Hop]:
    hops: List[Hop] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue

        # Expect: "<ttl>  ..." at the start
        mttl = re.match(r"^\s*(\d+)\s+(.*)$", line)
        if not mttl:
            continue
        ttl = int(mttl.group(1))
        rest = mttl.group(2)

        # Pure timeout line like "*", "* *", or similar
        if rest.startswith("*"):
            hops.append(Hop(ttl, None, [], "*"))
            continue

        # Try hostname (ip) form
        ip_in_paren = PAREN_IP.search(rest)
        rtts = [float(x) for x in RTT_NUM.findall(rest)]
        hostname: Optional[str] = None
        ip_str: Optional[str] = None

        if ip_in_paren:
            ip_str = ip_in_paren.group(1)
            # hostname is text before " ("
            before = rest[: ip_in_paren.start()].strip()
            # on Windows "tracert -d" suppresses names; if not suppressed, first token is name
            hostname = before.split()[0] if before else None
        else:
            # numeric-only output: first token is IP
            ip_str = _first_ip(rest)

        # Normalize IP validity
        if ip_str:
            try:
                ipaddress.ip_address(ip_str)
            except ValueError:
                ip_str = None

        disp = hostname if (dns_names and hostname) else (ip_str or "*")
        hops.append(Hop(ttl, ip_str, rtts, disp))
    return hops

async def trace(
    host: str,
    max_hops: int = 30,
    nprobes: int = 1,
    timeout: float = 2.0,
    proto: str = "udp",      # "udp", "icmp", "tcp"
    dns_names: bool = False, # True → show hostnames if tracer provides them
) -> List[Hop]:
    binpath = await resolve_tracer()
    if not binpath:
        raise RuntimeError("No traceroute/tracert found on PATH. Please install it.")

    if IS_WINDOWS:
        # tracert defaults to resolving names; -d disables
        cmd = [binpath]
        if not dns_names:
            cmd.append("-d")
        cmd += ["-h", str(max_hops), "-w", str(int(timeout * 1000)), host]
    else:
        # traceroute base args
        cmd = [binpath]
        if not dns_names:
            cmd.append("-n")  # numeric only
        cmd += ["-m", str(max_hops), "-q", str(nprobes), "-w", str(timeout)]
        p = proto.lower()
        if p == "icmp":
            cmd.append("-I")
        elif p == "tcp":
            cmd.extend(["-T", "-p", "80"])
        # udp is default
        cmd.append(host)

    rc, out, err = await run_proc(cmd, timeout=timeout * (max_hops + 2))
    text = out if out else err
    return parse_tracer_output(text, dns_names=dns_names)
