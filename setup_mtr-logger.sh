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
# ----------------------------------------

# ----------------- Defaults -----------------
GIT_URL_DEFAULT="https://github.com/CalebBrendel/mtr-logger.git"
BRANCH_DEFAULT="main"
PREFIX_DEFAULT="/opt/mtr-logger"
WRAPPER_DEFAULT="/usr/local/bin/mtr-logger"

TARGET_DEFAULT="google.ca"
PROTO_DEFAULT="icmp"
DNS_DEFAULT="auto"
INTERVAL_DEFAULT="0.3"   # interactive default
TIMEOUT_DEFAULT="0.3"
PROBES_DEFAULT="3"
FPS_DEFAULT="6"
ASCII_DEFAULT="yes"
USE_SCREEN_DEFAULT="yes"

LOGS_PER_HOUR_DEFAULT="4"
SAFETY_MARGIN_DEFAULT="5"
ARCHIVE_RETENTION_DEFAULT="90"
# --------------------------------------------

# ----------- Small helpers -----------
sanitize_input() {
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | tr -cd '\11\12\15\40-\176' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}
is_valid_git_url(){ case "${1:-}" in https://*|git@*:* ) return 0;; *) return 1;; esac; }
ask(){ local l="$1" d="$2" a=""; if [[ -t 0 ]]; then read -r -p "$l [$d]: " a; else read -r -p "$l [$d]: " a < /dev/tty; fi; a="$(printf "%s" "${a:-$d}"|sanitize_input)"; printf "%s\n" "$a"; }
ask_yn(){ local l="$1" d="$2" a=""; local def="${d,,}"; local def_hint; [[ "$def" == "yes" ]] && def_hint="Y/n" || def_hint="y/N"; read -r -p "$l [$def_hint]: " a </dev/tty || a=""; a="$(sanitize_input <<<"${a:-}")"; a="${a:-$d}"; case "${a,,}" in y|yes) echo "yes";; n|no) echo "no";; *) echo "$d";; esac; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root (sudo)."; exit 1; }; }

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
  local n="$1"
  local step=$((60 / n))
  local out="" m=0
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
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    [[ -n "${tz:-}" ]] && { printf "%s\n" "$tz"; return; }
  fi
  [[ -f /etc/timezone ]] && { tr -d '\n\r' < /etc/timezone; echo; return; }
  echo "UTC"
}
current_time_in_tz(){
  local tz="$1"
  TZ="$tz" date +"%Y-%m-%d %H:%M:%S %Z"
}

# ---------- Timezone list helpers ----------
_collect_timezones(){
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl list-timezones 2>/dev/null || true
    return
  fi
  if [[ -d /usr/share/zoneinfo ]]; then
    (cd /usr/share/zoneinfo >/dev/null 2>&1 || exit 0; find . -type f | sed 's#^\./##' | grep -E '^[A-Za-z]+/|^(UTC|GMT|Zulu)$')
  fi
}
list_timezones_all(){
  local pager="less -R"
  command -v less >/dev/null 2>&1 || pager="more"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl list-timezones | $pager
  else
    _collect_timezones | sort -u | $pager
  fi
}
list_timezones_region(){
  local region="$1" pager="less -R"
  command -v less >/dev/null 2>&1 || pager="more"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl list-timezones | grep -E "^${region}/" | $pager
  else
    _collect_timezones | grep -E "^${region}/" | sort -u | $pager
  fi
}
search_timezones(){
  local kw="$1" limit="${2:-50}"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl list-timezones | grep -i -- "$kw" | head -n "$limit"
  else
    _collect_timezones | grep -i -- "$kw" | sort -u | head -n "$limit"
  fi
}

# ---------- Interactive TZ picker ----------
choose_timezone_interactive() {
  local current="$1"
  local pick=""
  local input=""
  local tzs_all=""

  if command -v timedatectl >/dev/null 2>&1; then
    tzs_all="$(timedatectl list-timezones 2>/dev/null || true)"
  else
    tzs_all="$(_collect_timezones | grep -E '^[A-Za-z]+/|^(UTC|GMT|Zulu)$' | sort -u)"
  fi

  while true; do
    echo
    echo "Timezone helper:"
    echo "  1) Browse all (pager)"
    echo "  2) Browse by region (America, Europe, Asia, Africa, Australia, Pacific, Indian, Atlantic, Antarctica, Arctic)"
    echo "  3) Search by keyword (recommended)"
    echo "  4) Enter exact timezone (e.g., America/Chicago)"
    echo "  5) Cancel / keep current ($current)"
    echo
    echo "Tip: You can also type an exact IANA name here (e.g., America/Chicago) and press Enter."
    input="$(ask 'Choose an option' '3')"

    # Direct IANA name accepted at main prompt
    if [[ "$input" == */* || "$input" =~ ^(UTC|GMT|Zulu)$ ]]; then
      pick="$input"
      if command -v timedatectl >/dev/null 2>&1; then
        if ! printf "%s\n" "$tzs_all" | grep -Fxq "$pick"; then
          echo "Not a recognized timezone: $pick"
          pick=""; continue
        fi
      else
        [[ -f "/usr/share/zoneinfo/$pick" ]] || { echo "No such file: /usr/share/zoneinfo/$pick"; pick=""; continue; }
      fi
      echo "Current time in $pick: $(current_time_in_tz "$pick")"
      [[ "$(ask_yn 'Use this timezone?' 'yes')" == "yes" ]] && { printf "%s\n" "$pick"; return 0; }
      pick=""; continue
    fi

    case "${input,,}" in
      1|browse|b)
        list_timezones_all || true
        ;;
      2|region|r)
        local region; region="$(ask 'Region' 'America')"
        case "$region" in
          America|Europe|Asia|Africa|Australia|Pacific|Indian|Atlantic|Antarctica|Arctic)
            list_timezones_region "$region" || true
            ;;
          *)
            echo "Unknown region. Try: America Europe Asia Africa Australia Pacific Indian Atlantic Antarctica Arctic"
            ;;
        esac
        ;;
      3|search|s)
        local kw; kw="$(ask 'Search keyword (e.g., Chicago)' '')"
        if [[ -n "$kw" ]]; then
          echo "Matches (top 50):"
          search_timezones "$kw" 50 || true
          echo
          pick="$(ask 'Enter exact timezone from the matches (or leave blank to continue)' '')"
          if [[ -n "$pick" ]]; then
            if command -v timedatectl >/dev/null 2>&1; then
              printf "%s\n" "$tzs_all" | grep -Fxq "$pick" || { echo "Not a recognized timezone: $pick"; pick=""; continue; }
            else
              [[ -f "/usr/share/zoneinfo/$pick" ]] || { echo "No such file: /usr/share/zoneinfo/$pick"; pick=""; continue; }
            fi
            echo "Current time in $pick: $(current_time_in_tz "$pick")"
            [[ "$(ask_yn 'Use this timezone?' 'yes')" == "yes" ]] && { printf "%s\n" "$pick"; return 0; }
            pick=""
          fi
        else
          echo "No keyword entered."
        fi
        ;;
      4|enter|e)
        pick="$(ask 'Enter exact timezone (e.g., America/Chicago)' "$current")"
        [[ -n "$pick" ]] || { echo "No timezone entered."; continue; }
        if command -v timedatectl >/dev/null 2>&1; then
          printf "%s\n" "$tzs_all" | grep -Fxq "$pick" || { echo "Not a recognized timezone: $pick"; pick=""; continue; }
        else
          [[ -f "/usr/share/zoneinfo/$pick" ]] || { echo "No such file: /usr/share/zoneinfo/$pick"; pick=""; continue; }
        fi
        echo "Current time in $pick: $(current_time_in_tz "$pick")"
        [[ "$(ask_yn 'Use this timezone?' 'yes')" == "yes" ]] && { printf "%s\n" "$pick"; return 0; }
        pick=""
        ;;
      5|cancel|c)
        echo "$current"
        return 0
        ;;
      *)
        echo "Invalid choice. Type 1–5, or type an exact timezone (e.g., America/Chicago)."
        ;;
    esac
  done
}

apply_timezone_if_requested(){
  local current="$1"
  echo
  echo "[TZ] Detected host timezone: $current"
  if [[ "$(ask_yn 'Is this the correct timezone?' 'yes')" == "no" ]]; then
    if [[ "$(ask_yn 'Do you want to change the system timezone now?' 'yes')" == "yes" ]]; then
      echo
      echo "Browse/search, or type an exact IANA name (e.g., America/Chicago) when prompted."
      local new_tz; new_tz="$(choose_timezone_interactive "$current")"
      if [[ -n "$new_tz" && "$new_tz" != "$current" ]]; then
        echo "Applying timezone: $new_tz"
        if command -v timedatectl >/dev/null 2>&1; then
          timedatectl set-timezone "$new_tz" || { echo "timedatectl failed. Falling back to /etc/localtime."; ln -sf "/usr/share/zoneinfo/$new_tz" /etc/localtime; echo "$new_tz" > /etc/timezone || true; }
        else
          ln -sf "/usr/share/zoneinfo/$new_tz" /etc/localtime
          echo "$new_tz" > /etc/timezone || true
        fi
      fi
    fi
  fi
}

# ----------------- Main -----------------
main(){
  require_root
  print_logo
  echo "== mtr-logger bootstrap (universal) =="

  PM="$(detect_pm)"; [[ "$PM" != "none" ]] || { echo "No supported package manager found."; exit 1; }
  install_deps "$PM"
  start_cron_service

  # --- Timezone confirm / change ---
  CURRENT_TZ="$(detect_current_tz)"
  apply_timezone_if_requested "$CURRENT_TZ"
  CURRENT_TZ="$(detect_current_tz)"

  # --- Config prompts ---
  GIT_URL="$(ask "Git URL" "$GIT_URL_DEFAULT")"; is_valid_git_url "$GIT_URL" || { echo "WARNING: invalid URL; using default."; GIT_URL="$GIT_URL_DEFAULT"; }
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
  CRON_TZ_VAL="$(ask "Time zone for scheduling (IANA, e.g. America/Chicago)" "$CURRENT_TZ")"

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
- If CAP_NET_RAW couldn't be applied, ICMP may need sudo; 'tcp' works unprivileged
    mtr-logger $TARGET --proto tcp
- Logs live in ~/mtr/logs; archives in ~/mtr/logs/archive/MM-DD-YYYY (dated in TZ=$CRON_TZ_VAL)
- Retention is 90 days by default; edit root crontab to change.
INFO
}

main "$@"
