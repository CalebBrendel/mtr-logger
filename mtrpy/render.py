from __future__ import annotations

from time import perf_counter
from typing import Optional

from rich.console import Console
from rich.table import Table
from rich import box

console = Console(color_system="standard", force_terminal=True)

HEADERS = ["Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst"]


def _fmt_ms(v: Optional[float]) -> str:
    return f"{v:.1f}" if v is not None else "-"


def build_table(
    circuit,
    target: str,
    started_at: float,
    *,
    ascii_mode: bool = False,
    wide: bool = False,
):
    t = Table(
        expand=wide,
        box=box.SIMPLE if ascii_mode else box.ROUNDED,
        show_edge=True,
        show_lines=False,
        title=f"mtr-logger → {target}",
        caption=f"{int(perf_counter() - started_at)}s — Ctrl+C to quit",
        pad_edge=False,
        collapse_padding=True,
    )

    for h in HEADERS:
        justify = "left" if h == "Address" else "right"
        t.add_column(h, justify=justify, no_wrap=(h != "Address"))

    for ttl in sorted(circuit.hops.keys()):
        hop = circuit.hops[ttl]
        address = hop.address or "*"
        sent = hop.sent
        recv = hop.recv
        loss_pct = 0.0 if sent == 0 else (100.0 * (1.0 - (recv / sent)))

        t.add_row(
            f"{ttl}",
            address,
            f"{int(round(loss_pct))}",
            f"{sent}",
            f"{recv}",
            _fmt_ms(hop.avg_ms),
            _fmt_ms(hop.best_ms),
            _fmt_ms(hop.worst_ms),
        )
    return t


def render_table(
    circuit,
    target: str,
    started_at: float,
    *,
    ascii_mode: bool = False,
    wide: bool = False,
) -> str:
    table = build_table(circuit, target, started_at, ascii_mode=ascii_mode, wide=wide)
    with console.capture() as cap:
        console.print(table)
    return cap.get()
