from __future__ import annotations

from time import perf_counter
from typing import List, Tuple

from .stats import Circuit, HopStat

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]

def _fmt_ms(v):
    return f"{v:.1f} ms" if v is not None else "-"

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

def render_table(circuit: Circuit, target: str, started_at: float, *, ascii_mode: bool = True, wide: bool = False) -> str:
    rows = _rows(circuit)
    # compute widths
    cols = list(zip(*([tuple(HEADERS)] + rows))) if rows else [tuple(HEADERS)]
    widths = [max(len(x) for x in col) for col in cols]
    # widen address if requested
    if wide:
        widths[1] = max(widths[1], 40)

    def cell(i, text):
        just = ">" if i in (0,2,3,4,5,6,7) else "<"
        w = widths[i]
        return f"{text: {just}{w}}"

    # borders
    title = f"mtr-logger → {target}"
    elapsed = f"{int(perf_counter() - started_at)}s — Ctrl+C to quit"
    top = f"\n{title}\n\n"
    header = "  " + "  ".join(cell(i, h) for i, h in enumerate(HEADERS)) + "\n"
    sep = "  " + "  ".join("-" * widths[i] for i in range(len(HEADERS))) + "\n"
    body = ""
    for r in rows:
        body += "  " + "  ".join(cell(i, r[i]) for i in range(len(HEADERS))) + "\n"
    foot = f"\n  {elapsed}"
    return top + header + sep + body + foot
