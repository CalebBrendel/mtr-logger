from __future__ import annotations

import shutil
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from .util import default_log_dir, ensure_dir


def archive_logs(retention: int = 90) -> None:
    log_root = default_log_dir()
    today = datetime.now().strftime("%m-%d-%Y")
    archive_dir = log_root / "archive" / today
    ensure_dir(archive_dir)

    # Move today's loose logs (if any) into today's archive folder
    for p in sorted(log_root.glob("mtr-*.txt")):
        # skip existing archive folders
        if p.is_file():
            dest = archive_dir / p.name
            try:
                p.replace(dest)
            except Exception:
                # fallback copy+remove
                shutil.copy2(p, dest)
                p.unlink(missing_ok=True)

    # Prune old archive dirs
    cutoff = datetime.now() - timedelta(days=retention)
    for d in (log_root / "archive").glob("*"):
        if not d.is_dir():
            continue
        try:
            dt = datetime.strptime(d.name, "%m-%d-%Y")
        except Exception:
            continue
        if dt < cutoff:
            shutil.rmtree(d, ignore_errors=True)


def main(argv: Optional[list[str]] = None) -> int:
    # Allow: python -m mtrpy.archiver --retention 120
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--retention", type=int, default=90)
    a = ap.parse_args(argv)
    archive_logs(a.retention)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
