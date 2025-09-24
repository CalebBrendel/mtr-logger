from __future__ import annotations
from dataclasses import dataclass, field
from typing import Dict, List, Optional
import statistics


@dataclass
class HopStat:
    ttl: int
    address: Optional[str] = None
    sent: int = 0
    recv: int = 0
    rtts: List[float] = field(default_factory=list)

    # ---------- Derived metrics ----------
    @property
    def loss_pct(self) -> float:
        if self.sent <= 0:
            return 0.0
        return 100.0 * (1.0 - (self.recv / self.sent))

    @property
    def best_ms(self) -> Optional[float]:
        return min(self.rtts) if self.rtts else None

    @property
    def worst_ms(self) -> Optional[float]:
        return max(self.rtts) if self.rtts else None

    @property
    def avg_ms(self) -> Optional[float]:
        return statistics.fmean(self.rtts) if self.rtts else None


class Circuit:
    """
    Aggregates hop statistics keyed by TTL.
    """
    def __init__(self) -> None:
        self.hops: Dict[int, HopStat] = {}

    # Internal: get-or-create hop record
    def _get(self, ttl: int, address: Optional[str]) -> HopStat:
        hop = self.hops.get(ttl)
        if hop is None:
            hop = HopStat(ttl=ttl, address=address)
            self.hops[ttl] = hop
        # Prefer the first non-empty address we learn
        if address and not hop.address:
            hop.address = address
        return hop

    # Back-compat: single sample path
    def update_hop(self, ttl: int, address: Optional[str], rtt_ms: Optional[float]) -> None:
        if rtt_ms is None:
            self.update_hop_samples(ttl, address, [])
        else:
            self.update_hop_samples(ttl, address, [rtt_ms])

    # Primary: batch samples for a probe burst at this hop
    def update_hop_samples(self, ttl: int, address: Optional[str], samples_ms: List[float]) -> None:
        hop = self._get(ttl, address)

        # We count every probe as "sent"; only successful rtts as "recv".
        # If caller passed N samples, we assume N probes were sent.
        # If caller passed [], it means a lost probe at this hop.
        sent = max(1, len(samples_ms)) if not samples_ms else len(samples_ms)
        hop.sent += sent

        for rtt in samples_ms:
            hop.recv += 1
            hop.rtts.append(rtt)

    # What the renderer expects: a list of HopStat ordered by TTL
    def as_rows(self) -> List[HopStat]:
        return [self.hops[k] for k in sorted(self.hops.keys())]
