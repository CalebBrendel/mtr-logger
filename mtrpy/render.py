from __future__ import annotations

from time import perf_counter
from typing import Iterable, Any

from rich.console import Console
from rich.table import Table
from rich import box

# One console for both interactive + string rendering
# Keep colors simple for SSH / VMs
_console = Console(color_system="standard", force_terminal=True)

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]


def _fmt_ms(v: float | None) -> str:
    return f"{v:.1f}" if v is not None else "-"


def _iter_rows_compat(circuit: Any) -> Iterable[Any]:
    """
    Support multiple Circuit implementations:

    Priority:
      - circuit.iter_rows()
      - circuit.as_rows()
      - circuit.hops dict (sorted by ttl)
    Expect row / hop fields:
      ttl, address, loss_pct, sent, recv, avg_ms, best_ms, worst_ms
    """
    if hasattr(circuit, "iter_rows") and callable(circuit.iter_rows):
        yield from circuit.iter_rows()  # new API
        return
    if hasattr(circuit, "as_rows") and callable(circuit.as_rows):
        yield from circuit.as_rows()    # old API
        return
    # Fallback: assume dict of HopStat by ttl
    hops = getattr(circuit, "hops", {})
    for ttl in sorted(hops.keys()):
        yield hops[ttl]


def build_table(
    circuit: Any,
    title: str,
    started_at: float,
    *,
    ascii_mode: bool = False,
    wide: bool = False,
) -> Table:
    """Create a Rich Table for the current circuit snapshot."""
    t = Table(
        expand=wide,
        box=box.SIMPLE if ascii_mode else box.ROUNDED,
        show_edge=True,
        show_lines=False,
        title=title,
        caption=f"{int(perf_counter() - started_at)}s — Ctrl+C to quit",
        pad_edge=False,
    )
    # Column alignments
    for h in HEADERS:
        if h in {"Hop", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"}:
            t.add_column(h, justify="right", no_wrap=True)
        else:
            t.add_column(h, justify="left")

    # Rows
    for row in _iter_rows_compat(circuit):
        ttl = getattr(row, "ttl", None)
        addr = getattr(row, "address", None) or "*"
        loss = getattr(row, "loss_pct", 0.0)
        sent = getattr(row, "sent", 0)
        recv = getattr(row, "recv", 0)
        avg = getattr(row, "avg_ms", None)
        best = getattr(row, "best_ms", None)
        worst = getattr(row, "worst_ms", None)

        t.add_row(
            str(ttl) if ttl is not None else "-",
            str(addr),
            f"{loss:.0f}",
            str(sent),
            str(recv),
            _fmt_ms(avg),
            _fmt_ms(best),
            _fmt_ms(worst),
        )

    return t


def render_table(table: Table) -> str:
    """Render a Rich Table to a string (for printing without flicker)."""
    with _console.capture() as cap:
        _console.print(table)
    return cap.get()
