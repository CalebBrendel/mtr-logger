from __future__ import annotations
import os
from typing import List
from datetime import datetime

from .stats import Circuit, HopStat
from .util import default_log_dir, ensure_dir, timestamp_filename


def _fmt(v):
    return "-" if v is None else f"{v:.1f}"


def _row(h: HopStat) -> str:
    return f"{h.ttl:>3}  {(h.address or '*'):<42}  {h.loss_pct:>5.0f}  {h.sent:>4}  {h.recv:>4}  {_fmt(h.avg_ms):>4}  {_fmt(h.best_ms):>4}  {_fmt(h.worst_ms):>5}"


def export_report(circuit: Circuit, target: str, outfile: str | None, order: str = "hop", wide: bool = False) -> str:
    # path prep
    if outfile in (None, "", "auto"):
        outdir = default_log_dir()
        ensure_dir(outdir)
        path = os.path.join(outdir, timestamp_filename("mtr"))
    else:
        path = outfile
        ensure_dir(os.path.dirname(os.path.abspath(path)))

    # build body
    lines: List[str] = []
    lines.append(" Hop  Address                                     Loss%   Snt  Recv   Avg  Best   Wrst")
    lines.append(" ---  ------------------------------------------  -----  ----  ----  ----  ----  -----")

    # stable order by ttl
    for ttl in sorted(circuit.hops.keys()):
        hs = circuit.hops[ttl]
        lines.append(_row(hs))

    # alerts (ignore '*' hop)
    alerts: List[str] = []
    tstr = datetime.now().strftime("%I:%M:%S%p").lstrip("0")
    for ttl in sorted(circuit.hops.keys()):
        hs = circuit.hops[ttl]
        if hs.address in (None, "*"):
            continue
        lost = max(0, hs.sent - hs.recv)
        if lost > 0:
            alerts.append(f"❌ Packet loss detected on hop {ttl} at {tstr} - {lost} packets were lost")

    if alerts:
        lines.append("")
        lines.append("Alerts:")
        lines.extend(alerts)

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    return path
