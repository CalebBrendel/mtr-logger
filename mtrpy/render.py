from __future__ import annotations
from time import perf_counter
from rich.console import Console
from rich.table import Table
from rich import box

from .stats import Circuit

# simpler color system is safer in VMs/SSH
console = Console(color_system="standard", force_terminal=True)

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Best", "Avg", "Wrst"]


def _fmt_ms(v):
    return f"{v:.1f} ms" if v is not None else "-"


def build_table(circuit: Circuit, target: str, started_at: float, ascii_mode: bool = False):
    t = Table(
        expand=False,
        box=box.SIMPLE if ascii_mode else box.ROUNDED,
        show_edge=True,
        show_lines=False,
        title=f"mtrpy → {target}",
        caption=f"{int(perf_counter() - started_at)}s — Ctrl+C to quit",
    )
    for h in HEADERS:
        t.add_column(h, justify="right" if h in {"Hop", "Loss%", "Snt", "Recv", "Best", "Avg", "Wrst"} else "left")
    for row in circuit.as_rows():
        t.add_row(
            str(row.ttl),
            row.address or "*",
            f"{row.loss_pct:.0f}",
            str(row.sent),
            str(row.recv),
            _fmt_ms(row.best_ms),
            _fmt_ms(row.avg_ms),
            _fmt_ms(row.worst_ms),
        )
    return t
