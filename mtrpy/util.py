from __future__ import annotations

import asyncio
import contextlib
import os
import socket
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from shutil import which as _which
from typing import Iterable, Optional

IS_WINDOWS = sys.platform.startswith("win")


# ---------------- Filesystem helpers ----------------

def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def default_log_dir() -> Path:
    base = Path.home() / "mtr" / "logs"
    ensure_dir(base)
    return base


def timestamp_filename(prefix: str = "mtr", ext: str = ".txt") -> str:
    # mtr-09-24-2025-01-51-57.txt
    ts = datetime.now().strftime("%m-%d-%Y-%H-%M-%S")
    return f"{prefix}-{ts}{ext}"


def atomic_write_text(path: Path, text: str) -> None:
    """Safely write text by using a temporary file and atomic rename."""
    ensure_dir(path.parent)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent)) as tmp:
        tmp.write(text)
        tmp_path = Path(tmp.name)
    tmp_path.replace(path)


# ---------------- Time helpers ----------------

def now_local_str(time_only: bool = False) -> str:
    """
    Return current local time as:
      - time_only=True: '1:02:11PM'
      - else: '09-24-2025 1:02:11PM'
    """
    now = datetime.now()
    if time_only:
        s = now.strftime("%I:%M:%S%p")
        return s.lstrip("0")
    return f"{now.strftime('%m-%d-%Y')} {now.strftime('%I:%M:%S%p').lstrip('0')}"


# ---------------- Process / system helpers ----------------

async def run_proc(*args: str, timeout: Optional[float] = None) -> tuple[bytes, bytes, int]:
    """Run a subprocess, capture stdout/stderr, with optional timeout."""
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
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


# ---------------- DNS helpers ----------------

def is_ip_literal(s: str) -> bool:
    try:
        socket.inet_pton(socket.AF_INET, s)
        return True
    except OSError:
        pass
    with contextlib.suppress(OSError, ValueError):
        socket.inet_pton(socket.AF_INET6, s)
        return True
    return False


@dataclass
class ResolvedHost:
    ip: str        # numeric IP for probing
    display: str   # what to show as target title


def resolve_host(target: str, dns_mode: str = "auto") -> ResolvedHost:
    """Resolve forward to an IP, and decide display string."""
    ip = None
    try:
        infos = socket.getaddrinfo(target, None)
        # prefer IPv4
        infos_sorted = sorted(infos, key=lambda x: 0 if x[0] == socket.AF_INET else 1)
        for family, _type, _proto, _canon, sockaddr in infos_sorted:
            if family in (socket.AF_INET, socket.AF_INET6):
                ip = sockaddr[0]
                break
    except Exception:
        ip = target

    if ip is None:
        ip = target

    # display
    if dns_mode == "off":
        display = ip
    elif dns_mode == "on":
        display = target if not is_ip_literal(target) else ip
    else:  # auto
        display = target if not is_ip_literal(target) else ip

    return ResolvedHost(ip=ip, display=display)


class ReverseDNSCache:
    """Very small async reverse-DNS cache to avoid blocking UI too long."""
    def __init__(self) -> None:
        self.cache: dict[str, str] = {}  # ip -> name
        self.pending: set[str] = set()

    async def lookup(self, ip: Optional[str]) -> Optional[str]:
        if not ip or is_ip_literal(ip) is False:
            return ip
        if ip in self.cache:
            return self.cache[ip]
        if ip in self.pending:
            return ip  # return ip until finished

        loop = asyncio.get_running_loop()
        self.pending.add(ip)

        def _do():
            try:
                name, _alias, _addrs = socket.gethostbyaddr(ip)
                return name
            except Exception:
                return None

        name = await loop.run_in_executor(None, _do)
        self.pending.discard(ip)
        if name:
            self.cache[ip] = name
            return name
        return ip  # fallback to ip if no PTR
