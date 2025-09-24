from __future__ import annotations

from pathlib import Path
from typing import List, Tuple

from .render import render_table
from .util import atomic_write_text, ensure_dir


def write_text_report(
    circuit,
    target_display: str,
    alerts: List[Tuple[int, str, int, str]],  # (ttl, addr_display, lost_count, time_str)
    outdir: Path,
    ascii_mode: bool = False,
) -> Path:
    ensure_dir(outdir)
    # table as text
    table_text = render_table(circuit, target_display, circuit.started_at, ascii_mode=ascii_mode, wide=False)

    lines = [table_text, ""]
    lines.append("Alerts:")
    if alerts:
        for ttl, addr_disp, lost, ts in alerts:
            lines.append(f"❌ Packet loss detected on hop {ttl} ({addr_disp}) at {ts} - {lost} packets lost")
    else:
        lines.append("None")

    content = "\n".join(lines)
    out_path = outdir / circuit.filename
    atomic_write_text(out_path, content)
    return out_path
