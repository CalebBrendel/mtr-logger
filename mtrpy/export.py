from __future__ import annotations
from pathlib import Path
from typing import Iterable, Optional, List

from .stats import Circuit, HopStat
from .util import ensure_dir, now_local_str


# Fixed-width columns to match your previous logs
HEADERS = ("Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst")
COLS = (4, 42, 7, 5, 5, 6, 6, 6)  # widths per column (kept consistent)


def _fmt_ms(v: Optional[float]) -> str:
    return "-" if v is None else f"{v:.1f}"


def _fmt_addr(addr: Optional[str]) -> str:
    return "*" if not addr else addr


def _row_line(hop: HopStat) -> str:
    cells = (
        f"{hop.ttl:>3}",
        f"{_fmt_addr(hop.address):<42}",
        f"{hop.loss_pct:>5.0f}",
        f"{hop.sent:>5}",
        f"{hop.recv:>5}",
        f"{_fmt_ms(hop.avg_ms):>6}",
        f"{_fmt_ms(hop.best_ms):>6}",
        f"{_fmt_ms(hop.worst_ms):>6}",
    )
    return f" {cells[0]:>3}  {cells[1]:<42}  {cells[2]:>5}  {cells[3]:>3}  {cells[4]:>4}  {cells[5]:>4}  {cells[6]:>4}  {cells[7]:>5}"


def _header_line() -> str:
    cells = (
        f"{HEADERS[0]:>3}",
        f"{HEADERS[1]:<42}",
        f"{HEADERS[2]:>5}",
        f"{HEADERS[3]:>3}",
        f"{HEADERS[4]:>4}",
        f"{HEADERS[5]:>4}",
        f"{HEADERS[6]:>4}",
        f"{HEADERS[7]:>5}",
    )
    return f" {cells[0]:>3}  {cells[1]:<42}  {cells[2]:>5}  {cells[3]:>3}  {cells[4]:>4}  {cells[5]:>4}  {cells[6]:>4}  {cells[7]:>5}"


def _rule_line() -> str:
    # A separator line sized to the header
    return " ---  " + "-" * 42 + "  -----  ---  ----  ----  ----  -----"


def build_text_table(circuit: Circuit) -> List[str]:
    """Return a list of text lines representing the current table snapshot."""
    lines: List[str] = []
    lines.append(_header_line())
    lines.append(_rule_line())

    for ttl in sorted(circuit.hops.keys()):
        hop = circuit.hops[ttl]
        lines.append(_row_line(hop))

    return lines


class IncrementalReport:
    """
    Opens the log file once and appends a timestamped snapshot after each round,
    plus any alerts observed in that round. Safe to tail in real time.
    """

    def __init__(self, path: Path, target: str):
        ensure_dir(path.parent)
        self.path = path
        self._fp = path.open("a", encoding="utf-8")
        self._write_title(target)

    def _write_title(self, target: str) -> None:
        self._fp.write(f"=== mtr-logger → {target} ===\n")
        self._fp.flush()

    def append_snapshot(self, circuit: Circuit, when_str: Optional[str] = None) -> None:
        ts = when_str or now_local_str(time_only=True)
        self._fp.write(f"\nSnapshot @ {ts}\n")
        for line in build_text_table(circuit):
            self._fp.write(line + "\n")
        self._fp.flush()

    def append_alerts(self, alerts: Iterable[str]) -> None:
        alerts = list(alerts)
        if not alerts:
            return
        self._fp.write("\nAlerts:\n")
        for line in alerts:
            self._fp.write(line + "\n")
        self._fp.flush()

    def close(self) -> None:
        try:
            self._fp.flush()
        finally:
            self._fp.close()
