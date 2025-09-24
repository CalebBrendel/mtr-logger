from __future__ import annotations

import asyncio
import re
import shutil
from typing import Dict, List, Tuple

RTT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*ms", re.IGNORECASE)

def resolve_tracer() -> str:
    """
    Find a traceroute binary on PATH. Prefer 'traceroute' (Linux/BSD).
    """
    for name in ("traceroute", "traceproto", "tcptraceroute"):
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError("No traceroute-like binary found on PATH. Please install 'traceroute'.")

def _build_cmd(tr_path: str, ip: str, max_ttl: int, timeout: float, proto: str, probes: int) -> List[str]:
    """
    Compose traceroute command line for the chosen protocol.
    - We use -n for numeric output so we parse reliably; DNS display is handled elsewhere.
    - -q = probes per hop, -m = max ttl, -w = per-probe wait (seconds).
    """
    base = [tr_path, "-n", "-q", str(probes), "-m", str(max_ttl), "-w", str(timeout)]
    if proto == "icmp":
        base.insert(1, "-I")
    elif proto == "tcp":
        base.insert(1, "-T")
    # UDP is the traceroute default; no extra switch.
    base.append(ip)
    return base

def _parse_traceroute_output(text: str, max_ttl: int) -> Dict[int, List[float]]:
    """
    Parse traceroute stdout into {ttl: [rtt_ms, ...]}.
    We ignore hop addresses here; the CLI/resolver handles name display separately.
    """
    rtts_by_ttl: Dict[int, List[float]] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        # Typical starts with TTL number
        parts = line.split()
        try:
            ttl = int(parts[0])
        except (ValueError, IndexError):
            continue
        if ttl < 1 or ttl > max_ttl:
            continue

        # Extract all RTT values on the line
        samples: List[float] = []
        for m in RTT_RE.finditer(line):
            try:
                samples.append(float(m.group(1)))
            except ValueError:
                pass
        rtts_by_ttl[ttl] = samples  # empty list = no replies for that hop this round
    # Ensure every TTL has a key (even if empty)
    for t in range(1, max_ttl + 1):
        rtts_by_ttl.setdefault(t, [])
    return rtts_by_ttl

async def run_tracer_round(
    tr_path: str,
    ip: str,
    max_ttl: int,
    timeout: float,
    proto: str,
    probes: int,
) -> Tuple[Dict[int, List[float]], bool]:
    """
    Execute one traceroute round and return:
      ( {ttl: [rtt_ms, ...]}, ok_flag )
    ok_flag is True if the traceroute exited cleanly (rc==0).
    """
    cmd = _build_cmd(tr_path, ip, max_ttl, timeout, proto, probes)
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    out_b, err_b = await proc.communicate()
    stdout = out_b.decode(errors="replace")
    # stderr is not required for normal operation; keep for debugging if needed
    rtts = _parse_traceroute_output(stdout, max_ttl)
    ok = (proc.returncode == 0)
    return rtts, ok
