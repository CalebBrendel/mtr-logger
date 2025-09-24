from __future__ import annotations

import os
import shutil
import socket
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional

# -------- Platform helpers --------
IS_WINDOWS = os.name == "nt"


# -------- Filesystem helpers --------
def home_dir() -> Path:
    """Cross-platform home dir (Linux: /home/$USER, Windows: %USERPROFILE%)."""
    return Path(os.path.expanduser("~")).resolve()


def default_log_dir() -> Path:
    """
    Default log directory:
      - Linux/macOS:  ~/mtr/logs
      - Windows:      %USERPROFILE%\\mtr\\logs
    """
    root = home_dir() / "mtr" / "logs"
    return root


def ensure_dir(p: Path) -> Path:
    """Create directory if needed and return it."""
    p.mkdir(parents=True, exist_ok=True)
    return p


def timestamp_filename(prefix: str = "mtr", ext: str = ".txt") -> str:
    """mtr-09-24-2025-01-02-03.txt"""
    ts = datetime.now().strftime("%m-%d-%Y-%H-%M-%S")
    return f"{prefix}-{ts}{ext}"


def now_local_str() -> str:
    """Current local time as HH:MM:SSAM/PM (no date)."""
    return datetime.now().strftime("%I:%M:%S%p").lstrip("0")


# -------- Process / PATH helpers --------
def which(candidates: Iterable[str]) -> Optional[str]:
    """
    Find the first executable on PATH from a list of names.
    Returns absolute path or None.
    """
    for name in candidates:
        path = shutil.which(name)
        if path:
            return path
    return None


# -------- DNS / target helpers --------
@dataclass
class ResolvedTarget:
    ip: str        # numeric IP we will probe (IPv4 preferred)
    display: str   # how to display the target in UI/headers


def _first_ipv4(host: str) -> Optional[str]:
    """Best-effort IPv4 selection for traceroute compatibility."""
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
        for family, _stype, _proto, _canon, sockaddr in infos:
            if family == socket.AF_INET:
                return sockaddr[0]
    except socket.gaierror:
        return None
    return None


def resolve_host(target: str, dns_mode: str = "auto") -> ResolvedTarget:
    """
    Resolve the target into an IP we can pass to traceroute/tcptraceroute.
    - If target is already a dotted quad, use it.
    - Otherwise prefer IPv4 from DNS.
    - display:
        * if user passed a hostname, show that
        * if user passed an IP, show that IP
    """
    # Already IPv4?
    try:
        socket.inet_aton(target)
        return ResolvedTarget(ip=target, display=target)
    except OSError:
        pass

    ip = _first_ipv4(target)
    if not ip:
        # Last resort: try generic resolution (any family), use first address text
        try:
            infos = socket.getaddrinfo(target, None)
            if infos:
                ip = infos[0][4][0]
        except socket.gaierror as _e:
            ip = target  # allow downstream to fail with clearer message

    # Show the hostname the user typed if it looked like one, else the IP
    display = target if any(c.isalpha() for c in target) else ip
    return ResolvedTarget(ip=ip, display=display)
