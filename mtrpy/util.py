from __future__ import annotations

import asyncio
import os
import platform
import shutil
import socket
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional, Tuple

IS_WINDOWS = platform.system().lower().startswith("win")

def default_log_dir() -> Path:
    # Linux/macOS: ~/mtr/logs ; Windows: %USERPROFILE%\mtr\logs
    home = Path(os.environ.get("USERPROFILE") or os.environ.get("HOME") or str(Path.cwd()))
    return home / "mtr" / "logs"

def ensure_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    return p

def timestamp_filename(prefix: str = "mtr", ext: str = ".txt") -> Path:
    ts = datetime.now().strftime("%m-%d-%Y-%H-%M-%S")
    return Path(f"{prefix}-{ts}{ext}")

def auto_outfile_path(base_dir: Path, prefix: str = "mtr") -> Path:
    ensure_dir(base_dir)
    return base_dir / timestamp_filename(prefix=prefix)

@dataclass
class ResolvedHost:
    input: str
    ip: str

def resolve_host(target: str) -> ResolvedHost:
    # Prefer IPv4 where possible; fall back to AF_UNSPEC
    try:
        infos = socket.getaddrinfo(target, None, socket.AF_INET, 0, 0, socket.AI_ADDRCONFIG)
    except Exception:
        infos = socket.getaddrinfo(target, None, 0, 0, 0)
    ip = None
    for fam, _type, _proto, _canon, sockaddr in infos:
        ip = sockaddr[0]
        if fam == socket.AF_INET:
            break
    if not ip:
        ip = target  # last resort
    return ResolvedHost(input=target, ip=ip)

def which(cmds: Iterable[str]) -> Optional[str]:
    for c in cmds:
        path = shutil.which(c)
        if path:
            return path
    return None

async def run_proc(cmd: Iterable[str], timeout: float = 5.0) -> Tuple[int, str, str]:
    """Run a subprocess and return (rc, stdout, stderr) as strings."""
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        finally:
            return (124, "", "timeout")
    return (proc.returncode or 0, (out_b or b"").decode("utf-8", "replace"), (err_b or b"").decode("utf-8", "replace"))
