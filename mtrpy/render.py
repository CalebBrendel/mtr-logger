from __future__ import annotations
from time import perf_counter
from typing import Iterable
from rich.table import Table
from rich import box
from rich.console import Console

from .stats import Circuit, HopStat

console = Console(color_system="standard", force_terminal=True)

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]


def _fmt_ms(v):
    return f"{v:.1f}" if v is not None else "-"


def build_table(circuit: Circuit, target: str, started_at: float, ascii_mode: bool = False, wide: bool = False):
    t = Table(
        expand=wide,
        box=box.SIMPLE if ascii_mode else box.ROUNDED,
        show_edge=True,
        show_lines=False,
        title=f"mtr-logger → {target}",
        caption=f"{int(perf_counter() - started_at)}s — Ctrl+C to quit",
    )
    for h in HEADERS:
        t.add_column(h, justify="right" if h in {"Hop", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"} else "left")

    def rows() -> Iterable[HopStat]:
        for ttl in sorted(circuit.hops.keys()):
            yield circuit.hops[ttl]

    for row in rows():
        t.add_row(
            str(row.ttl),
            row.address or "*",
            f"{row.loss_pct:.0f}",
            str(row.sent),
            str(row.recv),
            _fmt_ms(row.avg_ms),
            _fmt_ms(row.best_ms),
            _fmt_ms(row.worst_ms),
        )
    return t


def render_table(circuit: Circuit, target: str, started_at: float, ascii_mode: bool = False, wide: bool = False) -> str:
    table = build_table(circuit, target, started_at, ascii_mode=ascii_mode, wide=wide)
    return console.render_str(table)
