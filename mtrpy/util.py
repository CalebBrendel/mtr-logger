# src/mtrpy/util.py
from __future__ import annotations

import asyncio
import os
import platform
import shutil
import socket
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional, Sequence, Tuple

# ---------- Platform ----------

IS_WINDOWS: bool = platform.system().lower().startswith("win")


# ---------- Paths & Directories ----------

def user_home() -> Path:
    """Best-effort home directory across platforms and services."""
    home = (
        os.environ.get("USERPROFILE")
        or os.environ.get("HOME")
        or "~"
    )
    return Path(home).expanduser()


def default_log_dir() -> Path:
    """
    Default per-user log directory:
      - Windows:  %USERPROFILE%/mtr/logs
      - Unix:     $HOME/mtr/logs
    """
    return user_home() / "mtr" / "logs"


def default_archive_dir() -> Path:
    """Archive folder lives under the normal logs folder."""
    return default_log_dir() / "archive"


def ensure_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    return p


# ---------- Time / Filenames ----------

TIMESTAMP_FMT = "%m-%d-%Y-%H-%M-%S"      # used in filenames, e.g. mtr-09-23-2025-13-02-11.txt
HUMAN_TIME_12H_FMT = "%I:%M:%S%p"        # e.g. 01:02:11PM

def timestamp_now() -> str:
    return datetime.now().strftime(TIMESTAMP_FMT)


def human_time_now_12h() -> str:
    return datetime.now().strftime(HUMAN_TIME_12H_FMT)


def auto_outfile_path(base_dir: Optional[Path] = None, prefix: str = "mtr") -> Path:
    """
    Build an auto-named logfile path like:
      ~/mtr/logs/mtr-09-23-2025-13-02-11.txt
    """
    base = base_dir or default_log_dir()
    ensure_dir(base)
    name = f"{prefix}-{timestamp_now()}.txt"
    return base / name


# ---------- DNS / Target helpers ----------

@dataclass(frozen=True)
class ResolvedTarget:
    """Minimal resolution info for a target passed on the CLI."""
    input: str           # what user typed (hostname or IP)
    host_for_display: str  # for headings; typically the original input
    ip: str             # first resolved IP (prefers IPv4)


def _first_ip(addrs: Sequence[Tuple]) -> Optional[str]:
    # Prefer IPv4, then IPv6
    v4 = next((a[4][0] for a in addrs if a[0] == socket.AF_INET), None)
    if v4:
        return v4
    v6 = next((a[4][0] for a in addrs if a[0] == socket.AF_INET6), None)
    return v6


def resolve_host(target: str) -> ResolvedTarget:
    """
    Resolve a hostname/IP to a usable IP string, keeping the original string
    for display. We do NOT force reverse lookups here; hop name resolution is
    handled elsewhere (e.g., tracer output).
    """
    host_for_display = target
    ip = target

    try:
        # If it's already an IP, getaddrinfo still works and normalizes it.
        addrs = socket.getaddrinfo(target, None)
        first = _first_ip(addrs)
        if first:
            ip = first
    except Exception:
        # Fall back to whatever the user typed; let the caller handle errors.
        pass

    return ResolvedTarget(input=target, host_for_display=host_for_display, ip=ip)


# ---------- Executables & Subprocess ----------

def which(cmds: Iterable[str]) -> Optional[str]:
    """
    Return the first existing executable path from a list of candidate names.
    Example:
        which(["traceroute", "tracepath"]) -> "/usr/bin/traceroute" or None
    """
    for c in cmds:
        p = shutil.which(c)
        if p:
            return p
    return None


async def run_proc(
    cmd: Sequence[str],
    timeout: Optional[float] = None,
    cwd: Optional[Path] = None,
    env: Optional[dict] = None,
) -> Tuple[int, str, str]:
    """
    Run a subprocess asynchronously, capturing stdout/stderr as text.
    Returns (returncode, stdout, stderr).
    """
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        finally:
            raise
    rc = proc.returncode
    stdout = stdout_b.decode(errors="replace") if stdout_b is not None else ""
    stderr = stderr_b.decode(errors="replace") if stderr_b is not None else ""
    return rc, stdout, stderr
