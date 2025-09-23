from __future__ import annotations
import asyncio
import platform
import shutil
from pathlib import Path
from datetime import datetime
from typing import Iterable

IS_WINDOWS = platform.system().lower().startswith("win")

async def which(cmds: Iterable[str]) -> str | None:
    for c in cmds:
        p = shutil.which(c)
        if p:
            return p
    return None

async def run_proc(cmd: list[str], timeout: float | None = None) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        creationflags=(0x08000000 if IS_WINDOWS else 0),  # CREATE_NO_WINDOW on Windows
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise
    return proc.returncode, out.decode(errors="ignore"), err.decode(errors="ignore")

def default_log_dir() -> Path:
    home = Path.home()
    return (home / "mtr" / "logs").resolve()

def ensure_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    return p

def timestamp_filename(prefix: str = "mtr-", ext: str = ".txt") -> str:
    ts = datetime.now().strftime("%m-%d-%Y-%H-%M-%S")
    return f"{prefix}{ts}{ext}"
