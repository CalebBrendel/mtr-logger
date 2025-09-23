#!/usr/bin/env bash
set -euo pipefail

# Defaults
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"
PREFIX_DEFAULT="/opt/mtr-logger"
TARGET_DEFAULT="8.8.8.8"
PROTO_DEFAULT="icmp"     # "tcp" if you prefer unprivileged
DNS_DEFAULT="auto"
INTERVAL_DEFAULT="0.2"
PROBES_DEFAULT="3"
FPS_DEFAULT="6"
ASCII_DEFAULT="yes"
USE_SCREEN_DEFAULT="yes"
LOGS_PER_HOUR_DEFAULT="4"   # 0,15,30,45
SAFETY_MARGIN_DEFAULT="60"  # seconds subtracted from each window
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

# TTY-safe prompt (works even when piped through curl)
ask() {
  local label="$1" default="$2" ans=""
  if [[ -t 0 ]]; then
    read -r -p "$label [$default]: " ans
  else
    # read from the user's terminal
    read -r -p "$label [$default]: " ans < /dev/tty
  fi
  printf "%s\n" "${ans:-$default}"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

pm_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-venv python3-pip git traceroute ca-certificates curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-virtualenv python3-pip git traceroute ca-certificates curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-virtualenv python3-pip git traceroute ca-certificates curl
  elif command -v zypper >/dev/null 2>&1; then
    zypper refresh
    zypper install -y python3 python3-venv python3-pip git traceroute ca-certificates curl
  else
    echo "Unsupported distro: need apt/dnf/yum/zypper." >&2
    exit 1
  fi
}

validate_factor_of_60() {
  case "$1" in
    1|2|3|4|5|6|10|12|15|20|30|60) return 0 ;;
    *) return 1 ;;
  esac
}

minutes_list() {
  local n="$1" step=$((60 / n)) out="" m=0
  while [[ $m -lt 60 ]]; do out+="${m},"; m=$((m + step)); done
  printf "%s\n" "${out%,}"
}

main() {
  require_root
  echo "== mtr-logger bootstrap =="

  echo "[1/8] Installing system dependencies..."
  pm_install

  # Prompts (via /dev/tty if needed)
  local GIT_URL BRANCH PREFIX WRAPPER
  GIT_URL="$(ask "Git URL" "$GIT_URL_DEFAULT")"
  BRANCH="$(ask "Branch" "$BRANCH_DEFAULT")"
  PREFIX="$(ask "Install prefix" "$PREFIX_DEFAULT")"
  WRAPPER="$(ask "Wrapper path" "$WRAPPER_DEFAULT")"

  local TARGET PROTO DNS_MODE INTERVAL PROBES FPS ASCII USE_SCREEN
  TARGET="$(ask "Target (hostname/IP)" "$TARGET_DEFAULT")"
  PROTO="$(ask "Probe protocol (icmp|tcp|udp)" "$PROTO_DEFAULT")"
  DNS_MODE="$(ask "DNS mode (auto|on|off)" "$DNS_DEFAULT")"
  INTERVAL="$(ask "Interval seconds (-i)" "$INTERVAL_DEFAULT")"
  PROBES="$(ask "Probes per hop (-p)" "$PROBES_DEFAULT")"
  FPS="$(ask "TUI FPS (interactive only)" "$FPS_DEFAULT")"
  ASCII="$(ask "Use ASCII borders? (yes/no)" "$ASCII_DEFAULT")"
  USE_SCREEN="$(ask "Use alternate screen? (yes/no)" "$USE_SCREEN_DEFAULT")"

  local LPH SAFETY
  LPH="$(ask "How many logs per hour (must divide 60 evenly)" "$LOGS_PER_HOUR_DEFAULT")"
  if ! validate_factor_of_60 "$LPH"; then
    echo "ERROR: $LPH does not evenly divide 60. Allowed: 1,2,3,4,5,6,10,12,15,20,30,60" >&2
    exit 2
  fi
  SAFETY="$(ask "Safety margin seconds (subtract from each window)" "$SAFETY_MARGIN_DEFAULT")"

  local SRC_DIR="$PREFIX/src" VENV_DIR="$PREFIX/.venv"
  local STEP_MIN=$((60 / LPH))
  local WINDOW_SEC=$((STEP_MIN * 60))
  local DURATION=$((WINDOW_SEC - SAFETY))
  if [[ $DURATION -le 0 ]]; then
    echo "ERROR: safety margin too large for the window (${WINDOW_SEC}s)." >&2
    exit 2
  fi
  local MINUTES; MINUTES="$(minutes_list "$LPH")"

  echo
  echo "Schedule:"
  echo "  Minute marks: $MINUTES"
  echo "  Per-run duration: ${DURATION}s  (window ${WINDOW_SEC}s - safety ${SAFETY}s)"
  echo

  echo "[2/8] Preparing install root: $PREFIX"
  mkdir -p "$PREFIX"

  echo "[3/8] Cloning/updating repo..."
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" remote set-url origin "$GIT_URL"
    git -C "$SRC_DIR" fetch origin --depth=1
    git -C "$SRC_DIR" checkout -q "$BRANCH"
    git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
  else
    rm -rf "$SRC_DIR"
    git clone --depth=1 --branch "$BRANCH" "$GIT_URL" "$SRC_DIR"
  fi
  [[ -f "$SRC_DIR/pyproject.toml" ]] || { echo "pyproject.toml not found in $SRC_DIR" >&2; exit 1; }

  echo "[4/8] Creating virtualenv: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip wheel

  echo "[5/8] Installing package..."
  pip install -e "$SRC_DIR"

  echo "[6/8] Creating wrapper: $WRAPPER"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
VENV="$VENV_DIR"
source "\$VENV/bin/activate"
exec mtrpy "\$@"
WRAP
  chmod +x "$WRAPPER"

  echo "[7/8] Self-test (TCP, non-root) ..."
  set +e
  TEST_PATH="$("$WRAPPER" "$TARGET" --proto tcp --dns "$DNS_MODE" -i "$INTERVAL" -p "$PROBES" --duration 5 --export --outfile auto 2>/dev/null | tail -n1)"
  STATUS=$?
  set -e
  if [[ $STATUS -ne 0 ]]; then
    echo "Self-test failed (non-fatal). Try: $WRAPPER $TARGET --proto tcp --duration 5 --export --outfile auto"
  else
    echo "Self-test example log: $TEST_PATH"
  fi

  echo "[8/8] Writing cron (root) ..."
  local ASCII_FLAG=""; [[ "$ASCII" == "yes" ]] && ASCII_FLAG="--ascii"
  local SCREEN_FLAG=""; [[ "$USE_SCREEN" == "no" ]] && SCREEN_FLAG="--no-screen"

  local CRONLINE="${MINUTES} * * * * flock -n /var/run/mtr-logger.lock \
$WRAPPER \"$TARGET\" --proto \"$PROTO\" --dns \"$DNS_MODE\" -i \"$INTERVAL\" -p \"$PROBES\" --duration \"$DURATION\" \
--export --outfile auto >> /var/log/mtr-logger.log 2>&1"

  # Install/replace cronline
  (crontab -l 2>/dev/null | grep -v 'mtr-logger.lock' || true; echo "$CRONLINE") | crontab -

  cat <<INFO

✅ Install complete.

Run interactively:
  mtr-logger $TARGET --proto $PROTO -i $INTERVAL -p $PROBES $ASCII_FLAG $SCREEN_FLAG

Cron (root):
  $CRONLINE

Notes:
- ICMP needs root or CAP_NET_RAW on the Python binary. Cron runs as root so ICMP is fine.
- To change schedule later, re-run this bootstrap or:  sudo crontab -e
- Logs appear under the invoking user's home (root → /root/mtr/logs).
INFO
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

# Defaults
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"
PREFIX_DEFAULT="/opt/mtr-logger"
TARGET_DEFAULT="8.8.8.8"
PROTO_DEFAULT="icmp"     # "tcp" if you prefer unprivileged
DNS_DEFAULT="auto"
INTERVAL_DEFAULT="0.2"
PROBES_DEFAULT="3"
FPS_DEFAULT="6"
ASCII_DEFAULT="yes"
USE_SCREEN_DEFAULT="yes"
LOGS_PER_HOUR_DEFAULT="4"   # 0,15,30,45
SAFETY_MARGIN_DEFAULT="60"  # seconds subtracted from each window
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

# TTY-safe prompt (works even when piped through curl)
ask() {
  local label="$1" default="$2" ans=""
  if [[ -t 0 ]]; then
    read -r -p "$label [$default]: " ans
  else
    # read from the user's terminal
    read -r -p "$label [$default]: " ans < /dev/tty
  fi
  printf "%s\n" "${ans:-$default}"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

pm_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-venv python3-pip git traceroute ca-certificates curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-virtualenv python3-pip git traceroute ca-certificates curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-virtualenv python3-pip git traceroute ca-certificates curl
  elif command -v zypper >/dev/null 2>&1; then
    zypper refresh
    zypper install -y python3 python3-venv python3-pip git traceroute ca-certificates curl
  else
    echo "Unsupported distro: need apt/dnf/yum/zypper." >&2
    exit 1
  fi
}

validate_factor_of_60() {
  case "$1" in
    1|2|3|4|5|6|10|12|15|20|30|60) return 0 ;;
    *) return 1 ;;
  esac
}

minutes_list() {
  local n="$1" step=$((60 / n)) out="" m=0
  while [[ $m -lt 60 ]]; do out+="${m},"; m=$((m + step)); done
  printf "%s\n" "${out%,}"
}

main() {
  require_root
  echo "== mtr-logger bootstrap =="

  echo "[1/8] Installing system dependencies..."
  pm_install

  # Prompts (via /dev/tty if needed)
  local GIT_URL BRANCH PREFIX WRAPPER
  GIT_URL="$(ask "Git URL" "$GIT_URL_DEFAULT")"
  BRANCH="$(ask "Branch" "$BRANCH_DEFAULT")"
  PREFIX="$(ask "Install prefix" "$PREFIX_DEFAULT")"
  WRAPPER="$(ask "Wrapper path" "$WRAPPER_DEFAULT")"

  local TARGET PROTO DNS_MODE INTERVAL PROBES FPS ASCII USE_SCREEN
  TARGET="$(ask "Target (hostname/IP)" "$TARGET_DEFAULT")"
  PROTO="$(ask "Probe protocol (icmp|tcp|udp)" "$PROTO_DEFAULT")"
  DNS_MODE="$(ask "DNS mode (auto|on|off)" "$DNS_DEFAULT")"
  INTERVAL="$(ask "Interval seconds (-i)" "$INTERVAL_DEFAULT")"
  PROBES="$(ask "Probes per hop (-p)" "$PROBES_DEFAULT")"
  FPS="$(ask "TUI FPS (interactive only)" "$FPS_DEFAULT")"
  ASCII="$(ask "Use ASCII borders? (yes/no)" "$ASCII_DEFAULT")"
  USE_SCREEN="$(ask "Use alternate screen? (yes/no)" "$USE_SCREEN_DEFAULT")"

  local LPH SAFETY
  LPH="$(ask "How many logs per hour (must divide 60 evenly)" "$LOGS_PER_HOUR_DEFAULT")"
  if ! validate_factor_of_60 "$LPH"; then
    echo "ERROR: $LPH does not evenly divide 60. Allowed: 1,2,3,4,5,6,10,12,15,20,30,60" >&2
    exit 2
  fi
  SAFETY="$(ask "Safety margin seconds (subtract from each window)" "$SAFETY_MARGIN_DEFAULT")"

  local SRC_DIR="$PREFIX/src" VENV_DIR="$PREFIX/.venv"
  local STEP_MIN=$((60 / LPH))
  local WINDOW_SEC=$((STEP_MIN * 60))
  local DURATION=$((WINDOW_SEC - SAFETY))
  if [[ $DURATION -le 0 ]]; then
    echo "ERROR: safety margin too large for the window (${WINDOW_SEC}s)." >&2
    exit 2
  fi
  local MINUTES; MINUTES="$(minutes_list "$LPH")"

  echo
  echo "Schedule:"
  echo "  Minute marks: $MINUTES"
  echo "  Per-run duration: ${DURATION}s  (window ${WINDOW_SEC}s - safety ${SAFETY}s)"
  echo

  echo "[2/8] Preparing install root: $PREFIX"
  mkdir -p "$PREFIX"

  echo "[3/8] Cloning/updating repo..."
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" remote set-url origin "$GIT_URL"
    git -C "$SRC_DIR" fetch origin --depth=1
    git -C "$SRC_DIR" checkout -q "$BRANCH"
    git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
  else
    rm -rf "$SRC_DIR"
    git clone --depth=1 --branch "$BRANCH" "$GIT_URL" "$SRC_DIR"
  fi
  [[ -f "$SRC_DIR/pyproject.toml" ]] || { echo "pyproject.toml not found in $SRC_DIR" >&2; exit 1; }

  echo "[4/8] Creating virtualenv: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip wheel

  echo "[5/8] Installing package..."
  pip install -e "$SRC_DIR"

  echo "[6/8] Creating wrapper: $WRAPPER"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
VENV="$VENV_DIR"
source "\$VENV/bin/activate"
exec mtrpy "\$@"
WRAP
  chmod +x "$WRAPPER"

  echo "[7/8] Self-test (TCP, non-root) ..."
  set +e
  TEST_PATH="$("$WRAPPER" "$TARGET" --proto tcp --dns "$DNS_MODE" -i "$INTERVAL" -p "$PROBES" --duration 5 --export --outfile auto 2>/dev/null | tail -n1)"
  STATUS=$?
  set -e
  if [[ $STATUS -ne 0 ]]; then
    echo "Self-test failed (non-fatal). Try: $WRAPPER $TARGET --proto tcp --duration 5 --export --outfile auto"
  else
    echo "Self-test example log: $TEST_PATH"
  fi

  echo "[8/8] Writing cron (root) ..."
  local ASCII_FLAG=""; [[ "$ASCII" == "yes" ]] && ASCII_FLAG="--ascii"
  local SCREEN_FLAG=""; [[ "$USE_SCREEN" == "no" ]] && SCREEN_FLAG="--no-screen"

  local CRONLINE="${MINUTES} * * * * flock -n /var/run/mtr-logger.lock \
$WRAPPER \"$TARGET\" --proto \"$PROTO\" --dns \"$DNS_MODE\" -i \"$INTERVAL\" -p \"$PROBES\" --duration \"$DURATION\" \
--export --outfile auto >> /var/log/mtr-logger.log 2>&1"

  # Install/replace cronline
  (crontab -l 2>/dev/null | grep -v 'mtr-logger.lock' || true; echo "$CRONLINE") | crontab -

  cat <<INFO

✅ Install complete.

Run interactively:
  mtr-logger $TARGET --proto $PROTO -i $INTERVAL -p $PROBES $ASCII_FLAG $SCREEN_FLAG

Cron (root):
  $CRONLINE

Notes:
- ICMP needs root or CAP_NET_RAW on the Python binary. Cron runs as root so ICMP is fine.
- To change schedule later, re-run this bootstrap or:  sudo crontab -e
- Logs appear under the invoking user's home (root → /root/mtr/logs).
INFO
}

main "$@"
