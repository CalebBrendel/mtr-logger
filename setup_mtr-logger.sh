#!/usr/bin/env bash
set -euo pipefail

# Defaults
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"
PREFIX_DEFAULT="/opt/mtr-logger"
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

TARGET_DEFAULT="8.8.8.8"
PROTO_DEFAULT="icmp"
DNS_DEFAULT="auto"
INTERVAL_DEFAULT="0.2"
PROBES_DEFAULT="3"
FPS_DEFAULT="6"
ASCII_DEFAULT="yes"
USE_SCREEN_DEFAULT="yes"

LOGS_PER_HOUR_DEFAULT="4"
SAFETY_MARGIN_DEFAULT="0"   # 0 = full window
SETCAP_DEFAULT="yes"        # default: grant CAP_NET_RAW to venv python

# ---- flag parsing (optional) ----
SETCAP_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setcap-icmp)
      SETCAP_FLAG="${2:-}"; shift 2 ;;
    --no-setcap)
      SETCAP_FLAG="no"; shift 1 ;;
    *)
      echo "Unknown flag: $1"; exit 2 ;;
  esac
done

ask() {
  local label="$1" default="$2" ans=""
  if [[ -t 0 ]]; then
    read -r -p "$label [$default]: " ans
  else
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

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf      >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum      >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v zypper   >/dev/null 2>&1; then echo "zypper"; return; fi
  if command -v pacman   >/dev/null 2>&1; then echo "pacman"; return; fi
  if command -v apk      >/dev/null 2>&1; then echo "apk"; return; fi
  echo "none"
}

install_deps() {
  local pm="$1"
  echo "[1/10] Installing system dependencies (pm: $pm)..."
  case "$pm" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 python3-venv python3-pip git traceroute curl cron ca-certificates libcap2-bin
      ;;
    dnf)
      dnf install -y python3 python3-virtualenv python3-pip git traceroute curl cronie ca-certificates libcap
      ;;
    yum)
      yum install -y python3 python3-virtualenv python3-pip git traceroute curl cronie ca-certificates libcap
      ;;
    zypper)
      zypper refresh
      zypper install -y python3 python3-venv python3-pip git traceroute curl cron ca-certificates libcap-progs
      ;;
    pacman)
      pacman -Sy --noconfirm python python-virtualenv python-pip git traceroute curl cronie ca-certificates libcap
      ;;
    apk)
      apk update
      apk add python3 py3-virtualenv py3-pip git traceroute curl dcron ca-certificates libcap
      ;;
    *)
      echo "Unsupported distro: install Python 3, venv, pip, git, traceroute, curl, cron, libcap manually." >&2
      exit 1
      ;;
  esac

  # enable cron where applicable
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now crond 2>/dev/null || true
    systemctl enable --now cron  2>/dev/null || true
    systemctl enable --now cronie 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service crond start 2>/dev/null || true
    rc-update add crond default 2>/dev/null || true
  fi
}

validate_factor_of_60() {
  case "$1" in
    1|2|3|4|5|6|10|12|15|20|30|60) return 0 ;;
    *) return 1 ;;
  esac
}

minutes_list() {
  local n="$1"
  local step out m
  step=$((60 / n))
  out=""
  m=0
  while [[ $m -lt 60 ]]; do
    out+="${m},"
    m=$((m + step))
  done
  printf "%s\n" "${out%,}"
}

main() {
  require_root
  echo "== mtr-logger bootstrap (universal, setcap default on) =="

  local PM; PM="$(detect_pm)"
  [[ "$PM" != "none" ]] || { echo "No supported package manager found."; exit 1; }
  install_deps "$PM"

  # Prompts
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

  # decide setcap (flag overrides prompt default)
  local SETCAP_ANSWER
  if [[ -n "${SETCAP_FLAG:-}" ]]; then
    SETCAP_ANSWER="$SETCAP_FLAG"
  else
    SETCAP_ANSWER="$(ask "Grant CAP_NET_RAW to venv python for ICMP without sudo? (yes/no)" "$SETCAP_DEFAULT")"
  fi

  local SRC_DIR="$PREFIX/src" VENV_DIR="$PREFIX/.venv"

  # Compute schedule & duration
  local STEP_MIN WINDOW_SEC DURATION MINUTES
  STEP_MIN=$((60 / LPH))
  WINDOW_SEC=$((STEP_MIN * 60))
  DURATION=$((WINDOW_SEC - SAFETY))
  if [[ $DURATION -le 0 ]]; then
    echo "ERROR: Safety margin too large for ${WINDOW_SEC}s window." >&2
    exit 2
  fi
  MINUTES="$(minutes_list "$LPH")"

  echo
  echo "Schedule:"
  echo "  Minute marks:      $MINUTES"
  echo "  Window seconds:    $WINDOW_SEC"
  echo "  Duration seconds:  $DURATION (window - safety)"
  echo "  Setcap (ICMP w/o sudo): $SETCAP_ANSWER"
  echo

  # Clone / update
  echo "[2/10] Preparing install root: $PREFIX"
  mkdir -p "$PREFIX"

  echo "[3/10] Cloning/updating repo..."
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

  # Venv & install
  echo "[4/10] Creating virtualenv: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip wheel

  echo "[5/10] Installing package (editable)..."
  pip install -e "$SRC_DIR"

  # Wrapper
  echo "[6/10] Creating wrapper: $WRAPPER"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
VENV="$VENV_DIR"
source "\$VENV/bin/activate"
exec "\$VENV/bin/python" -m mtrpy "\$@"
WRAP
  chmod +x "$WRAPPER"

  # setcap (optional, default yes)
  echo "[7/10] Applying CAP_NET_RAW (if requested)..."
  if [[ "${SETCAP_ANSWER,,}" == "yes" ]]; then
    if command -v setcap >/dev/null 2>&1; then
      PYBIN="$VENV_DIR/bin/python3"
      [[ -x "$PYBIN" ]] || PYBIN="$VENV_DIR/bin/python"
      if [[ -x "$PYBIN" ]]; then
        setcap cap_net_raw=ep "$PYBIN" || true
      fi
    else
      echo "WARNING: setcap not found; cannot grant CAP_NET_RAW. ICMP may require sudo."
    fi
  else
    echo "Skipping setcap per selection."
  fi

  # Self-test
  echo "[8/10] Self-test (TCP, non-root) ..."
  set +e
  TEST_PATH="$("$WRAPPER" "$TARGET" --proto tcp --dns "$DNS_MODE" -i "$INTERVAL" -p "$PROBES" --duration 5 --export --outfile auto 2>/dev/null | tail -n1)"
  STATUS=$?
  set -e
  if [[ $STATUS -ne 0 || -z "${TEST_PATH:-}" ]]; then
    echo "Self-test failed (non-fatal). Try: $WRAPPER $TARGET --proto tcp --duration 5 --export --outfile auto"
  else
    echo "Self-test example log: $TEST_PATH"
  fi

  # Cron
  echo "[9/10] Writing cron (root) ..."
  local ASCII_FLAG=""; [[ "$ASCII" == "yes" ]] && ASCII_FLAG="--ascii"
  local SCREEN_FLAG=""; [[ "$USE_SCREEN" == "no" ]] && SCREEN_FLAG="--no-screen"

  local CRONLINE="${MINUTES} * * * * flock -n /var/run/mtr-logger.lock \
$WRAPPER \"$TARGET\" --proto \"$PROTO\" --dns \"$DNS_MODE\" -i \"$INTERVAL\" -p \"$PROBES\" --duration \"$DURATION\" \
--export --outfile auto >> /var/log/mtr-logger.log 2>&1"

  (crontab -l 2>/dev/null | grep -v 'mtr-logger.lock' || true; echo "$CRONLINE") | crontab -

  echo "[10/10] Done."
  cat <<INFO

✅ Install complete.

Run interactively:
  mtr-logger $TARGET --proto $PROTO -i $INTERVAL -p $PROBES $ASCII_FLAG $SCREEN_FLAG

Cron (root):
  $CRONLINE

Notes:
- With CAP_NET_RAW applied, you can run ICMP without sudo:  mtr-logger 8.8.8.8 --proto icmp
- To change schedule later, re-run this bootstrap or:  sudo crontab -e
- Logs appear under the invoking user's home (root → /root/mtr/logs).
INFO
}

main "$@"
