from __future__ import annotations
import os
import shutil
from datetime import datetime, timedelta

from .util import default_log_dir, ensure_dir


def archive_root() -> str:
    root = os.path.join(default_log_dir(), "archive")
    ensure_dir(root)
    return root


def move_logs_to_archive(day_folder: str | None = None) -> str:
    today = datetime.now().strftime("%m-%d-%Y") if day_folder is None else day_folder
    src_dir = default_log_dir()
    dst_dir = os.path.join(archive_root(), today)
    ensure_dir(dst_dir)

    for name in os.listdir(src_dir):
        if not name.lower().endswith(".txt"):
            continue
        src = os.path.join(src_dir, name)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(dst_dir, name)
        try:
            shutil.move(src, dst)
        except Exception:
            pass
    return dst_dir


def delete_old_archives(retention_days: int = 90) -> None:
    root = archive_root()
    now = datetime.now()
    for name in os.listdir(root):
        p = os.path.join(root, name)
        if not os.path.isdir(p):
            continue
        try:
            dt = datetime.strptime(name, "%m-%d-%Y")
        except ValueError:
            continue
        if (now - dt) > timedelta(days=retention_days):
            shutil.rmtree(p, ignore_errors=True)


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="mtr-logger archiver")
    ap.add_argument("--retention", type=int, default=90, help="Days to retain archived folders")
    args = ap.parse_args(argv)
    d = move_logs_to_archive()
    delete_old_archives(args.retention)
    print(d)


if __name__ == "__main__":
    main()
