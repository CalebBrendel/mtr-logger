from __future__ import annotations
import asyncio
import contextlib
import os
import socket
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from shutil import which as _which
from typing import Iterable, Optional, Union

IS_WINDOWS = sys.platform.startswith("win")


# ---------- filesystem helpers ----------

def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def default_log_dir() -> Path:
    """
    Default logs directory under ~/mtr/logs, created if missing.
    """
    base = Path.home() / "mtr" / "logs"
    ensure_dir(base)
    return base


def timestamp_filename(prefix: str = "mtr", ext: str = ".txt") -> str:
    """
    Return a filename like: mtr-09-24-2025-01-51-57.txt
    """
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
        return s.lstrip("0")  # drop leading zero from hour
    return f"{now.strftime('%m-%d-%Y')} {now.strftime('%I:%M:%S%p').lstrip('0')}"


# ---------- atomic file write ----------

def atomic_write_text(path: Union[str, Path], text: str) -> None:
    """
    Atomically write text to a file:
      1) write to temp file in the same directory
      2) fsync
      3) os.replace to final path
    Safe against partial writes if the system crashes mid-write.
    """
    path = Path(path)
    ensure_dir(path.parent)
    fd, tmppath = tempfile.mkstemp(prefix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmppath, str(path))
    finally:
        with contextlib.suppress(FileNotFoundError):
            if os.path.exists(tmppath):
                os.unlink(tmppath)


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
      - 'off': never do reverse names here (display is the ip)
      - 'on' : prefer names for display when available (handled later in CLI)
      - 'auto': keep given hostname for display if it isn't a numeric IP
    """
    ip = None
    try:
        infos = socket.getaddrinfo(target, None)
        # prefer IPv4 over IPv6 if available
        infos_sorted = sorted(infos, key=lambda x: 0 if x[0] == socket.AF_INET else 1)
        for family, _type, _proto, _canon, sockaddr in infos_sorted:
            if family in (socket.AF_INET, socket.AF_INET6):
                ip = sockaddr[0]
                break
    except Exception:
        ip = target

    if ip is None:
        ip = target

    # decide display
    if dns_mode == "off":
        disp = ip
    else:
        # keep original hostname if it isn't an IP literal
        disp = target if any(ch.isalpha() for ch in target) else ip

    return ResolvedHost(ip=ip, display=disp)
