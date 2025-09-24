#!/usr/bin/env bash
# Universal mtr-logger bootstrap installer (Linux)
# - Supports apt/dnf/yum/zypper/pacman/apk
# - Installs deps, clones repo, creates venv, adds wrapper, prompts for schedule, writes cron
# - Ensures cron is enabled/started (systemd, SysV/service, OpenRC, BusyBox crond)
# - Tries to grant cap_net_raw to venv python; falls back gracefully if unavailable
# - Sanitizes prompt input and validates Git URL (shell-safe)
# - Adds midnight archiving cron with 90-day retention (configurable by editing crontab)

set -euo pipefail

# ----------------- Defaults -----------------
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"
PREFIX_DEFAULT="/opt/mtr-logger"
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

TARGET_DEFAULT="8.8.8.8"
PROTO_DEFAULT="icmp"
DNS_DEFAULT="auto"
INTERVAL_DEFAULT="0.1"    # CHANGED: was 0.2
TIMEOUT_DEFAULT="0.2"     # NEW: probe timeout (seconds)
PROBES_DEFAULT="3"
FPS_DEFAULT="6"
ASCII_DEFAULT="yes"
USE_SCREEN_DEFAULT="yes"

LOGS_PER_HOUR_DEFAULT="4"  # e.g., 0,15,30,45
SAFETY_MARGIN_DEFAULT="5"  # seconds subtracted from each window; 0 = full window
ARCHIVE_RETENTION_DEFAULT="90"
# --------------------------------------------

sanitize_input() {
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' \
  | tr -cd '\11\12\15\40-\176' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

is_valid_git_url() {
  case "${1:-}" in
    https://*) return 0 ;;
    git@*:* )  return 0 ;;
    *)         return 1 ;;
  esac
}

ask() {
  local label="$1" default="$2" ans=""
  if [[ -t 0 ]]; then
    read -r -p "$label [$default]: " ans
  else
    read -r -p "$label [$default]: " ans < /dev/tty
  fi
  ans="$(printf "%s" "${ans:-$default}" | sanitize_input)"
  printf "%s\n" "${ans}"
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
  echo "[1/11] Installing system dependencies (pm: $pm)..."
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
      echo "Unsupported distro: please install Python 3, venv, pip, git, traceroute, curl, cron, libcap manually." >&2
      exit 1
      ;;
  esac
}

start_cron_service() {
  echo "[2/11] Ensuring cron service is enabled and running..."

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-system-running >/dev/null 2>&1 || systemctl list-units >/dev/null 2>&1; then
      for svc in cron crond cronie; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
          systemctl enable --now "$svc" 2>/dev/null || true
          systemctl start "$svc" 2>/dev/null || true
          if systemctl is-active --quiet "$svc"; then
            echo "    - ${svc} is active (systemd)"
            return 0
          fi
        fi
      done
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    for svc in cron crond cronie; do
      service "$svc" start 2>/dev/null || true
    done
  fi

  for path in /etc/init.d/cron /etc/init.d/crond /etc/init.d/cronie; do
    if [[ -x "$path" ]]; then
      "$path" start 2>/dev/null || true
    fi
  done

  if command -v rc-service >/dev/null 2>&1; then
    rc-update add crond default 2>/dev/null || true
    rc-service crond start 2>/dev/null || true
  fi
  if command -v crond >/dev/null 2>&1; then
    crond 2>/dev/null || true
  fi

  if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
    echo "    - cron/crond is running"
    return 0
  fi

  echo "    - Could not verify an active cron unit; please check manually."
  return 1
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

try_setcap_cap_net_raw() {
  local pybin="$1"
  if [[ ! -x "$pybin" ]]; then
    echo "    - Python binary not found at $pybin (skipping setcap)."
    return 1
  fi
  if ! command -v setcap >/dev/null 2>&1; then
    echo "    - 'setcap' not available on this system; ICMP may require sudo."
    return 1
  fi
  if ! setcap cap_net_raw+ep "$pybin" 2>/dev/null; then
    echo "    - setcap failed (filesystem may not support file capabilities). ICMP may require sudo."
    return 1
  fi
  if command -v getcap >/dev/null 2>&1; then
    if ! getcap "$pybin" | grep -q 'cap_net_raw'; then
      echo "    - getcap verification did not show cap_net_raw; ICMP may still require sudo."
      return 1
    fi
  fi
  echo "    - cap_net_raw granted to $pybin"
  return 0
}

main() {
  require_root
  echo "== mtr-logger bootstrap (universal) =="

  local PM; PM="$(detect_pm)"
  [[ "$PM" != "none" ]] || { echo "No supported package manager found. Aborting." >&2; exit 1; }
  install_deps "$PM"
  start_cron_service

  # ---- Prompts ----
  local GIT_URL BRANCH PREFIX WRAPPER
  GIT_URL="$(ask "Git URL" "$GIT_URL_DEFAULT")"
  if ! is_valid_git_url "$GIT_URL"; then
    echo "WARNING: Invalid Git URL entered; falling back to default: $GIT_URL_DEFAULT"
    GIT_URL="$GIT_URL_DEFAULT"
  fi
  BRANCH="$(ask "Branch" "$BRANCH_DEFAULT")"
  PREFIX="$(ask "Install prefix" "$PREFIX_DEFAULT")"
  WRAPPER="$(ask "Wrapper path" "$WRAPPER_DEFAULT")"

  local TARGET PROTO DNS_MODE INTERVAL TIMEOUT PROBES FPS ASCII USE_SCREEN
  TARGET="$(ask "Target (hostname/IP)" "$TARGET_DEFAULT")"
  PROTO="$(ask "Probe protocol (icmp|tcp|udp)" "$PROTO_DEFAULT")"
  DNS_MODE="$(ask "DNS mode (auto|on|off)" "$DNS_DEFAULT")"
  INTERVAL="$(ask "Interval seconds (-i)" "$INTERVAL_DEFAULT")"
  TIMEOUT="$(ask "Timeout seconds (--timeout)" "$TIMEOUT_DEFAULT")"     # NEW prompt
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
  echo
  echo "Repo:"
  echo "  URL:    $GIT_URL"
  echo "  Branch: $BRANCH"
  echo "Install:"
  echo "  Prefix: $PREFIX"
  echo "  Wrapper:$WRAPPER"
  echo

  # ---- Clone/Update ----
  echo "[3/11] Preparing install root: $PREFIX"
  mkdir -p "$PREFIX"

  echo "[4/11] Cloning/updating repo..."
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

  # ---- Venv & Install ----
  echo "[5/11] Creating virtualenv: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip wheel
  echo "[6/11] Installing package (editable)..."
  pip install -e "$SRC_DIR"

  # ---- Try to grant cap_net_raw (graceful fallback) ----
  echo "[7/11] Granting CAP_NET_RAW to venv python (best effort)..."
  PYBIN="$VENV_DIR/bin/python3"
  [[ -x "$PYBIN" ]] || PYBIN="$VENV_DIR/bin/python"
  if ! try_setcap_cap_net_raw "$PYBIN"; then
    echo "WARNING: Continuing without file capabilities. ICMP may require sudo (or use --proto tcp)." >&2
  fi

  # ---- Wrapper ----
  echo "[8/11] Creating wrapper: $WRAPPER"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
VENV="$VENV_DIR"
source "\$VENV/bin/activate"
exec "\$VENV/bin/python" -m mtrpy "\$@"
WRAP
  chmod +x "$WRAPPER"

  # ---- Cron: logging ----
  echo "[9/11] Writing cron entries (root) ..."
  local ASCII_FLAG=""; [[ "$ASCII" == "yes" ]] && ASCII_FLAG="--ascii"
  local SCREEN_FLAG=""; [[ "$USE_SCREEN" == "no" ]] && SCREEN_FLAG="--no-screen"

  local CRONLINE_LOG="${MINUTES} * * * * flock -n /var/run/mtr-logger.lock \
$WRAPPER \"$TARGET\" --proto \"$PROTO\" --dns \"$DNS_MODE\" -i \"$INTERVAL\" --timeout \"$TIMEOUT\" -p \"$PROBES\" --duration \"$DURATION\" \
--export --outfile auto >> /var/log/mtr-logger.log 2>&1"

  # ---- Cron: daily archiving ----
  local CRONLINE_ARCHIVE="0 0 * * * flock -n /var/run/mtr-archive.lock \
$VENV_DIR/bin/python -m mtrpy.archiver --retention $ARCHIVE_RETENTION_DEFAULT >> /var/log/mtr-logger-archive.log 2>&1"

  # Install/replace both lines; remove any previous entries we own
  (crontab -l 2>/dev/null | grep -v -E 'mtr-logger\.lock|mtr-archive\.lock' || true; \
    echo "$CRONLINE_LOG"; \
    echo "$CRONLINE_ARCHIVE" \
  ) | crontab -

  echo "[10/11] Self-test (non-fatal if it fails) ..."
  set +e
  TEST_PATH="$("$WRAPPER" "$TARGET" --proto tcp --dns "$DNS_MODE" -i "$INTERVAL" --timeout "$TIMEOUT" -p "$PROBES" --duration 5 --export --outfile auto 2>/dev/null | tail -n1)"
  set -e
  [[ -n "${TEST_PATH:-}" ]] && echo "    - Test log: $TEST_PATH" || echo "    - Self-test not conclusive."

  echo "[11/11] Done."
  cat <<INFO

✅ Install complete.

Run interactively:
  mtr-logger $TARGET --proto $PROTO -i $INTERVAL --timeout $TIMEOUT -p $PROBES $ASCII_FLAG $SCREEN_FLAG

Cron (root):
  $CRONLINE_LOG

Archiver (daily at 00:00):
  $CRONLINE_ARCHIVE

Notes:
- If CAP_NET_RAW couldn't be applied, ICMP may need sudo; 'tcp' works unprivileged:
    mtr-logger $TARGET --proto tcp
- Logs live in ~/mtr/logs; archives in ~/mtr/logs/archive/MM-DD-YYYY
- Retention is 90 days by default; edit root crontab to change.
INFO
}

main "$@"
