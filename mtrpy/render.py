from __future__ import annotations
from time import perf_counter
from rich.console import Console
from rich.table import Table
from rich import box

from .stats import Circuit

# Global rich console used by cli.py
console = Console(color_system="standard", force_terminal=True)

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]

def _fmt(v):
    return "-" if v is None else f"{v:.1f}"

def build_table(
    circuit: Circuit,
    title: str,
    started_at: float,
    ascii_mode: bool = False,
    wide: bool = False,
) -> Table:
    """Build a rich.Table with hop statistics."""
    t = Table(
        expand=wide,
        box=box.SIMPLE if ascii_mode else box.ROUNDED,
        show_edge=True,
        show_lines=False,
        title=title,
        caption=f"{int(perf_counter() - started_at)}s — Ctrl+C to quit",
    )

    for h in HEADERS:
        justify = "right" if h in {"Hop", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"} else "left"
        t.add_column(h, justify=justify)

    for ttl, addr, lp, snt, rcv, avg, best, wrst in circuit.rows():
        t.add_row(
            str(ttl),
            (addr or "*"),
            f"{int(round(lp, 0))}",
            str(snt),
            str(rcv),
            _fmt(avg),
            _fmt(best),
            _fmt(wrst),
        )

    return t
