from __future__ import annotations

import os
import io
from datetime import datetime
from typing import Iterable

# --- helpers ---------------------------------------------------------------

def _fmt_ms(v: float | None) -> str:
    return f"{v:.1f}" if v is not None else "-"

def _fmt_time_12h(dt: datetime) -> str:
    # e.g. "1:02:11PM"
    return dt.strftime("%I:%M:%S%p").lstrip("0")

def _build_table_lines(circuit, target: str, started_ts: float) -> list[str]:
    """
    Build the plain-text MTR-style table as a list of lines (without trailing \n).
    We don't rely on circuit.as_rows(); we iterate its internal hops map.
    """
    # Header
    lines: list[str] = []
    title = f" Hop  Address                                     Loss%  Snt  Recv   Avg  Best   Wrst"
    sep   = f" ---  ------------------------------------------  -----  ----  ----  ----  ----  -----"
    lines.append(title)
    lines.append(sep)

    # Body: hop stats in numeric TTL order
    # circuit.hops is expected to be Dict[int, HopStat]
    for ttl in sorted(circuit.hops.keys()):
        hop = circuit.hops[ttl]
        address = hop.address or "*"
        sent = hop.sent
        recv = hop.recv
        loss = 0 if sent == 0 else int(round(sent - recv))
        loss_pct = 0.0 if sent == 0 else (100.0 * (1.0 - (recv / sent)))

        # Widths chosen to match your previous log format
        #   Hop: 3 right
        #   Address: 42 left
        #   Loss%: 5 right (integer)
        #   Snt/Recv: 4 right
        #   Avg/Best/Wrst: 4 right (strings; '-' or N.N)
        line = (
            f"{ttl:>3}  "
            f"{address:<42}  "
            f"{int(round(loss_pct)):>5}  "
            f"{sent:>4}  "
            f"{recv:>4}  "
            f"{_fmt_ms(hop.avg_ms):>4}  "
            f"{_fmt_ms(hop.best_ms):>4}  "
            f"{_fmt_ms(hop.worst_ms):>5}"
        )
        lines.append(line)

    return lines

def _build_alert_lines(circuit) -> list[str]:
    """
    Build the 'Alerts:' section lines. Writes one line per hop that shows any loss
    observed at report time (repeats are fine by design).
    """
    lines: list[str] = []
    now_str = _fmt_time_12h(datetime.now())
    for ttl in sorted(circuit.hops.keys()):
        hop = circuit.hops[ttl]
        lost = max(0, hop.sent - hop.recv)
        if lost > 0 and (hop.address or "*") != "*":
            lines.append(f"❌ Packet loss detected on hop {ttl} at {now_str} - {lost} packets were lost")
    return lines

def _atomic_write_text(path: str, text: str) -> None:
    """
    Write to path atomically:
      - write to path.tmp
      - flush + fsync
      - os.replace(tmp, path)
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    # Use utf-8, no BOM
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)

# --- public API ------------------------------------------------------------

def write_text_report(path: str, circuit, target: str, started_ts: float) -> None:
    """
    Build the final plain-text report (table + Alerts) and write it atomically.
    Signature matches cli.py: write_text_report(out_path, circuit, display_target, started)
    """
    buf = io.StringIO()
    # Table
    for line in _build_table_lines(circuit, target, started_ts):
        buf.write(line)
        buf.write("\n")

    # Alerts section
    alerts = _build_alert_lines(circuit)
    if alerts:
        buf.write("\nAlerts:\n")
        for line in alerts:
            buf.write(line)
            buf.write("\n")

    _atomic_write_text(path, buf.getvalue())


# Optional: a simple helper you can call from the loop if you decide to append
# “live” alert lines to a sidecar file. Not used by cli.py unless you wire it in.
def append_alert_line(alert_file: str, line: str) -> None:
    os.makedirs(os.path.dirname(alert_file) or ".", exist_ok=True)
    with open(alert_file, "a", encoding="utf-8", newline="\n") as f:
        f.write(line.rstrip("\n"))
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
