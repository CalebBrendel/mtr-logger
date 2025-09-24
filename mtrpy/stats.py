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
        return 100.0 * (1.0 - (self.recv / self.sent))

class Circuit:
    """
    Holds cumulative hop stats across tracer rounds.
    """

    def __init__(self) -> None:
        self.hops: Dict[int, HopStat] = {}

    def _get(self, ttl: int, address: Optional[str]) -> HopStat:
        hop = self.hops.get(ttl)
        if not hop:
            hop = HopStat(ttl=ttl, address=address)
            self.hops[ttl] = hop
        # prefer to remember an address once we see it
        if address and not hop.address:
            hop.address = address
        return hop

    def update_hop_round(self, ttl: int, address: Optional[str], probes_attempted: int, samples_ms: List[float]) -> None:
        """
        Increment 'sent' by the number of probes attempted this round, even if zero replies,
        then fold in any RTT samples we did receive.
        """
        hop = self._get(ttl, address)
        if probes_attempted < 0:
            probes_attempted = 0
        hop.sent += probes_attempted

        for rtt in samples_ms:
            hop.recv += 1
            hop.rtts.append(rtt)
            hop.best_ms = rtt if hop.best_ms is None else min(hop.best_ms, rtt)
            hop.worst_ms = rtt if hop.worst_ms is None else max(hop.worst_ms, rtt)

        if hop.rtts:
            # simple running average from stored samples
            hop.avg_ms = sum(hop.rtts) / len(hop.rtts)

    # Backwards-compat helpers (used nowhere after this fix, but harmless to keep)
    def update_hop(self, ttl: int, address: Optional[str], rtt_ms: Optional[float]) -> None:
        self.update_hop_round(ttl, address, 1, [] if rtt_ms is None else [rtt_ms])

    def update_hop_samples(self, ttl: int, address: Optional[str], samples_ms: List[float]) -> None:
        self.update_hop_round(ttl, address, max(1, len(samples_ms)), samples_ms)

    # Rendering helpers
    def rows(self):
        """Yield rows in TTL order."""
        for ttl in sorted(self.hops.keys()):
            hop = self.hops[ttl]
            yield (
                hop.ttl,
                hop.address or "*",
                int(round(hop.loss_pct)),
                hop.sent,
                hop.recv,
                hop.avg_ms,
                hop.best_ms,
                hop.worst_ms,
            )
