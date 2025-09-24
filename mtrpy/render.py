from __future__ import annotations
from time import perf_counter
from rich.console import Console
from rich.table import Table
from rich import box

from .stats import Circuit

# One console for rendering to string (record/capture mode).
_console = Console(color_system="standard", force_terminal=True, record=True)

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]

def _fmt_ms(v):
    return f"{v:.1f}" if v is not None else "-"

def _box(ascii_mode: bool):
    # SIMPLE works well over SSH/VMs; ROUNDED looks nice locally.
    return box.SIMPLE if ascii_mode else box.ROUNDED

def render_table(
    circuit: Circuit,
    target: str,
    started_at: float,
    ascii_mode: bool = False,
    wide: bool = False,
) -> str:
    """
    Build the Rich table then render it to a plain string for callers.
    """
    t = Table(
        expand=False,
        box=_box(ascii_mode),
        show_edge=True,
        show_lines=False,
        title=f"mtr-logger → {target}",
        caption=f"{int(perf_counter() - started_at)}s — Ctrl+C to quit",
        pad_edge=False,
    )

    # Column alignment
    for h in HEADERS:
        justify = "right" if h in {"Hop", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"} else "left"
        t.add_column(h, justify=justify, no_wrap=(h != "Address"))

    # Rows
    for row in circuit.as_rows():
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

    # Render to a plain string
    with _console.capture() as cap:
        _console.print(t)
    return cap.get()
