from __future__ import annotations
from dataclasses import dataclass
from typing import Optional
from icmplib import async_ping

@dataclass
class PingStat:
    address: str
    transmitted: int
    received: int
    loss_pct: float
    avg_ms: Optional[float]
    best_ms: Optional[float]
    worst_ms: Optional[float]

async def ping_host(address: str, count: int = 1, deadline: float = 1.0) -> PingStat:
    """
    Send ICMP echo requests using icmplib.
    Returns a PingStat with loss percentage and latency stats.
    """
    try:
        host = await async_ping(address, count=count, interval=0.2, timeout=deadline, privileged=False)
        transmitted = count
        received = host.packets_received
        loss_pct = 100.0 * (1 - (received / transmitted if transmitted else 0))
        return PingStat(
            address=address,
            transmitted=transmitted,
            received=received,
            loss_pct=loss_pct,
            avg_ms=host.avg_rtt,
            best_ms=host.min_rtt,
            worst_ms=host.max_rtt,
        )
    except Exception:
        return PingStat(
            address=address,
            transmitted=count,
            received=0,
            loss_pct=100.0,
            avg_ms=None,
            best_ms=None,
            worst_ms=None,
        )
