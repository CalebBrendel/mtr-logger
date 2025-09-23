# src/mtrpy/archiver.py
from __future__ import annotations

import argparse
import datetime as dt
import os
import shutil
from pathlib import Path

from .util import default_log_dir

# ---- Config helpers ----

def default_archive_dir() -> Path:
    """Archive directory under the normal logs folder."""
    return default_log_dir() / "archive"

# ---- Core operations ----

def move_logs_to_archive(log_dir: Path, archive_dir: Path, when: dt.datetime | None = None) -> Path:
    """
    Move all .txt logs from log_dir into a dated subfolder under archive_dir.
    The folder name is MM-DD-YYYY (local time). Returns the created archive path.
    """
    now = when or dt.datetime.now()
    dated = now.strftime("%m-%d-%Y")
    dest = archive_dir / dated
    dest.mkdir(parents=True, exist_ok=True)

    count = 0
    for p in sorted(log_dir.glob("*.txt")):
        # skip empty or already-archived files
        if not p.is_file():
            continue
        target = dest / p.name
        try:
            shutil.move(str(p), str(target))
            count += 1
        except Exception:
            # don't fail the whole run for a single file
            pass

    print(f"[✔] Moved {count} logs to archive folder: {dest}")
    return dest


def delete_old_archives(archive_dir: Path, retention_days: int = 90) -> int:
    """
    Delete dated subfolders older than retention_days.
    Dated subfolders are named MM-DD-YYYY. Returns number of folders deleted.
    """
    now = dt.datetime.now()
    deleted = 0

    if not archive_dir.exists():
        return deleted

    for child in sorted(archive_dir.iterdir()):
        if not child.is_dir():
            continue
        try:
            folder_date = dt.datetime.strptime(child.name, "%m-%d-%Y")
        except ValueError:
            # Ignore non-date folders
            continue
        age_days = (now - folder_date).days
        if age_days > retention_days:
            try:
                shutil.rmtree(child)
                deleted += 1
                print(f"[✔] Deleted old archive folder: {child.name} (age {age_days} days)")
            except Exception:
                # keep going if one folder can't be removed
                pass
    return deleted


def archive_once(retention_days: int = 90, log_dir: Path | None = None, archive_dir: Path | None = None) -> int:
    """
    One-shot archiving: move current logs to today's archive, then prune old archives.
    Intended to be run from cron at 00:00 local time.
    """
    logs = log_dir or default_log_dir()
    arch = archive_dir or default_archive_dir()
    logs.mkdir(parents=True, exist_ok=True)
    arch.mkdir(parents=True, exist_ok=True)

    move_logs_to_archive(logs, arch)
    delete_old_archives(arch, retention_days=retention_days)
    return 0

# ---- CLI entrypoint ----

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="mtr-logger-archiver",
        description="Archive mtr-logger text logs into dated folders and prune old archives."
    )
    ap.add_argument("--retention", type=int, default=int(os.environ.get("MTR_LOGGER_RETENTION_DAYS", "90")),
                    help="Retention window (days) for dated archive folders (default: 90)")
    ap.add_argument("--log-dir", type=Path, default=None,
                    help="Override the base log directory (default: user home mtr/logs)")
    ap.add_argument("--archive-dir", type=Path, default=None,
                    help="Override the archive directory (default: <log-dir>/archive)")
    args = ap.parse_args(argv)
    return archive_once(retention_days=args.retention, log_dir=args.log_dir, archive_dir=args.archive_dir)

if __name__ == "__main__":
    raise SystemExit(main())
