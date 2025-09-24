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
