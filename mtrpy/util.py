from __future__ import annotations
import os
import socket
from dataclasses import dataclass
from typing import Optional

IS_WINDOWS = (os.name == "nt")


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def default_log_dir() -> str:
    # Linux/mac: ~/mtr/logs ; Windows: %USERPROFILE%\mtr\logs
    home = os.path.expanduser("~")
    base = os.path.join(home, "mtr", "logs")
    ensure_dir(base)
    return base


def timestamp_filename(prefix: str = "mtr", ext: str = ".txt") -> str:
    # mtr-MM-DD-YYYY-HH-MM-SS.txt
    from datetime import datetime
    stamp = datetime.now().strftime("%m-%d-%Y-%H-%M-%S")
    return f"{prefix}-{stamp}{ext}"


@dataclass
class Resolved:
    name: str
    ip: str
    display: str


async def resolve_host(target: str, mode: str = "auto") -> Resolved:
    """
    mode: auto|on|off
      - auto: show hostnames if initial target is hostname else show IPs
      - on: always reverse resolve
      - off: never reverse resolve
    """
    try:
        # resolve A/AAAA
        ai = socket.getaddrinfo(target, None, proto=socket.IPPROTO_TCP)
        ip = ai[0][4][0]
    except Exception:
        # maybe already an IP
        ip = target

    # decide display target
    if mode == "off":
        display = ip
        name = target
    elif mode == "on":
        try:
            name = socket.gethostbyaddr(ip)[0]
        except Exception:
            name = ip
        display = name
    else:  # auto
        # if user typed a hostname (contains letters), keep name; else IP
        is_name = any(c.isalpha() for c in target)
        if is_name:
            display = target
            name = target
        else:
            display = ip
            name = target

    return Resolved(name=name, ip=ip, display=display)


def which(cmds) -> Optional[str]:
    if isinstance(cmds, str):
        cmds = [cmds]
    paths = os.environ.get("PATH", "").split(os.pathsep)
    for c in cmds:
        for d in paths:
            p = os.path.join(d, c)
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
    return None
