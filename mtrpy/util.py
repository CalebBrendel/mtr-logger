from __future__ import annotations
import asyncio
import os
import socket
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from shutil import which as _which
from typing import Iterable, Optional

IS_WINDOWS = sys.platform.startswith("win")


# ---------- filesystem helpers ----------

def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def default_log_dir() -> Path:
    # Keep behavior consistent with earlier versions
    base = Path.home() / "mtr" / "logs"
    ensure_dir(base)
    return base


def timestamp_filename(prefix: str = "mtr", ext: str = ".txt") -> str:
    # mtr-09-24-2025-01-51-57.txt
    ts = datetime.now().strftime("%m-%d-%Y-%H-%M-%S")
    return f"{prefix}-{ts}{ext}"


# ---------- time formatting ----------

def now_local_str(time_only: bool = False) -> str:
    """
    Return current local time as:
      - time_only=True: '1:02:11PM'
      - else: '09-24-2025 1:02:11PM'
    """
    now = datetime.now()
    if time_only:
        s = now.strftime("%I:%M:%S%p")
        # drop leading zero from hour
        return s.lstrip("0")
    return f"{now.strftime('%m-%d-%Y')} {now.strftime('%I:%M:%S%p').lstrip('0')}"


# ---------- process helpers ----------

async def run_proc(*args: str, timeout: Optional[float] = None) -> tuple[bytes, bytes, int]:
    """
    Run a subprocess, capture stdout/stderr, with optional timeout.
    Returns (stdout_bytes, stderr_bytes, returncode).
    """
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        # Best effort: terminate and wait briefly
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise
    return out_b, err_b, proc.returncode


def which(candidates: Iterable[str] | str) -> Optional[str]:
    if isinstance(candidates, str):
        return _which(candidates)
    for c in candidates:
        p = _which(c)
        if p:
            return p
    return None


# ---------- DNS/host resolution ----------

@dataclass
class ResolvedHost:
    ip: str        # IPv4/IPv6 numeric
    display: str   # what to show in UI/title (hostname if given, else ip)


def resolve_host(target: str, dns_mode: str = "auto") -> ResolvedHost:
    """
    Resolve to a numeric IP for probing, and decide display string.
    dns_mode:
      - 'off': never do reverse names here (display is the input target or ip)
      - 'on' : prefer names for display when available
      - 'auto': keep given name for display if it wasn't a numeric IP
    """
    # Forward resolution: prefer IPv4 first, else whatever comes first
    ip = None
    try:
        # getaddrinfo(None) fallback avoided; we must resolve target
        infos = socket.getaddrinfo(target, None)
        # prefer AF_INET
        infos_sorted = sorted(infos, key=lambda x: 0 if x[0] == socket.AF_INET else 1)
        for family, _type, _proto, _canon, sockaddr in infos_sorted:
            if family in (socket.AF_INET, socket.AF_INET6):
                ip = sockaddr[0]
                break
    except Exception:
        # if target already appears numeric, keep it
        ip = target

    if ip is None:
        ip = target

    # Decide display string
    disp = target
    if dns_mode == "off":
        disp = ip
    else:
        # 'on' and 'auto' -> keep original hostname if it isn't an IP literal
        # naive check: if it has letters, it's likely a hostname
        if all(ch.isdigit() or ch in ".:[]" for ch in target):
            disp = ip

    return ResolvedHost(ip=ip, display=disp)
