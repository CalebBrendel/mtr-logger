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
        self.hops: Dict[int, HopStat] = {}

    def _get(self, ttl: int, address: Optional[str]) -> HopStat:
        hop = self.hops.get(ttl)
        if not hop:
            hop = HopStat(ttl=ttl, address=address)
            self.hops[ttl] = hop
        if address and not hop.address:
            hop.address = address
        return hop

    def update_hop_samples(self, ttl: int, address: Optional[str], samples_ms: List[float]) -> None:
        hop = self._get(ttl, address)
        # Only count probes as 'sent' when we actually have samples for this hop.
        # This avoids fabricating 100% loss on TTLs that weren't reached this round.
        if samples_ms:
            hop.sent += len(samples_ms)
            for rtt in samples_ms:
                hop.recv += 1
                hop.rtts.append(rtt)
                hop.best_ms = rtt if hop.best_ms is None else min(hop.best_ms, rtt)
                hop.worst_ms = rtt if hop.worst_ms is None else max(hop.worst_ms, rtt)
            if hop.rtts:
                hop.avg_ms = sum(hop.rtts) / len(hop.rtts)

    def as_rows(self) -> List[HopStat]:
        # Only return hops that have ever seen activity (address known OR any probes recorded)
        rows = []
        for ttl in sorted(self.hops):
            hop = self.hops[ttl]
            if hop.address is not None or hop.sent > 0 or hop.recv > 0:
                rows.append(hop)
        return rows
