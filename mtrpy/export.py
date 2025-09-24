from __future__ import annotations

from pathlib import Path
from typing import Iterable, List

from .stats import Circuit, HopStat


# ---------- formatting helpers ----------

HEADERS = ("Hop", "Address", "Loss%", "Snt", "Recv", "Avg", "Best", "Wrst")

# column widths tuned to match your existing logs
W = {
    "hop": 3,
    "addr": 42,
    "loss": 5,
    "snt": 4,
    "recv": 4,
    "avg": 4,
    "best": 4,
    "wrst": 5,
}


def _fmt_ms(v: float | None) -> str:
    return "-" if v is None else f"{v:.1f}"


def _fmt_addr(addr: str | None) -> str:
    return "*" if not addr else addr


def _rows(circuit: Circuit) -> Iterable[HopStat]:
    # circuit.hops: Dict[int, HopStat]
    for ttl in sorted(circuit.hops.keys()):
        yield circuit.hops[ttl]


def _table_text(circuit: Circuit) -> str:
    # header
    line1 = (
        f"{HEADERS[0]:>{W['hop']}}  "
        f"{HEADERS[1]:<{W['addr']}}  "
        f"{HEADERS[2]:>{W['loss']}}  "
        f"{HEADERS[3]:>{W['snt']}}  "
        f"{HEADERS[4]:>{W['recv']}}  "
        f"{HEADERS[5]:>{W['avg']}}  "
        f"{HEADERS[6]:>{W['best']}}  "
        f"{HEADERS[7]:>{W['wrst']}}"
    )

    line2 = (
        f"{'-'*W['hop']:>{W['hop']}}  "
        f"{'-'*W['addr']:<{W['addr']}}  "
        f"{'-'*W['loss']:>{W['loss']}}  "
        f"{'-'*W['snt']:>{W['snt']}}  "
        f"{'-'*W['recv']:>{W['recv']}}  "
        f"{'-'*W['avg']:>{W['avg']}}  "
        f"{'-'*W['best']:>{W['best']}}  "
        f"{'-'*W['wrst']:>{W['wrst']}}"
    )

    body_lines: List[str] = []
    for hop in _rows(circuit):
        body_lines.append(
            f"{hop.ttl:>{W['hop']}}  "
            f"{_fmt_addr(hop.address):<{W['addr']}}  "
            f"{int(round(hop.loss_pct)):>{W['loss']}}  "
            f"{hop.sent:>{W['snt']}}  "
            f"{hop.recv:>{W['recv']}}  "
            f"{_fmt_ms(hop.avg_ms):>{W['avg']}}  "
            f"{_fmt_ms(hop.best_ms):>{W['best']}}  "
            f"{_fmt_ms(hop.worst_ms):>{W['wrst']}}"
        )

    return "\n".join([line1, line2, *body_lines])


# ---------- alert helpers ----------

def _loss_alert_lines(
    circuit: Circuit,
    *,
    ignore_unroutable: bool = True,
) -> List[str]:
    """Create 12-hour time alert lines for any hop with loss>0 during the run.
    NOTE: we do not add the timestamp here; cli.py typically adds the time for interactive alerts,
    while for exports we make one line per hop at the *end* using the final totals.
    """
    # We only need (ttl, lost) and whether to ignore '*'
    lines: List[str] = []
    for hop in _rows(circuit):
        addr = hop.address or "*"
        if ignore_unroutable and addr == "*":
            continue
        lost = hop.sent - hop.recv
        if lost > 0:
            # time stamp is appended by caller (cli) when desired; for export we keep the shorter format
            # but if cli passes a formatted time string, we’ll include it.
            # To keep backward compatibility, we just output without time here; cli can prepend it.
            lines.append((hop.ttl, lost))
    # convert to human lines later (we keep ttl,lost for flexibility)
    return [f"❌ Packet loss detected on hop {ttl} - {lost} packets were lost" for (ttl, lost) in lines]


# ---------- public API ----------

def write_text_report(
    circuit: Circuit,
    target_display: str,
    outfile_path: Path | str,
    *,
    append_alerts: bool = True,
    ignore_unroutable: bool = True,
    header_title: str | None = None,
) -> Path:
    """
    Write a plain-text report to 'outfile_path'.

    Parameters
    ----------
    circuit : Circuit
        Accumulated hop stats.
    target_display : str
        What to show in the title line (e.g. 'google.ca' or '8.8.8.8').
    outfile_path : Path | str
        Destination file path. Parent directories will be created.
    append_alerts : bool
        If True, append an 'Alerts:' section with one line per hop that had loss.
    ignore_unroutable : bool
        Skip hops whose address is '*' in the alerts section.
    header_title : Optional[str]
        If provided, use this instead of the default title line.
    """
    path = Path(outfile_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    title = header_title or f" mtr-logger → {target_display} "
    # build text
    header = title.rstrip()
    table = _table_text(circuit)

    lines = [table]
    if append_alerts:
        alerts = _loss_alert_lines(circuit, ignore_unroutable=ignore_unroutable)
        lines.append("")
        lines.append("Alerts:")
        if alerts:
            lines.extend(alerts)
        else:
            lines.append("None")

    content = f"{header}\n\n{'\n'.join(lines)}\n"

    path.write_text(content, encoding="utf-8")
    return path
