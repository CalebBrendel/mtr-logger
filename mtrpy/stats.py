from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, Dict, List


@dataclass
class HopStat:
    ttl: int
    address: Optional[str]
    sent: int = 0
    recv: int = 0
    best_ms: Optional[float] = None
    worst_ms: Optional[float] = None
    avg_ms: Optional[float] = None
    rtts: List[float] = field(default_factory=list)

    @property
    def loss_pct(self) -> float:
        if self.sent == 0:
            return 0.0
        return 100.0 * (1 - (self.recv / self.sent))


class Circuit:
    def __init__(self) -> None:
        # ttl -> HopStat
        self.hops: Dict[int, HopStat] = {}

    def _get(self, ttl: int, address: Optional[str]) -> HopStat:
        hop = self.hops.get(ttl)
        if not hop:
            hop = HopStat(ttl=ttl, address=address)
            self.hops[ttl] = hop
        if address and not hop.address:
            hop.address = address
        return hop

    def update_hop(self, ttl: int, address: Optional[str], rtt_ms: Optional[float]) -> None:
        self.update_hop_samples(ttl, address, [rtt_ms] if rtt_ms is not None else [])

    def update_hop_samples(self, ttl: int, address: Optional[str], samples_ms: List[float]) -> None:
        hop = self._get(ttl, address)
        # Count probes provided; recv = number of RTT samples we parsed
        sent = max(1, len(samples_ms)) if not samples_ms else len(samples_ms)
        hop.sent += sent
        for rtt in samples_ms:
            hop.recv += 1
            hop.rtts.append(rtt)
            hop.best_ms = rtt if hop.best_ms is None else min(hop.best_ms, rtt)
            hop.worst_ms = rtt if hop.worst_ms is None else max(hop.worst_ms, rtt)
        if hop.rtts:
            hop.avg_ms = sum(hop.rtts) / len(hop.rtts)
