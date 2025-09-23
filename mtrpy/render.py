# mtrpy/render.py
"""
Render helpers for mtr-logger.

- Rich TUI (interactive): `build_table(...)` + `console`  [backward compatible]
- Plain text (export / non-TUI): `render_table(...)` -> delegates to export.render_report
"""

from __future__ import annotations
from time import perf_counter
from typing import Optional

# --- Rich TUI (legacy/interactive) ---
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
    """
    Rich Table used by interactive UI (via Live).
    """
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


# --- Plain text (export / non-TUI) ---
from .export import render_report, DEFAULT_ORDER


def render_table(
    circuit: Circuit,
    order: Optional[str] = None,
    wide: bool = False,
    ascii: bool = False,      # accepted for compatibility; not used in text export
    no_screen: bool = False,  # accepted for compatibility; not used in text export
) -> str:
    """
    Return a neatly aligned, plain-text table for the current circuit snapshot.
    Used by the CLI when printing/exporting without Rich.

    Args:
        circuit: Circuit object with collected hop statistics.
        order: mtr-style field order string (default "LSRABW").
        wide: pass-through to export renderer (controls width policy).
        ascii, no_screen: accepted for CLI compatibility; not used here.

    Returns:
        str: Rendered text table for display or logging.
    """
    return render_report(circuit, order=order or DEFAULT_ORDER, wide=wide)
