from __future__ import annotations
from typing import Callable, List, Tuple
from datetime import datetime
from .stats import Circuit

# Field code -> (Header, extractor)
# Order semantics follow mtr: L S R A B W
FIELD_MAP: dict[str, Tuple[str, Callable]] = {
    "L": ("Loss%", lambda r: f"{r.loss_pct:.0f}"),
    "S": ("Snt",   lambda r: f"{r.sent}"),
    "R": ("Recv",  lambda r: f"{r.recv}"),
    "A": ("Avg",   lambda r: "-" if r.avg_ms   is None else f"{r.avg_ms:.1f}"),
    "B": ("Best",  lambda r: "-" if r.best_ms  is None else f"{r.best_ms:.1f}"),
    "W": ("Wrst",  lambda r: "-" if r.worst_ms is None else f"{r.worst_ms:.1f}"),
}

DEFAULT_ORDER = "LSRABW"

def _truncate(s: str, maxlen: int) -> str:
    if len(s) <= maxlen:
        return s
    if maxlen <= 1:
        return s[:maxlen]
    # keep as much as possible and add ellipsis
    return s[: maxlen - 1] + "…"

def render_report(
    circuit: Circuit,
    order: str = DEFAULT_ORDER,
    wide: bool = False,
    addr_min: int = 12,
    addr_max: int = 46,
) -> str:
    """
    Returns a neatly aligned text table and an 'Alerts' footer for hops with packet loss.
    - Address column grows to fit data up to addr_max (trim w/ ellipsis beyond that).
    - Numeric columns sized to longest datum or header, right-aligned.
    - 'wide' currently keeps same structure; TUI handles true wide view.
    """
    # Column spec: Hop, Address, then fields per 'order'
    cols: List[Tuple[str, Callable, str]] = []  # (header, extractor(row), align "<" or ">")
    cols.append(("Hop",     lambda r: f"{r.ttl}",             ">"))  # numeric
    cols.append(("Address", lambda r: r.address or "*",       "<"))  # left aligned
    for ch in order:
        meta = FIELD_MAP.get(ch.upper())
        if meta:
            hdr, fn = meta
            cols.append((hdr, fn, ">"))

    # Gather rows from stats
    rows = circuit.as_rows()

    # Determine Address width dynamically (respect min/max)
    if rows:
        addr_values = [(r.address or "*") for r in rows]
        addr_width = max(addr_min, len("Address"), *(len(v) for v in addr_values))
    else:
        addr_width = max(addr_min, len("Address"))
    addr_width = min(addr_width, addr_max)

    # Compute widths for all columns
    widths: List[int] = []
    for (hdr, fn, _align) in cols:
        if hdr == "Address":
            w = addr_width
        else:
            if hdr == "Hop":
                vals = [f"{r.ttl}" for r in rows]
            else:
                vals = [str(fn(r)) for r in rows]
            w = max(len(hdr), *(len(v) for v in vals)) if rows else len(hdr)
        widths.append(w)

    # Build row format string
    parts = []
    for (hdr, _fn, align), w in zip(cols, widths):
        parts.append(f"{{:{align}{w}}}")
    row_fmt = "  ".join(parts)

    # Header line
    headers = []
    for (hdr, _fn, _align), w in zip(cols, widths):
        headers.append(f"{hdr:{'>' if hdr not in ('Address','Hop') else '<'}{w}}")
    lines = ["  ".join(headers)]

    # Data lines (truncate Address if needed)
    for r in rows:
        vals: List[str] = []
        for (hdr, fn, _align), w in zip(cols, widths):
            if hdr == "Address":
                addr = r.address or "*"
                vals.append(_truncate(addr, w))
            elif hdr == "Hop":
                vals.append(f"{r.ttl}")
            else:
                vals.append(str(fn(r)))
        lines.append(row_fmt.format(*vals))

    # --- Alerts footer: list any hops with packet loss ---
    alert_lines: List[str] = []
    for r in rows:
        # Determine lost packets from Snt/Recv
        try:
            sent = int(getattr(r, "sent", 0))
            recv = int(getattr(r, "recv", 0))
        except (TypeError, ValueError):
            sent, recv = 0, 0
        lost = max(0, sent - recv)
        if lost > 0:
            ts = datetime.now().strftime("%I:%M:%S%p")  # 12-hour with AM/PM
            alert_lines.append(f"❌ Packet loss detected on hop {r.ttl} at {ts} - {lost} packets were lost")

    if alert_lines:
        lines.append("")  # blank line
        lines.append("Alerts:")
        lines.extend(alert_lines)

    return "\n".join(lines) + "\n"
