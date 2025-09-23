#!/usr/bin/env bash
# One-time installer for mtr-logger on Linux from GitHub, with interactive cron setup.
# Usage: curl -fsSL https://raw.githubusercontent.com/CalebBrendel/mtr-logger/main/setup_mtrpy.sh | sudo bash
# (Rename the file in your repo to setup_mtr-logger.sh if you want; the URL above is just an example.)

set -euo pipefail

# -------- Defaults (you can override in prompts) --------
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"

PREFIX_DEFAULT="/opt/mtr-logger"          # install root
SRC_DIR_DEFAULT="$PREFIX_DEFAULT/src"
VENV_DIR_DEFAULT="$PREFIX_DEFAULT/.venv"
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

TARGET_DEFAULT="8.8.8.8"
PROTO_DEFAULT="icmp"                       # icmp (root) or tcp (no root needed)
DNS_DEFAULT="auto"                         # auto|on|off
INTERVAL_DEFAULT="0.2"                     # -i seconds
PROBES_DEFAULT="3"                         # -p probes per hop
FPS_DEFAULT="6"                            # --fps (interactive UI only)
ASCII_DEFAULT="yes"                        # --ascii (less flicker)
USE_SCREEN_DEFAULT="yes"                   # use alternate screen for TUI
LOGS_PER_HOUR_DEFAULT="4"                  # 4 → 0,15,30,45
SAFETY_MARGIN_DEFAULT="60"                 # seconds subtracted from each window for guaranteed finish
# --------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
  fi
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  echo "none"
}

install_system_deps() {
  local PM="$1"
  echo "[1/8] Installing system dependencies..."
  case "$PM" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 python3-venv python3-pip git traceroute ca-certificates curl
      ;;
    dnf|yum)
      $PM install -y python3 python3-virtualenv python3-pip git traceroute ca-certificates curl
      ;;
    zypper)
      zypper refresh
      zypper install -y python3 python3-venv python3-pip git traceroute ca-certificates curl
      ;;
    *)
      echo "Unsupported distro (need apt/dnf/yum/zypper)."; exit 1;;
  esac
}

prompt() {
  local label="$1" default="$2"
  read -r -p "$label [$default]: " val || true
  echo "${val:-$default}"
}

validate_factor_of_60() {
  local n="$1"
  case "$n" in
    1|2|3|4|5|6|10|12|15|20|30|60) return 0 ;;
    *) return 1 ;;
  esac
}

make_minutes_list() {
  # input: logs_per_hour
  local n="$1"
  local step=$((60 / n))
  local out=""
  local m=0
  while [[ $m -lt 60 ]]; do
    out+="${m},"
    m=$((m + step))
  done
  echo "${out%,}"
}

main() {
  require_root

  echo "== mtr-logger installer =="

  local PM; PM="$(detect_pm)"
  install_system_deps "$PM"

  # --- Interactive choices ---
  local GIT_URL BRANCH PREFIX SRC_DIR VENV_DIR WRAPPER
  GIT_URL="$(prompt "Git repo URL" "$GIT_URL_DEFAULT")"
  BRANCH="$(prompt "Branch" "$BRANCH_DEFAULT")"
  PREFIX="$(prompt "Install prefix" "$PREFIX_DEFAULT")"
  SRC_DIR="$PREFIX/src"
  VENV_DIR="$PREFIX/.venv"
  WRAPPER="$(prompt "Wrapper path" "$WRAPPER_DEFAULT")"

  local TARGET PROTO DNS_MODE INTERVAL PROBES FPS ASCII USE_SCREEN
  TARGET="$(prompt "Target (hostname/IP)" "$TARGET_DEFAULT")"
  PROTO="$(prompt "Probe protocol (icmp|tcp|udp)" "$PROTO_DEFAULT")"
  DNS_MODE="$(prompt "DNS mode (auto|on|off)" "$DNS_DEFAULT")"
  INTERVAL="$(prompt "Interval seconds (-i)" "$INTERVAL_DEFAULT")"
  PROBES="$(prompt "Probes per hop (-p)" "$PROBES_DEFAULT")"
  FPS="$(prompt "TUI FPS (interactive only)" "$FPS_DEFAULT")"
  ASCII="$(prompt "Use ASCII borders? (yes/no)" "$ASCII_DEFAULT")"
  USE_SCREEN="$(prompt "Use alternate screen? (yes/no)" "$USE_SCREEN_DEFAULT")"

  local LPH; LPH="$(prompt "How many logs per hour (must divide 60 evenly)" "$LOGS_PER_HOUR_DEFAULT")"
  if ! validate_factor_of_60 "$LPH"; then
    echo "ERROR: $LPH does not evenly divide 60. Allowed: 1,2,3,4,5,6,10,12,15,20,30,60"
    exit 2
  fi
  local SAFETY; SAFETY="$(prompt "Safety margin seconds subtracted from each window" "$SAFETY_MARGIN_DEFAULT")"

  # compute schedule + suggested duration
  local STEP_MIN=$((60 / LPH))                    # minutes between runs
  local WINDOW_SEC=$((STEP_MIN * 60))             # seconds per window
  local DURATION=$((WINDOW_SEC - SAFETY))         # run time per job
  if [[ $DURATION -le 0 ]]; then
    echo "ERROR: Safety margin too large for window ($WINDOW_SEC s). Reduce margin."
    exit 2
  fi
  local MINUTES_LIST; MINUTES_LIST="$(make_minutes_list "$LPH")"

  echo
  echo "Computed schedule:"
  echo "  Runs per hour:     $LPH"
  echo "  Minute marks:      $MINUTES_LIST"
  echo "  Window seconds:    $WINDOW_SEC"
  echo "  Duration seconds:  $DURATION (window - safety=$SAFETY)"
  echo

  echo "[2/8] Preparing install root: $PREFIX"
  mkdir -p "$PREFIX"

  # --- Clone or update repo ---
  if [[ -d "$SRC_DIR/.git" ]]; then
    echo "[3/8] Updating repo $GIT_URL ($BRANCH)"
    git -C "$SRC_DIR" remote set-url origin "$GIT_URL"
    git -C "$SRC_DIR" fetch origin --depth=1
    git -C "$SRC_DIR" checkout -q "$BRANCH"
    git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
  else
    echo "[3/8] Cloning $GIT_URL → $SRC_DIR (branch: $BRANCH)"
    rm -rf "$SRC_DIR"
    git clone --depth=1 --branch "$BRANCH" "$GIT_URL" "$SRC_DIR"
  fi

  if [[ ! -f "$SRC_DIR/pyproject.toml" ]]; then
    echo "ERROR: pyproject.toml not found in $SRC_DIR."
    exit 1
  fi

  echo "[4/8] Creating virtualenv: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip wheel

  echo "[5/8] Installing package (editable)..."
  pip install -e "$SRC_DIR"

  echo "[6/8] Creating wrapper: $WRAPPER"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
VENV="$VENV_DIR"
source "\$VENV/bin/activate"
# Run the Python console script (installed by the package) with mtr-logger branding
exec mtrpy "\$@"
WRAP
  chmod +x "$WRAPPER"

  echo "[7/8] Self-test (non-root TCP) to verify the wrapper works..."
  set +e
  TEST_PATH="$("$WRAPPER" "$TARGET" --proto tcp --dns "$DNS_MODE" -i "$INTERVAL" -p "$PROBES" --duration 5 --export --outfile auto 2>/dev/null | tail -n1)"
  STATUS=$?
  set -e
  if [[ $STATUS -ne 0 ]]; then
    echo "Self-test failed (non-fatal). You can try: $WRAPPER $TARGET --proto tcp --duration 5 --export --outfile auto"
  else
    echo "Self-test example log: $TEST_PATH"
  fi

  echo "[8/8] Writing root crontab entry (no overlap, uses duration)..."
  local CRONLINE="${MINUTES_LIST} * * * * flock -n /var/run/mtr-logger.lock $WRAPPER \"$TARGET\" --proto \"$PROTO\" --dns \"$DNS_MODE\" -i \"$INTERVAL\" -p \"$PROBES\" --duration \"$DURATION\" --export --outfile auto >> /var/log/mtr-logger.log 2>&1"
  # Read current root crontab (if any), filter out old lines, append new
  (crontab -l 2>/dev/null | grep -v 'mtr-logger.lock' || true; echo "$CRONLINE") | crontab -

  cat <<INFO

✅ Install complete.

Command:
  mtr-logger $TARGET --proto $PROTO -i $INTERVAL -p $PROBES

Cron (root):
  $CRONLINE

Notes:
- ICMP mode requires root or CAP_NET_RAW on your Python interpreter. Cron runs as root so ICMP is fine.
- To change schedule later, re-run this installer or edit root's crontab:  sudo crontab -e
- Logs go to:  ~/mtr/logs/  (per-user home; for root it's /root/mtr/logs)

INFO
}

main "$@"
