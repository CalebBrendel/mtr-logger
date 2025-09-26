#!/usr/bin/env bash
set -euo pipefail

# ----------------- Logo -----------------
print_logo() {
cat <<'LOGO'
         __           .__                                     
  ______/  |________  |  |   ____   ____   ____   ___________ 
 /     \   __\_  __ \ |  |  /  _ \ / ___\ / ___\_/ __ \_  __ \
|  Y Y  \  |  |  | \/ |  |_(  <_> ) /_/  > /_/  >  ___/|  | \/
|__|_|  /__|  |__|    |____/\____/\___  /\___  / \___  >__|   
      \/                         /_____//_____/      \/        
LOGO
}

# ----------------- Defaults -----------------
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"
PREFIX_DEFAULT="/opt/mtr-logger"
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

TARGET_DEFAULT="google.ca"
PROTO_DEFAULT="icmp"
DNS_DEFAULT="auto"
INTERVAL_DEFAULT="0.3"
TIMEOUT_DEFAULT="0.3"
PROBES_DEFAULT="3"
FPS_DEFAULT="6"
ASCII_DEFAULT="yes"
USE_SCREEN_DEFAULT="yes"

LOGS_PER_HOUR_DEFAULT="4"
SAFETY_MARGIN_DEFAULT="5"
ARCHIVE_RETENTION_DEFAULT="90"
# --------------------------------------------

# ------------- Prompt helpers (TTY-safe) -------------
sanitize_input() {
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | tr -cd '\11\12\15\40-\176' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}
_read_tty() {
  local prompt="$1" default="${2:-}"
  local ans=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt" ans
  else
    # stdin is a pipe; read from real terminal
    read -r -p "$prompt" ans < /dev/tty
  fi
  ans="${ans:-$default}"
  printf "%s\n" "$(printf "%s" "$ans" | sanitize_input)"
}
ask() { _read_tty "$1 [$2]: " "$2"; }
ask_raw() { _read_tty "$1" ""; }
ask_yn() {
  local q="$1" def="${2:-Y}"
  local d="$(printf "%s" "$def" | tr '[:lower:]' '[:upper:]')"
  local ans="$( _read_tty "$q [${d}]: " "$d" )"
  case "${ans,,}" in y|yes) echo "Y";; n|no) echo "N";; *) echo "$d";; esac
}
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root (sudo)."; exit 1; }; }

# ------------- System helpers -------------
detect_pm(){
  if command -v apt-get >/dev/null 2>&1; then echo apt; elif command -v dnf >/dev/null 2>&1; then echo dnf;
  elif command -v yum >/dev/null 2>&1; then echo yum; elif command -v zypper >/dev/null 2>&1; then echo zypper;
  elif command -v pacman >/dev/null 2>&1; then echo pacman; elif command -v apk >/dev/null 2>&1; then echo apk;
  else echo none; fi
}
install_deps(){
  local pm="$1"; echo "[1/12] Installing system dependencies (pm: $pm)..."
  case "$pm" in
    apt) apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip git traceroute curl cron ca-certificates libcap2-bin ;;
    dnf) dnf install -y python3 python3-virtualenv python3-pip git traceroute curl cronie ca-certificates libcap ;;
    yum) yum install -y python3 python3-virtualenv python3-pip git traceroute curl cronie ca-certificates libcap ;;
    zypper) zypper refresh; zypper install -y python3 python3-venv python3-pip git traceroute curl cron ca-certificates libcap-progs ;;
    pacman) pacman -Sy --noconfirm python python-virtualenv python-pip git traceroute curl cronie ca-certificates libcap ;;
    apk) apk update; apk add python3 py3-virtualenv py3-pip git traceroute curl dcron ca-certificates libcap ;;
    *) echo "Unsupported distro. Install python3, venv, pip, git, traceroute, curl, cron, libcap manually."; exit 1 ;;
  esac
}
start_cron_service(){
  echo "[2/12] Ensuring cron service is enabled and running..."
  local ok=0
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-system-running >/dev/null 2>&1 || systemctl list-units >/dev/null 2>&1; then
      for svc in cron crond cronie; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
          systemctl enable --now "$svc" >/dev/null 2>&1 || true
          systemctl start "$svc" >/dev/null 2>&1 || true
          systemctl is-active --quiet "$svc" && { echo "    - ${svc} is active (systemd)"; ok=1; break; }
        fi
      done
    fi
  fi
  if [[ $ok -eq 0 ]] && command -v service >/dev/null 2>&1; then
    for svc in cron crond cronie; do service "$svc" start >/dev/null 2>&1 || true; done
  fi
  if [[ $ok -eq 0 ]]; then
    for path in /etc/init.d/cron /etc/init.d/crond /etc/init.d/cronie; do
      [[ -x "$path" ]] && "$path" start >/dev/null 2>&1 || true
    done
  fi
  if [[ $ok -eq 0 ]] && command -v rc-service >/dev/null 2>&1; then
    rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
  fi
  if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then echo "    - cron/crond is running"; else echo "    - Could not verify an active cron unit; please check manually."; fi
}

validate_factor_of_60(){ case "$1" in 1|2|3|4|5|6|10|12|15|20|30|60) return 0;; *) return 1;; esac; }

minutes_list(){
  local n="$1" step out="" m=0
  step=$((60 / n))
  while (( m < 60 )); do out+="${m},"; m=$((m + step)); done
  printf '%s\n' "${out%,}"
}

try_setcap_cap_net_raw(){
  local pybin="$1"
  [[ -x "$pybin" ]] || { echo "    - Python binary not found at $pybin (skipping setcap)."; return 1; }
  command -v setcap >/dev/null 2>&1 || { echo "    - 'setcap' not available; ICMP may require sudo."; return 1; }
  setcap cap_net_raw+ep "$pybin" 2>/dev/null || { echo "    - setcap failed; ICMP may require sudo."; return 1; }
  if command -v getcap >/dev/null 2>&1; then getcap "$pybin" | grep -q cap_net_raw || echo "    - getcap did not show cap_net_raw; ICMP may still require sudo."; fi
  echo "    - cap_net_raw granted to $pybin"
  return 0
}

detect_current_tz(){
  if command -v timedatectl >/dev/null 2>&1; then
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    [[ -n "${tz:-}" ]] && { printf "%s\n" "$tz"; return; }
  fi
  [[ -f /etc/timezone ]] && { tr -d '\n\r' < /etc/timezone; echo; return; }
  echo "UTC"
}

tz_list() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl list-timezones 2>/dev/null || true
  elif [[ -d /usr/share/zoneinfo ]]; then
    # Filter out non-zones
    find /usr/share/zoneinfo -type f \
      | sed -e 's|^/usr/share/zoneinfo/||' \
      | grep -Ev '(^posix/|^right/|/Etc/|^Etc/UTC$|\.tab$|leapseconds|zone1970\.tab|zoneinfo\.dir|zoneinfo\.tzdata)' \
      || true
  fi
}

show_local_time_preview(){
  local tz="$1"
  if [[ -n "$tz" ]]; then
    TZ="$tz" date "+%Y-%m-%d %H:%M:%S %Z (preview)"
  fi
}

choose_timezone_with_menu(){
  local detected="$1"
  echo
  echo "[TZ] Detected host timezone: $detected"
  local yn
  yn="$(ask_yn 'Is this the correct timezone?' 'Y')"
  if [[ "$yn" == "Y" ]]; then
    echo "    - Keeping system timezone as: $detected"
    CRON_TZ_VAL="$detected"
    return 0
  fi

  echo
  echo "Choose how to set timezone:"
  echo "  1) Use detected timezone ($detected)"
  echo "  2) Enter exact IANA name (e.g., America/Chicago)"
  echo "  3) Browse by Region (e.g., America → Chicago)"
  echo "  4) Search by keyword (shows matches)"
  echo "  5) Skip timezone change"
  while :; do
    local opt; opt="$(ask 'Option' '4')"
    case "$opt" in
      1)
        echo "    - Using detected timezone: $detected"
        CRON_TZ_VAL="$detected"
        break
        ;;
      2)
        local tz_exact; tz_exact="$(ask_raw 'Enter exact IANA timezone: ')"
        if [[ -z "$tz_exact" ]]; then echo "    - Empty, try again."; continue; fi
        if tz_list | grep -Fxq "$tz_exact"; then
          echo "Preview: $(show_local_time_preview "$tz_exact")"
          if [[ "$(ask_yn "Use this timezone?" 'Y')" == "Y" ]]; then
            apply_timezone "$tz_exact"
            CRON_TZ_VAL="$tz_exact"
            break
          fi
        else
          echo "    - Not found in system TZ database. Try again."
        fi
        ;;
      3)
        browse_timezone && break || true
        ;;
      4)
        search_timezone && break || true
        ;;
      5)
        echo "    - Skipping timezone change."
        CRON_TZ_VAL="$detected"
        break
        ;;
      *)
        echo "    - Invalid option. Choose 1–5."
        ;;
    esac
  done
}

apply_timezone(){
  local tz="$1"
  echo "Applying timezone: $tz"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$tz" || echo "WARNING: timedatectl failed; continuing."
  elif [[ -f "/usr/share/zoneinfo/$tz" ]]; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime || true
    printf "%s\n" "$tz" > /etc/timezone || true
  else
    echo "WARNING: Could not set timezone automatically."
  fi
}

browse_timezone(){
  echo
  echo "Browse by Region:"
  local regions
  regions="$(tz_list | awk -F'/' 'NF>1{print $1}' | sort -u)"
  if [[ -z "$regions" ]]; then echo "    - No region list available."; return 1; fi
  echo "$regions" | nl -w2 -s'. '
  local idx; idx="$(ask 'Pick region number' '')"
  if ! [[ "$idx" =~ ^[0-9]+$ ]]; then echo "    - Invalid number."; return 1; fi
  local region; region="$(echo "$regions" | sed -n "${idx}p")"
  if [[ -z "$region" ]]; then echo "    - Invalid selection."; return 1; fi
  local zones; zones="$(tz_list | grep -E "^${region}/")"
  if [[ -z "$zones" ]]; then echo "    - No zones under region."; return 1; fi
  echo
  echo "Zones under $region:"
  echo "$zones" | nl -w2 -s'. '
  local zidx; zidx="$(ask 'Pick zone number' '')"
  if ! [[ "$zidx" =~ ^[0-9]+$ ]]; then echo "    - Invalid number."; return 1; fi
  local choice; choice="$(echo "$zones" | sed -n "${zidx}p")"
  if [[ -z "$choice" ]]; then echo "    - Invalid selection."; return 1; fi
  echo "Preview: $(show_local_time_preview "$choice")"
  if [[ "$(ask_yn "Use this timezone?" 'Y')" == "Y" ]]; then
    apply_timezone "$choice"
    CRON_TZ_VAL="$choice"
    return 0
  fi
  return 1
}

search_timezone(){
  echo
  local kw; kw="$(ask 'Search keyword (e.g., Chicago)' '')"
  if [[ -z "$kw" ]]; then echo "    - Empty search."; return 1; fi
  local matches; matches="$(tz_list | grep -i "$kw" || true)"
  if [[ -z "$matches" ]]; then echo "    - No matches."; return 1; fi
  echo
  echo "Matches:"
  echo "$matches" | nl -w2 -s'. '
  local pick; pick="$(ask 'Enter exact timezone from the list (or leave blank to cancel)' '')"
  if [[ -z "$pick" ]]; then echo "    - Cancelled."; return 1; fi
  if ! (echo "$matches" | grep -Fxq "$pick"); then echo "    - Not in shown list."; return 1; fi
  echo "Preview: $(show_local_time_preview "$pick")"
  if [[ "$(ask_yn "Use this timezone?" 'Y')" == "Y" ]]; then
    apply_timezone "$pick"
    CRON_TZ_VAL="$pick"
    return 0
  fi
  return 1
}

# -------------------- Main flow --------------------
main(){
  require_root
  print_logo
  echo "== mtr-logger bootstrap (universal) =="

  PM="$(detect_pm)"; [[ "$PM" != "none" ]] || { echo "No supported package manager found."; exit 1; }
  install_deps "$PM"
  start_cron_service

  # --- Timezone block (before any Git work) ---
  CURRENT_TZ="$(detect_current_tz)"
  CRON_TZ_VAL="$CURRENT_TZ"
  choose_timezone_with_menu "$CURRENT_TZ"

  # --- Standard prompts / install ---
  GIT_URL="$(ask "Git URL" "$GIT_URL_DEFAULT")"; case "$GIT_URL" in https://*|git@*:* ) ;; *) echo "WARNING: invalid URL; using default."; GIT_URL="$GIT_URL_DEFAULT";; esac
  BRANCH="$(ask "Branch" "$BRANCH_DEFAULT")"
  PREFIX="$(ask "Install prefix" "$PREFIX_DEFAULT")"
  WRAPPER="$(ask "Wrapper path" "$WRAPPER_DEFAULT")"

  TARGET="$(ask "Target (hostname/IP)" "$TARGET_DEFAULT")"
  PROTO="$(ask "Probe protocol (icmp|tcp|udp)" "$PROTO_DEFAULT")"
  DNS_MODE="$(ask "DNS mode (auto|on|off)" "$DNS_DEFAULT")"
  INTERVAL="$(ask "Interval seconds (-i)" "$INTERVAL_DEFAULT")"
  TIMEOUT="$(ask "Timeout seconds (--timeout)" "$TIMEOUT_DEFAULT")"
  PROBES="$(ask "Probes per hop (-p)" "$PROBES_DEFAULT")"
  FPS="$(ask "TUI FPS (interactive only)" "$FPS_DEFAULT")"
  ASCII="$(ask "Use ASCII borders? (yes/no)" "$ASCII_DEFAULT")"
  USE_SCREEN="$(ask "Use alternate screen? (yes/no)" "$USE_SCREEN_DEFAULT")"

  LPH="$(ask "How many logs per hour (must divide 60 evenly)" "$LOGS_PER_HOUR_DEFAULT")"
  validate_factor_of_60 "$LPH" || { echo "ERROR: $LPH does not evenly divide 60."; exit 2; }
  SAFETY="$(ask "Safety margin seconds (subtract from each window)" "$SAFETY_MARGIN_DEFAULT")"

  SRC_DIR="$PREFIX/src"; VENV_DIR="$PREFIX/.venv"

  STEP_MIN=$((60 / LPH)); WINDOW_SEC=$((STEP_MIN * 60)); DURATION=$((WINDOW_SEC - SAFETY)); [[ $DURATION -gt 0 ]] || { echo "ERROR: Safety too large."; exit 2; }
  MINUTES="$(minutes_list "$LPH")"

  echo
  echo "Schedule (CRON_TZ=$CRON_TZ_VAL):"
  echo "  Minute marks: $MINUTES"
  echo "  Window seconds: $WINDOW_SEC"
  echo "  Duration seconds: $DURATION"
  echo

  echo "[3/12] Preparing install root: $PREFIX"; mkdir -p "$PREFIX"
  echo "[4/12] Cloning/updating repo..."
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" remote set-url origin "$GIT_URL"
    git -C "$SRC_DIR" fetch origin --depth=1
    git -C "$SRC_DIR" checkout -q "$BRANCH"
    git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
  else
    rm -rf "$SRC_DIR"
    git clone --depth=1 --branch "$BRANCH" "$GIT_URL" "$SRC_DIR"
  fi
  [[ -f "$SRC_DIR/pyproject.toml" ]] || { echo "pyproject.toml not found in $SRC_DIR"; exit 1; }

  echo "[5/12] Creating virtualenv: $VENV_DIR"; python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip wheel
  echo "[6/12] Installing package (editable)..."; pip install -e "$SRC_DIR"

  echo "[7/12] Granting CAP_NET_RAW to venv python (best effort)..."
  PYBIN="$VENV_DIR/bin/python3"; [[ -x "$PYBIN" ]] || PYBIN="$VENV_DIR/bin/python"
  try_setcap_cap_net_raw "$PYBIN" || echo "WARNING: ICMP may require sudo; you can use --proto tcp."

  echo "[8/12] Creating wrapper: $WRAPPER"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
VENV="$VENV_DIR"
source "\$VENV/bin/activate"
exec "\$VENV/bin/python" -m mtrpy "\$@"
WRAP
  chmod +x "$WRAPPER"

  echo "[9/12] Writing cron entries (root) ..."
  ASCII_FLAG=""; [[ "$ASCII" == "yes" ]] && ASCII_FLAG="--ascii"
  SCREEN_FLAG=""; [[ "$USE_SCREEN" == "no" ]] && SCREEN_FLAG="--no-screen"

  CRONLINE_LOG="CRON_TZ=$CRON_TZ_VAL
${MINUTES} * * * * TZ=\"$CRON_TZ_VAL\" flock -n /var/run/mtr-logger.lock $WRAPPER \"$TARGET\" --proto \"$PROTO\" --dns \"$DNS_MODE\" -i \"$INTERVAL\" --timeout \"$TIMEOUT\" -p \"$PROBES\" --duration \"$DURATION\" --export --outfile auto >> /var/log/mtr-logger.log 2>&1"

  CRONLINE_ARCHIVE="CRON_TZ=$CRON_TZ_VAL
0 0 * * * TZ=\"$CRON_TZ_VAL\" flock -n /var/run/mtr-archive.lock $VENV_DIR/bin/python -m mtrpy.archiver --retention $ARCHIVE_RETENTION_DEFAULT >> /var/log/mtr-logger-archive.log 2>&1"

  (crontab -l 2>/dev/null | grep -v -E 'mtr-logger\.lock|mtr-archive\.lock|CRON_TZ=' || true; \
    echo "$CRONLINE_LOG"; echo "$CRONLINE_ARCHIVE") | crontab -

  echo "[10/12] Self-test (non-fatal if it fails) ..."
  set +e
  TEST_PATH="$("$WRAPPER" "$TARGET" --proto tcp --dns "$DNS_MODE" -i "$INTERVAL" --timeout "$TIMEOUT" -p "$PROBES" --duration 5 --export --outfile auto 2>/dev/null | tail -n1)"
  set -e
  [[ -n "${TEST_PATH:-}" ]] && echo "    - Test log: $TEST_PATH" || echo "    - Self-test not conclusive."

  echo "[11/12] Time reference"
  echo "    - Host time zone: $(detect_current_tz)"
  echo "    - Cron jobs scheduled with CRON_TZ=$CRON_TZ_VAL"

  echo "[12/12] Done."
  print_logo
  cat <<INFO

✅ Install complete.

Run interactively:
  mtr-logger $TARGET --proto $PROTO -i $INTERVAL --timeout $TIMEOUT -p $PROBES ${ASCII_FLAG:+$ASCII_FLAG} ${SCREEN_FLAG:+$SCREEN_FLAG}

Cron (root, in $CRON_TZ_VAL):
  $CRONLINE_LOG

Archiver (daily 00:00 in $CRON_TZ_VAL):
  $CRONLINE_ARCHIVE

Notes:
- If CAP_NET_RAW couldn't be applied, ICMP may need sudo; 'tcp' works unprivileged:
    mtr-logger $TARGET --proto tcp
- Logs live in ~/mtr/logs; archives in ~/mtr/logs/archive/MM-DD-YYYY (dated in TZ=$CRON_TZ_VAL)
- Retention is 90 days by default; edit root crontab to change.
INFO
}

# Export CRON_TZ_VAL default to quiet shellcheck warnings
CRON_TZ_VAL="UTC"

main "$@"
