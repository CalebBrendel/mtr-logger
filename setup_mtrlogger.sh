#!/usr/bin/env bash
# One-time installer for mtrpy on Linux pulling from GitHub
# Usage:
#   sudo bash setup_mtrpy.sh
#   sudo bash setup_mtrpy.sh --git https://github.com/<user>/<repo>.git --branch main
#   sudo bash setup_mtrpy.sh --prefix /opt/mtrpy-custom
#
# What it does:
# - Installs system deps (python3, venv, pip, traceroute, git)
# - Clones repo into /opt/mtrpy/src (or --prefix)
# - Creates venv in /opt/mtrpy/.venv
# - Pip-installs project
# - Creates wrapper /usr/local/bin/mtrpy
# - Runs a quick self-test (TCP) and prints the log path

set -euo pipefail

# ---------- Defaults (override via flags) ----------
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH="main"
PREFIX="/opt/mtrpy"                 # install root
SRC_DIR="$PREFIX/src"               # repo clone here
VENV_DIR="$PREFIX/.venv"
WRAPPER="/usr/local/bin/mtrpy"
SELFTEST_TARGET="8.8.8.8"
SELFTEST_DURATION=10                # seconds
SELFTEST_INTERVAL=0.2
SELFTEST_PROBES=1
SELFTEST_PROTO="tcp"                # tcp works without root; use icmp with sudo
DNS_MODE="auto"                     # auto|on|off
GIT_URL="$GIT_URL_DEFAULT"
# ---------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git)    GIT_URL="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

SRC_DIR="$PREFIX/src"
VENV_DIR="$PREFIX/.venv"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PM="apt"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"
elif command -v yum >/dev/null 2>&1; then
  PM="yum"
elif command -v zypper >/dev/null 2>&1; then
  PM="zypper"
else
  echo "Unsupported distro: need apt/dnf/yum/zypper."
  exit 1
fi

echo "[1/7] Installing system dependencies..."
case "$PM" in
  apt)
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-venv python3-pip git traceroute ca-certificates
    ;;
  dnf|yum)
    $PM install -y python3 python3-virtualenv python3-pip git traceroute ca-certificates
    ;;
  zypper)
    zypper refresh
    zypper install -y python3 python3-venv python3-pip git traceroute ca-certificates
    ;;
esac

echo "[2/7] Preparing install root: $PREFIX"
mkdir -p "$PREFIX"

# Clone or update the repo
if [[ -d "$SRC_DIR/.git" ]]; then
  echo "[3/7] Repo exists, pulling latest ($BRANCH) from $GIT_URL ..."
  git -C "$SRC_DIR" remote set-url origin "$GIT_URL"
  git -C "$SRC_DIR" fetch origin --depth=1
  git -C "$SRC_DIR" checkout -q "$BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
else
  echo "[3/7] Cloning $GIT_URL → $SRC_DIR (branch: $BRANCH)"
  rm -rf "$SRC_DIR"
  git clone --depth=1 --branch "$BRANCH" "$GIT_URL" "$SRC_DIR"
fi

if [[ ! -f "$SRC_DIR/pyproject.toml" ]]; then
  echo "ERROR: pyproject.toml not found in $SRC_DIR. Aborting."
  exit 1
fi

echo "[4/7] Creating virtualenv: $VENV_DIR"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
python -m pip install -U pip wheel

echo "[5/7] Installing mtrpy package from source..."
pip install -e "$SRC_DIR"

echo "[6/7] Creating wrapper: $WRAPPER"
cat > "$WRAPPER" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
VENV="/opt/mtrpy/.venv"
# shellcheck disable=SC1090
source "$VENV/bin/activate"
exec mtrpy "$@"
WRAP
chmod +x "$WRAPPER"

# If prefix was changed, adjust wrapper's VENV path accordingly
if [[ "$PREFIX" != "/opt/mtrpy" ]]; then
  sed -i "s|^VENV=.*|VENV=\"$VENV_DIR\"|g" "$WRAPPER"
fi

echo "[7/7] Running self-test (non-root, TCP probes) ..."
set +e
LOG_PATH="$(
  "$WRAPPER" "$SELFTEST_TARGET" --proto "$SELFTEST_PROTO" --dns "$DNS_MODE" \
    -i "$SELFTEST_INTERVAL" -p "$SELFTEST_PROBES" --duration "$SELFTEST_DURATION" \
    --export --outfile auto 2>/dev/null | tail -n1
)"
STATUS=$?
set -e

if [[ $STATUS -ne 0 || -z "$LOG_PATH" ]]; then
  echo "Self-test did not complete successfully."
  echo "Try manually: mtrpy $SELFTEST_TARGET --proto tcp --duration 5 --export --outfile auto"
else
  echo "Self-test complete. Example log written to: $LOG_PATH"
fi

cat <<'NEXT'

✅ Install finished.

Try:
  mtrpy 8.8.8.8 --proto tcp -i 0.2 -p 3
Or (ICMP like mtr; needs root/cap_net_raw on many distros):
  sudo mtrpy 8.8.8.8 --proto icmp -i 0.2 -p 3

Quarter-hour logs via cron (non-overlapping, 14 min duration):
  sudo crontab -e
Add:
  0,15,30,45 * * * * flock -n /var/run/mtrpy-quarter.lock \
    mtrpy 8.8.8.8 --proto icmp --dns auto -i 0.2 -p 3 --duration 840 --export --outfile auto >> /var/log/mtrpy-quarter.log 2>&1

(Use --proto tcp if you don’t want to run as root.)
NEXT
