from __future__ import annotations

from datetime import datetime
from typing import List, Tuple

from .stats import Circuit, HopStat

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]

def _fmt_ms(v):
    return f"{v:.1f}" if v is not None else "-"

def _rows(circuit: Circuit) -> List[Tuple[str, ...]]:
    out: List[Tuple[str, ...]] = []
    for ttl in sorted(circuit.hops.keys()):
        hs: HopStat = circuit.hops[ttl]
        loss = 0.0 if hs.sent == 0 else (100.0 * (1.0 - (hs.recv / hs.sent)))
        out.append((
            str(ttl),
            hs.address or "*",
            f"{loss:.0f}",
            str(hs.sent),
            str(hs.recv),
            _fmt_ms(hs.avg_ms),
            _fmt_ms(hs.best_ms),
            _fmt_ms(hs.worst_ms),
        ))
    return out

def render_report(circuit: Circuit, *, order: str = "LSRABW", wide: bool = False) -> str:
    # fixed-width plain text table, then alerts
    rows = _rows(circuit)
    cols = list(zip(*([tuple(HEADERS)] + rows))) if rows else [tuple(HEADERS)]
    widths = [max(len(x) for x in col) for col in cols]
    if wide:
        widths[1] = max(widths[1], 40)

    def cell(i, text):
        just = ">" if i in (0,2,3,4,5,6,7) else "<"
        w = widths[i]
        return f"{text: {just}{w}}"

    header = " " + "  ".join(cell(i, h) for i, h in enumerate(HEADERS)) + "\n"
    sep = " " + "  ".join("-" * widths[i] for i in range(len(HEADERS))) + "\n"
    body = ""
    for r in rows:
        body += " " + "  ".join(cell(i, r[i]) for i in range(len(HEADERS))) + "\n"

    # alerts: ignore unresolved '*' hops; 12h time; include exact lost count
    alerts: List[str] = []
    tstr = datetime.now().strftime("%I:%M:%S%p").lstrip("0")
    for ttl in sorted(circuit.hops.keys()):
        hs: HopStat = circuit.hops[ttl]
        if hs.address in (None, "*"):
            continue
        lost = max(0, hs.sent - hs.recv)
        if lost > 0:
            alerts.append(f"❌ Packet loss detected on hop {ttl} at {tstr} - {lost} packets were lost")

    out = header + sep + body
    if alerts:
        out += "\nAlerts:\n" + "\n".join(alerts) + "\n"
    return out
