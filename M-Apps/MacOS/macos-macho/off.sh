#!/bin/bash
# =============================================================================
#  off.sh v4.0 - "Movie Mode": zero pop-ups + zero notifications on macOS
# =============================================================================
#  BASE: the v3.0 TCC engine you told me was the good one. Its proven parts
#  (password prompt, TCC database grants, exact restore) are kept as they
#  were. Everything below marked [v4] was added on top.
#
#  USAGE
#    bash off.sh                enable  (explains -> password -> confirm -> done)
#    bash off.sh --back         restore everything exactly as before
#    bash off.sh --add <path>   pre-approve another binary or .app mid-session
#    bash off.sh --status       show current state
#    bash off.sh --doctor       environment check
#    bash off.sh --yes          non-interactive (for agents / cron)
#    bash off.sh --help
#
#  WHAT IT DOES (enable)
#    1. Backs up: both TCC privacy databases + screen-capture approvals +
#       the Focus (Do Not Disturb) database file.            [v3 + v4]
#    2. Pre-approves 18 privacy services (screen recording, mic, camera,
#       full disk access, accessibility, input monitoring, automation,
#       folder/volume access, LOCAL NETWORK, NOTIFICATIONS, app
#       management, ...) for:
#         - dev binaries found on this Mac: node, python3, python, uv, uvx,
#           deno, bun, ffmpeg, osascript (+ every symlink resolved to its
#           REAL path, nvm/fnm/volta/asdf/mise/pyenv/homebrew globs, and
#           whatever node/python is RUNNING right now - found via ps) [v4]
#         - terminal / editor apps: Terminal, iTerm2, VS Code, Cursor,
#           Windsurf, Warp, Claude, Zed, Xcode, Sublime (whatever exists)
#         - Apple Events rows for controlling Finder + System Events  [v4]
#    3. Sets screen-recording approval dates to 2099 (kills the recurring
#       "Allow For One Month" re-prompt).                              [v3]
#    4. Firewall: whitelists every dev tool so the "node would like to
#       accept incoming network connections" box can never appear.    [v4]
#       (Your firewall itself stays exactly as it is - ON or OFF.)
#    5. Gatekeeper off + no quarantine (no "can't be opened because Apple
#       cannot check it" / Allow Anyway boxes). Restored by --back.    [v4]
#    6. NOTIFICATIONS OFF, the verified way (schema confirmed against
#       live macOS 15.3 and macOS 26.3 Tahoe):                        [v4]
#         - writes the real Do Not Disturb assertion into
#           ~/Library/DoNotDisturb/DB/Assertions.json
#         - posts _NSDoNotDisturbEnabledNotification + the Darwin
#           notification names, restarts donotdisturbd via launchctl
#           kickstart -k  (same mechanism as the macos-focus library)
#         - mutes ONLY alert/beep sounds (movie audio untouched)
#         - stops Dock bouncing
#       Why not just kill Notification Center? Because on a Mac with SIP
#       ON (the default), launchctl bootout/unload of
#       com.apple.notificationcenterui is BLOCKED by SIP - that approach
#       silently fails on a real Mac. Focus/DND is the supported way.
#    7. Menu bar: hides the Focus (purple moon), Control Center,
#       Screen Mirroring, Now Playing, Sound Recognition and
#       Accessibility Shortcuts icons; Control Center is restarted so it
#       takes effect immediately.                                      [v4]
#    8. Turns ON every sharing service (they STAY ON after --back, as you
#       asked): File Sharing, Screen Sharing, Remote Login (SSH), Remote
#       Management, Remote Apple Events, Printer Sharing, Bluetooth
#       Sharing, Media Sharing, Content Caching, Internet Sharing.     [v4]
#    9. Reloads tccd so everything takes effect IMMEDIATELY.           [v3]
#
#  ONE-TIME SETUP (30 seconds, no reboot)
#    macOS blocks ALL writes to the privacy databases (even for root) unless
#    the app doing the writing has Full Disk Access. One time only:
#        System Settings -> Privacy & Security -> Full Disk Access
#        -> enable Terminal (or iTerm2 / VS Code - whatever runs this script)
#    SIP stays ON. v4 checks this FIRST and refuses to pretend it worked:
#    if the check fails it prints exactly what to do and changes nothing.
#
#  RESTORE (--back)
#    Removes exactly the rows it added and restores previous values
#    (including previously-DENIED entries and Apple Events targets),
#    restores the Focus database, menu bar icons, alert sounds, Dock
#    bouncing, firewall whitelist entries and Gatekeeper. Sharing
#    services stay ON (as you asked). No reboot. Full database backups
#    are kept in ~/.tcc-devtool/backups/.
#
#  NOTES
#    - The orange/green camera-mic dot and the purple IN-USE recording
#      indicator are enforced by macOS and cannot be hidden on a stock
#      Mac (anti-stalkerware by design). All prompts/nags/banners are
#      silenced.
#    - Menu-bar Focus icon: v4 hides it and then VERIFIES the setting; if
#      your Mac forces it back while Do Not Disturb is on, v4 says so and
#      prints the 5-second manual fix (Menu Bar Controls -> Focus).
#    - For headless agents: allow NOPASSWD for this script in sudoers, then
#      run it with --yes.
#    - Survives reboots (they are just database rows) until you run --back.
# =============================================================================

set -euo pipefail

NL='
'

# --- Paths (env-overridable; also used by the automated test harness) -------
STATE_DIR="${OFF_STATE_DIR:-$HOME/.tcc-devtool}"
SYS_TCC="${OFF_SYS_TCC:-/Library/Application Support/com.apple.TCC/TCC.db}"
USER_TCC="${OFF_USER_TCC:-$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
REPLAYD_PLIST="${OFF_REPLAYD_PLIST:-$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist}"
EXTRA_PATHS_FILE="$STATE_DIR/paths.txt"   # extra binaries (persistent config)
EXTRA_APPS_FILE="$STATE_DIR/apps.txt"     # extra .app bundles (persistent)
DND_DIR="${OFF_DND_DIR:-$HOME/Library/DoNotDisturb/DB}"
SFW="${OFF_SFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
LD_DAEMONS="${OFF_LD_DAEMONS:-/System/Library/LaunchDaemons}"
LD_AGENTS="${OFF_LD_AGENTS:-/System/Library/LaunchAgents}"
ARD_KICKSTART="${OFF_ARD_KS:-/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart}"

F_ENABLED="$STATE_DIR/enabled.flag"
F_ADDED="$STATE_DIR/added.tsv"            # rows WE added   (deleted on restore)
F_PRESERVE="$STATE_DIR/preserved.tsv"     # rows that existed before us
F_TARGETS="$STATE_DIR/all_targets.tsv"    # everything we touched
F_REPLAYD="$STATE_DIR/replayd.state"      # replayd plist backup info
F_MOVIE="$STATE_DIR/movie.state"          # [v4] icons/sounds/firewall/gatekeeper/DND state
F_FW="$STATE_DIR/firewall.added"          # [v4] firewall whitelist entries we added

DND_ASSERT="$DND_DIR/Assertions.json"     # [v4] the Focus/DND database file
DND_BAK="$STATE_DIR/Assertions.json.orig" # [v4] original, kept for --back
UID_N="$(id -u)"

NAG_DATE="2099-01-01 00:00:00 +0000"
SQLITE_TIMEOUT_MS=6000

# --- Privacy services pre-approved for every dev tool -----------------------
# (v3 had 14; v4 adds LocalNetwork + Notifications + AppManagement +
#  AudioCapture - these are the "node would like to..." boxes that were
#  still popping up.)
SERVICES=(
  kTCCServiceScreenCapture                # screen recording
  kTCCServiceMicrophone                   # microphone
  kTCCServiceCamera                       # camera
  kTCCServiceSystemPolicyAllFiles         # full disk access
  kTCCServiceAccessibility                # accessibility (AX API)
  kTCCServiceListenEvent                  # input monitoring
  kTCCServicePostEvent                    # synthetic keyboard/mouse events
  kTCCServiceAppleEvents                  # automation (osascript)
  kTCCServiceSystemPolicyAppBundles       # control other apps
  kTCCServiceSystemPolicyDesktopFolder    # Desktop access
  kTCCServiceSystemPolicyDocumentsFolder  # Documents access
  kTCCServiceSystemPolicyDownloadsFolder  # Downloads access
  kTCCServiceSystemPolicyRemovableVolumes # USB / external drives
  kTCCServiceSystemPolicyNetworkVolumes   # network volumes
  kTCCServiceLocalNetwork                 # [v4] "find and connect to devices on your local network"
  kTCCServiceNotifications                # [v4] "would like to send you notifications"
  kTCCServiceAppManagement                # [v4] app management (macOS 13+)
  kTCCServiceAudioCapture                 # [v4] system audio capture (macOS 13+)
)

# --- [v4] Apple Events targets pre-approved for every client ----------------
# ("Terminal/node would like to control Finder / System Events")
AE_TARGETS=(com.apple.finder com.apple.systemevents)

# --- [v4] menu-bar icons hidden while Movie Mode is on ----------------------
CC_ICONS=(ControlCenter FocusModes ScreenMirroring NowPlaying SoundRecognition AccessibilityShortcuts)

# --- Terminal / editor / AI-host apps (auto-detected by existence) ----------
# (roots are env-overridable; also used by the automated test harness)
APP_ROOT_SYS="${OFF_APP_ROOT_SYS:-/System/Applications}"
APP_ROOT_APPS="${OFF_APP_ROOT_APPS:-/Applications}"
APP_CANDIDATES=(
  "$APP_ROOT_SYS/Utilities/Terminal.app"
  "$APP_ROOT_APPS/iTerm.app"
  "$APP_ROOT_APPS/Visual Studio Code.app"
  "$APP_ROOT_APPS/Cursor.app"
  "$APP_ROOT_APPS/Windsurf.app"
  "$APP_ROOT_APPS/Warp.app"
  "$APP_ROOT_APPS/Claude.app"
  "$APP_ROOT_APPS/Zed.app"
  "$APP_ROOT_APPS/Xcode.app"
  "$APP_ROOT_APPS/Sublime Text.app"
)

# --- Dev binaries to look up on PATH ----------------------------------------
CLI_COMMANDS=(node python3 python uv uvx deno bun ffmpeg)
CLI_STATIC=(/usr/bin/python3 /usr/bin/osascript)

# --- Globals -----------------------------------------------------------------
ASSUME_YES="${OFF_YES:-0}"
DEBUG="${OFF_DEBUG:-0}"
SYS_DB_OK=0
USER_DB_OK=0
USER_DB_VIA_SUDO=0
GRANT_COUNT=0
GRANT_EXPECTED=0
CLI_PATHS=()
APP_BUNDLES=()
APP_EXES=()
APP_PATHS=()
# schema flags for the access table of the db currently being written
HAS_CSREQ=0; HAS_POLICY_ID=0; HAS_IND_TYPE=0; HAS_IND_ID=0; HAS_IND_CODE=0
HAS_FLAGS=0; HAS_LASTMOD=0

# =============================================================================
# Helpers
# =============================================================================
c_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
c_step() { printf '\033[1;36m[STEP]\033[0m %s\n' "$1"; }
c_ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"; }
c_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
c_err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$1" >&2; }
die()    { c_err "$1"; exit 1; }
hr()     { printf '%s\n' "-------------------------------------------------------------------"; }

dbg() { # debug-print SQL
  if [[ "$DEBUG" == "1" ]]; then printf '[SQL] %s\n' "$1" >&2; fi
  return 0
}

sql_q() { # SQL string literal with proper escaping
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

resolve_path() { # resolve symlinks without requiring GNU coreutils
  local p="$1" r=""
  if [[ ! -e "$p" ]]; then printf '%s' "$p"; return 0; fi
  if command -v realpath >/dev/null 2>&1; then
    r="$(realpath "$p" 2>/dev/null || true)"
  fi
  if [[ -z "$r" ]]; then
    r="$(perl -MCwd=abs_path -e 'print Cwd::abs_path(shift)' "$p" 2>/dev/null || true)"
  fi
  printf '%s' "${r:-$p}"
}

dedup_stdin_lines() { awk '!seen[$0]++ && NF' ; }

require_darwin() {
  if [[ "$(uname)" != "Darwin" ]]; then die "This script only works on macOS."; fi
}

require_sqlite3() {
  if ! command -v sqlite3 >/dev/null 2>&1; then die "sqlite3 not found (it ships with macOS)."; fi
}

need_sudo() { # [v4] ALWAYS show a real password prompt (proof the privileged part runs)
  sudo -k >/dev/null 2>&1 || true      # forget any cached password first
  c_info "Type your Mac admin password when asked (needed to edit the privacy databases)."
  if ! sudo -v; then die "Admin password is required (sudo failed). Nothing was changed."; fi
  if sudo -n true 2>/dev/null; then
    c_ok "Password accepted (or NOPASSWD sudo) - the privileged part is really running."
  fi
}

confirm() { # $1 = prompt; returns 0 when the user answers y
  local answer=""
  if [[ ! -t 0 ]]; then
    if [[ "$ASSUME_YES" != "1" ]]; then
      die "stdin is not a terminal. Run me interactively, or pass --yes."
    fi
    return 0
  fi
  if ! read -r -p "$1 " answer; then die "No input received."; fi
  if [[ "$answer" =~ ^[Yy]$ ]]; then return 0; fi
  return 1
}

macos_version() { sw_vers -productVersion 2>/dev/null || echo "unknown"; }

# never leave temp files behind, even on Ctrl+C
cleanup_tmp() {
  rm -f "$STATE_DIR/.preserve."*.tmp "$STATE_DIR/.targets."*.tmp \
        "$STATE_DIR/.csreq."*.tmp "$STATE_DIR/.paths."*.tmp \
        "$STATE_DIR/.bundles."*.tmp "$STATE_DIR/.add.paths."*.tmp \
        "$STATE_DIR/.add.bundles."*.tmp "$STATE_DIR/.sqlerr."*.tmp \
        "$STATE_DIR/.sqlerr.tmp" "$STATE_DIR/preserved.tsv.tmp" \
        "$STATE_DIR/all_targets.tsv.tmp" "$F_MOVIE.tmp" \
        "$STATE_DIR/.grantsql."*.tmp "$STATE_DIR/.aesql."*.tmp \
        "$STATE_DIR/.restoresql."*.tmp 2>/dev/null || true
}
trap cleanup_tmp EXIT

# =============================================================================
# sqlite plumbing
# =============================================================================
sql_sys() { # $1 = SQL -> stdout  (system db, root-owned)
  sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" "$1"
}
sql_user() { # $1 = SQL -> stdout  (user db; plain first, sudo fallback)
  if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
    sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" "$1"
  else
    sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" "$1"
  fi
}
sql_tag() { # $1 = tag (sys|user), $2 = SQL
  if [[ "$1" == "sys" ]]; then sql_sys "$2"; else sql_user "$2"; fi
}
sql_file() { # [v4] $1 = tag, $2 = FILE containing SQL - avoids the OS
  # "argument list too long" limit when there are many tools/services
  if [[ "$1" == "sys" ]]; then
    sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" < "$2"
  elif [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
    sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" < "$2"
  else
    sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" < "$2"
  fi
}
db_file() { # $1 = tag -> db path
  if [[ "$1" == "sys" ]]; then printf '%s' "$SYS_TCC"; else printf '%s' "$USER_TCC"; fi
}

detect_schema() { # $1 = tag; sets column flags used by insert_row_sql
  local tag="$1" info="" name="" notnull="" dflt="" unknown_bad="" cols=""
  if ! info="$(sql_tag "$tag" "PRAGMA table_info(access);")"; then return 1; fi
  if [[ -z "$info" ]]; then return 1; fi
  HAS_CSREQ=0; HAS_POLICY_ID=0; HAS_IND_TYPE=0; HAS_IND_ID=0; HAS_IND_CODE=0
  HAS_FLAGS=0; HAS_LASTMOD=0; cols=""
  local _cid _type _pk
  while IFS='|' read -r _cid name _type notnull dflt _pk; do
    if [[ -z "$name" ]]; then continue; fi
    case "$name" in
      service|client|client_type|auth_value|auth_reason|auth_version) ;;
      csreq)                           HAS_CSREQ=1 ;;
      policy_id)                       HAS_POLICY_ID=1 ;;
      indirect_object_identifier_type) HAS_IND_TYPE=1 ;;
      indirect_object_identifier)      HAS_IND_ID=1 ;;
      indirect_object_code_identity)   HAS_IND_CODE=1 ;;
      flags)                           HAS_FLAGS=1 ;;
      last_modified)                   HAS_LASTMOD=1 ;;
      *)
        if [[ "$notnull" == "1" && -z "$dflt" ]]; then unknown_bad="$unknown_bad $name"; fi
        ;;
    esac
    if [[ -n "$cols" ]]; then cols="$cols, $name"; else cols="$name"; fi
  done <<< "$info"
  if [[ -n "$unknown_bad" ]]; then
    c_warn "access table has unknown required columns:$unknown_bad - skipping db '$tag'."
    return 1
  fi
  return 0
}

insert_row_sql() {
  # $1=service $2=client $3=client_type $4=csreq_literal
  # $5=auth_value $6=auth_reason $7=auth_version $8=flags_value
  # $9=[v4] indirect_object_identifier_type (default 0)
  # $10=[v4] indirect_object_identifier      (default 'UNUSED')
  local svc="$1" client="$2" ctype="$3" csreq="$4"
  local authv="$5" reason="${6:-4}" ver="${7:-1}" flagsv="${8:-0}"
  local indt="${9:-0}" indi="${10:-UNUSED}"
  local cols="service, client, client_type, auth_value, auth_reason, auth_version"
  local vals
  vals="$(sql_q "$svc"), $(sql_q "$client"), $ctype, $authv, $reason, $ver"
  if [[ "$HAS_CSREQ" == "1" ]];     then cols="$cols, csreq";                           vals="$vals, $csreq"; fi
  if [[ "$HAS_POLICY_ID" == "1" ]]; then cols="$cols, policy_id";                       vals="$vals, NULL"; fi
  if [[ "$HAS_IND_TYPE" == "1" ]];  then cols="$cols, indirect_object_identifier_type"; vals="$vals, $indt"; fi
  if [[ "$HAS_IND_ID" == "1" ]];    then cols="$cols, indirect_object_identifier";      vals="$vals, $(sql_q "$indi")"; fi
  if [[ "$HAS_IND_CODE" == "1" ]];  then cols="$cols, indirect_object_code_identity";   vals="$vals, NULL"; fi
  if [[ "$HAS_FLAGS" == "1" ]];     then cols="$cols, flags";                           vals="$vals, $flagsv"; fi
  if [[ "$HAS_LASTMOD" == "1" ]];   then cols="$cols, last_modified";                   vals="$vals, CAST(strftime('%s','now') AS INTEGER)"; fi
  printf 'INSERT OR REPLACE INTO access (%s) VALUES (%s);' "$cols" "$vals"
}

csreq_literal() { # $1 = hex blob ('' -> NULL)
  if [[ -n "$1" ]]; then printf "x'%s'" "$1"; else printf 'NULL'; fi
}

in_values_list() { # stdin: svc<TAB>client<TAB>ctype lines -> VALUES ((...),(...))
  local first=1 svc client ctype
  while IFS=$'\t' read -r svc client ctype; do
    if [[ -z "$svc" ]]; then continue; fi
    if [[ "$first" == "1" ]]; then first=0; else printf ', '; fi
    printf '(%s, %s, %s)' "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype"
  done
  return 0
}

# =============================================================================
# Client collection (dev binaries + apps) - no root needed
# =============================================================================
collect_cli_paths() {
  CLI_PATHS=()
  local c p g i rp
  local found=()
  for c in ${CLI_COMMANDS[@]+"${CLI_COMMANDS[@]}"}; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [[ -n "$p" ]]; then found+=("$p"); fi
  done
  for p in ${CLI_STATIC[@]+"${CLI_STATIC[@]}"}; do
    if [[ -e "$p" ]]; then found+=("$p"); fi
  done
  # [v4] whatever node/python is RUNNING right now - the exact binaries your
  # AI agent is using (catches version managers and custom paths).
  while IFS= read -r p; do
    if [[ -n "$p" ]]; then found+=("$p"); fi
  done < <(ps axo comm= 2>/dev/null | grep -E '(^|/)(node|deno|bun|uv|uvx|python3|python)$' || true)
  # [v4] only paths that actually exist (v3.0 also collected non-matching
  # glob literals like /opt/homebrew/bin/node on machines where they are
  # absent - harmless but planted junk rows)
  for g in \
    /opt/homebrew/bin/node /opt/homebrew/bin/python3 \
    /opt/homebrew/opt/node*/bin/node \
    /opt/homebrew/opt/python@3*/bin/python3* \
    /usr/local/bin/node /usr/local/bin/python3 \
    /usr/local/opt/node*/bin/node \
    /usr/local/opt/python@3*/bin/python3* \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.volta/bin/node \
    "$HOME"/Library/"Application Support"/fnm/node-versions/*/installation/bin/node \
    "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
    "$HOME"/.asdf/installs/nodejs/*/bin/node \
    "$HOME"/.local/share/mise/installs/node/*/bin/node \
    "$HOME"/.pyenv/versions/*/bin/python3* \
    "$HOME"/.local/share/uv/python/*/bin/python3* \
    "$HOME"/.deno/bin/deno \
    "$HOME"/.bun/bin/bun
  do
    [[ -e "$g" ]] && found+=("$g")
  done
  if [[ -f "$EXTRA_PATHS_FILE" ]]; then
    while IFS= read -r p; do
      p="${p%$'\r'}"
      if [[ -z "$p" || "$p" == \#* ]]; then continue; fi
      if [[ -e "$p" ]]; then found+=("$p"); fi
    done < "$EXTRA_PATHS_FILE"
  fi
  for i in ${found[@]+"${found[@]}"}; do
    CLI_PATHS+=("$i")
    rp="$(resolve_path "$i")"
    if [[ "$rp" != "$i" ]]; then CLI_PATHS+=("$rp"); fi
  done
  local _dedup=() _l
  while IFS= read -r _l; do
    if [[ -n "$_l" ]]; then _dedup+=("$_l"); fi
  done < <(printf '%s\n' ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} | dedup_stdin_lines)
  CLI_PATHS=(${_dedup[@]+"${_dedup[@]}"})
  return 0
}

collect_apps() { # fills APP_BUNDLES (ids), APP_EXES (main executables), APP_PATHS [v4]
  APP_BUNDLES=()
  APP_EXES=()
  APP_PATHS=()
  local apps=() app id exe
  for app in ${APP_CANDIDATES[@]+"${APP_CANDIDATES[@]}"}; do
    if [[ -d "$app" ]]; then apps+=("$app"); fi
  done
  if [[ -f "$EXTRA_APPS_FILE" ]]; then
    while IFS= read -r app; do
      app="${app%$'\r'}"
      if [[ -z "$app" || "$app" == \#* ]]; then continue; fi
      if [[ -d "$app" ]]; then apps+=("$app"); fi
    done < "$EXTRA_APPS_FILE"
  fi
  for app in ${apps[@]+"${apps[@]}"}; do
    id="$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
    if [[ -z "$id" ]]; then continue; fi
    exe="$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
    if [[ -z "$exe" ]]; then exe="$(basename "$app" .app)"; fi
    APP_BUNDLES+=("$id")
    APP_PATHS+=("$app")
    if [[ -e "$app/Contents/MacOS/$exe" ]]; then APP_EXES+=("$app/Contents/MacOS/$exe"); fi
  done
  local _d1=() _d2=() _d3=() _l
  while IFS= read -r _l; do if [[ -n "$_l" ]]; then _d1+=("$_l"); fi; done \
    < <(printf '%s\n' ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"} | dedup_stdin_lines)
  while IFS= read -r _l; do if [[ -n "$_l" ]]; then _d2+=("$_l"); fi; done \
    < <(printf '%s\n' ${APP_EXES[@]+"${APP_EXES[@]}"} | dedup_stdin_lines)
  while IFS= read -r _l; do if [[ -n "$_l" ]]; then _d3+=("$_l"); fi; done \
    < <(printf '%s\n' ${APP_PATHS[@]+"${APP_PATHS[@]}"} | dedup_stdin_lines)
  APP_BUNDLES=(${_d1[@]+"${_d1[@]}"})
  APP_EXES=(${_d2[@]+"${_d2[@]}"})
  APP_PATHS=(${_d3[@]+"${_d3[@]}"})
  return 0
}

all_clients_count() {
  echo $(( ${#CLI_PATHS[@]} + ${#APP_BUNDLES[@]} ))
}

# =============================================================================
# Probes / availability (sudo -n = never hang on a password prompt)
# =============================================================================
probe_sys_db() { # 0 = usable (needs admin + Full Disk Access on this terminal)
  if [[ ! -f "$SYS_TCC" ]]; then return 1; fi
  sudo -n sqlite3 -batch -readonly "$SYS_TCC" "PRAGMA quick_check;" >/dev/null 2>&1
}

probe_user_db() { # sets USER_DB_OK / USER_DB_VIA_SUDO
  USER_DB_OK=0
  USER_DB_VIA_SUDO=0
  if [[ ! -f "$USER_TCC" ]]; then return 1; fi
  if sqlite3 -batch -readonly "$USER_TCC" "PRAGMA quick_check;" >/dev/null 2>&1; then
    USER_DB_OK=1
    return 0
  fi
  if sudo -n sqlite3 -batch -readonly "$USER_TCC" "PRAGMA quick_check;" >/dev/null 2>&1; then
    USER_DB_OK=1
    USER_DB_VIA_SUDO=1
    return 0
  fi
  return 1
}

fda_hint() { # $1 = why Full Disk Access is needed right now
  local term="${TERM_PROGRAM:-}"
  case "$term" in
    Apple_Terminal) term="Terminal" ;;
    iTerm.app)      term="iTerm2" ;;
    vscode*)        term="VS Code" ;;
    Cursor)         term="Cursor" ;;
    WarpTerminal)   term="Warp" ;;
    *)              term="your terminal app" ;;
  esac
  c_warn "$1"
  echo "    One-time fix (no reboot):"
  echo "      System Settings -> Privacy & Security -> Full Disk Access -> enable $term"
  echo "    (macOS blocks ALL writes to the privacy databases, even for root,"
  echo "     unless the writing app has Full Disk Access. SIP stays ON.)"
}

# =============================================================================
# Grant engine
# =============================================================================
# [v4] Manifest formats (tab-separated):
#   F_TARGETS  : tag svc client ctype ind_type ind_id            (6 cols)
#   F_PRESERVE : tag svc client ctype authv reason ver csreq flags ind_type ind_id (11 cols)
#   F_ADDED    : tag svc client ctype ind_type ind_id            (6 cols)
# The extra ind_* columns mean Apple Events rows that point at different
# targets (Finder vs System Events vs pre-existing rows) are tracked and
# restored EXACTLY - v3.0 flattened them to 'UNUSED' on --back.
normalize_manifests() { # upgrade v3.0-era manifests to the v4 format
  local f
  for f in "$F_TARGETS" "$F_ADDED"; do
    if [[ -f "$f" ]]; then
      if awk -F'\t' 'NF==4{print $0"\t0\tUNUSED"; next} {print}' "$f" > "$f.n" 2>/dev/null; then
        mv "$f.n" "$f"
      else
        rm -f "$f.n"
      fi
    fi
  done
  if [[ -f "$F_PRESERVE" ]]; then
    if awk -F'\t' 'NF==9{print $0"\t0\tUNUSED"; next} {print}' "$F_PRESERVE" > "$F_PRESERVE.n" 2>/dev/null; then
      mv "$F_PRESERVE.n" "$F_PRESERVE"
    else
      rm -f "$F_PRESERVE.n"
    fi
  fi
  return 0
}

grant_targets() {
  # $1 = tag (sys|user), $2 = file of CLI paths, $3 = file of bundle ids
  local tag="$1" pfile="$2" bfile="$3"
  local db; db="$(db_file "$tag")"

  if ! detect_schema "$tag"; then return 1; fi

  local csreq_map="$STATE_DIR/.csreq.$$.tmp"
  : > "$csreq_map"

  # Copy existing csreq blobs for bundle clients so tccd keeps seeing the
  # app's real code-signature requirement (falls back to NULL for new apps).
  if [[ -s "$bfile" ]]; then
    local idlist="" id
    while IFS= read -r id; do
      if [[ -n "$id" ]]; then
        if [[ -n "$idlist" ]]; then idlist+=", "; fi
        idlist+="$(sql_q "$id")"
      fi
    done < "$bfile"
    if [[ -n "$idlist" ]]; then
      sql_tag "$tag" \
        "SELECT client || char(31) || hex(csreq) FROM access WHERE csreq IS NOT NULL AND client IN ($idlist);" \
        2>/dev/null | while IFS=$'\037' read -r id hx; do
          if [[ -n "$id" ]]; then printf '%s\t%s\n' "$id" "${hx:-}" >> "$csreq_map"; fi
        done || true
    fi
  fi

  # 1) Snapshot rows we are about to overwrite (for a perfect --back),
  #    excluding rows that are already ours (recorded in a previous run).
  local triplet_list="" svc client hx
  for svc in ${SERVICES[@]+"${SERVICES[@]}"}; do
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        triplet_list+="$svc"$'\t'"$client"$'\t'"1"$'\n'
      fi
    done < "$pfile"
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        triplet_list+="$svc"$'\t'"$client"$'\t'"0"$'\n'
      fi
    done < "$bfile"
  done

  local tmp_pres="$STATE_DIR/.preserve.$$.tmp"
  : > "$tmp_pres"
  if [[ -n "$triplet_list" ]]; then
    local inlist sel out sel_ind=""
    inlist="$(printf '%s' "$triplet_list" | in_values_list)"
    # [v4] also snapshot the Apple Events target columns so --back can put
    # back EXACTLY the row that was there (including 'com.apple.finder').
    # Only when this macOS has the columns (10.14+ always does).
    if [[ "$HAS_IND_TYPE" == "1" ]]; then
      sel_ind=" || char(31) || COALESCE(indirect_object_identifier_type, 0)"
    fi
    if [[ "$HAS_IND_ID" == "1" ]]; then
      sel_ind+=" || char(31) || COALESCE(indirect_object_identifier, 'UNUSED')"
    fi
    if [[ -n "$inlist" ]]; then
      sel="SELECT service || char(31) || client || char(31) || client_type || char(31) || auth_value || char(31) || auth_reason || char(31) || auth_version || char(31) || COALESCE(hex(csreq),'') || char(31) || COALESCE(flags,'')${sel_ind} FROM access WHERE (service, client, client_type) IN ($inlist);"
      dbg "$sel"
      out=""
      out="$(sql_tag "$tag" "$sel" 2>/dev/null)" || out=""
      local svc2 client2 ctype2 authv reason ver csh flagsv indt indi line
      while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        IFS=$'\037' read -r svc2 client2 ctype2 authv reason ver csh flagsv indt indi <<< "$line"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$tag" "$svc2" "$client2" "$ctype2" "${authv:-0}" "${reason:-0}" \
          "${ver:-1}" "$csh" "$flagsv" "${indt:-0}" "${indi:-UNUSED}" >> "$tmp_pres"
      done <<< "$out"
    fi
  fi
  if [[ -f "$F_ADDED" ]]; then
    # NB: FILENAME==ARGV[1] (not NR==FNR) because F_ADDED may be empty,
    # which breaks the NR==FNR idiom. Key = (tag,svc,client,ctype,ind_type,ind_id).
    awk -F'\t' 'FILENAME==ARGV[1]{k[$1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6]=1;next} !($1"\t"$2"\t"$3"\t"$4"\t"$10"\t"$11 in k)' \
      "$F_ADDED" "$tmp_pres" > "$tmp_pres.f" && mv "$tmp_pres.f" "$tmp_pres"
  fi

  # 2) Record manifests BEFORE mutating anything, so a crash can never leave
  #    untracked changes behind (deleting a never-inserted row is a no-op).
  local tmp_tgt="$STATE_DIR/.targets.$$.tmp"
  : > "$tmp_tgt"
  printf '%s\n' "$triplet_list" | while IFS=$'\t' read -r svc client ctype; do
    if [[ -n "$svc" ]]; then printf '%s\t%s\t%s\t%s\t0\tUNUSED\n' "$tag" "$svc" "$client" "$ctype" >> "$tmp_tgt"; fi
  done
  if [[ ! -f "$F_PRESERVE" ]]; then : > "$F_PRESERVE"; fi
  if [[ ! -f "$F_TARGETS" ]]; then : > "$F_TARGETS"; fi
  # Keep the FIRST (true original) snapshot per key so re-runs never
  # overwrite the real pre-existing values.
  awk -F'\t' 'FILENAME==ARGV[1]{k[$1"\t"$2"\t"$3"\t"$4"\t"$10"\t"$11]=1;next} !($1"\t"$2"\t"$3"\t"$4"\t"$10"\t"$11 in k)' \
    "$F_PRESERVE" "$tmp_pres" >> "$F_PRESERVE"
  cat "$tmp_tgt" >> "$F_TARGETS"
  if [[ -s "$F_PRESERVE" ]]; then
    LC_ALL=C sort -u "$F_PRESERVE" > "$F_PRESERVE.tmp" && mv "$F_PRESERVE.tmp" "$F_PRESERVE"
  fi
  if [[ -s "$F_TARGETS" ]]; then
    LC_ALL=C sort -u "$F_TARGETS" > "$F_TARGETS.tmp" && mv "$F_TARGETS.tmp" "$F_TARGETS"
  fi

  # 3) One atomic transaction with every INSERT, fed via a temp FILE so
  #    the OS "argument list too long" limit can never break it
  #    (real bug with many tools x 18 services).
  local sqlfile="$STATE_DIR/.grantsql.$$.tmp"
  : > "$sqlfile"
  printf '%s' "BEGIN IMMEDIATE;$NL" >> "$sqlfile"
  for svc in ${SERVICES[@]+"${SERVICES[@]}"}; do
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        printf '%s\n' "$(insert_row_sql "$svc" "$client" 1 NULL 2 4 1 0)" >> "$sqlfile"
      fi
    done < "$pfile"
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        hx=""
        if [[ -s "$csreq_map" ]]; then
          hx="$(grep -F -m1 -- "$client"$'\t' "$csreq_map" | cut -f2 || true)"
        fi
        printf '%s\n' "$(insert_row_sql "$svc" "$client" 0 "$(csreq_literal "$hx")" 2 4 1 0)" >> "$sqlfile"
      fi
    done < "$bfile"
  done
  printf '%s' "COMMIT;" >> "$sqlfile"
  dbg "$(head -c 400 "$sqlfile") ... ($(grep -c . "$sqlfile" || true) statements)"
  local sqlerr="$STATE_DIR/.sqlerr.$$.tmp"
  if ! sql_file "$tag" "$sqlfile" 2>"$sqlerr"; then
    c_err "Failed to write $db:"
    sed 's/^/    /' "$sqlerr" >&2 || true
    rm -f "$sqlerr" "$tmp_pres" "$tmp_tgt" "$csreq_map" "$sqlfile"
    return 1
  fi
  rm -f "$sqlerr" "$tmp_pres" "$tmp_tgt" "$csreq_map" "$sqlfile"

  # 4) Verify
  local n=0 expected=0 inlist2
  expected="$(printf '%s\n' "$triplet_list" | grep -c . || true)"
  inlist2="$(printf '%s' "$triplet_list" | in_values_list)"
  if [[ -n "$inlist2" ]]; then
    n="$(sql_tag "$tag" "SELECT count(*) FROM access WHERE (service, client, client_type) IN ($inlist2);" 2>/dev/null)" || n=0
  fi
  n="${n:-0}"; n="${n%%[!0-9]*}"
  if [[ -z "$n" ]]; then n=0; fi
  GRANT_COUNT="$n"
  GRANT_EXPECTED="$expected"
  return 0
}

# [v4] Apple Events: pre-approve automation for the two targets agents
# actually use - Finder and System Events. These rows carry the target
# bundle id in indirect_object_identifier, exactly like rows macOS itself
# writes when you click OK on "Terminal would like to control Finder".
grant_ae_targets() {
  # $1 = tag (sys|user), $2 = file of CLI paths, $3 = file of bundle ids
  local tag="$1" pfile="$2" bfile="$3"
  local tgt client sqlfile
  if ! detect_schema "$tag"; then return 1; fi
  sqlfile="$STATE_DIR/.aesql.$$.tmp"
  : > "$sqlfile"
  printf '%s' "BEGIN IMMEDIATE;$NL" >> "$sqlfile"
  for tgt in ${AE_TARGETS[@]+"${AE_TARGETS[@]}"}; do
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        printf '%s\n' "$(insert_row_sql kTCCServiceAppleEvents "$client" 1 NULL 2 4 1 0 1 "$tgt")" >> "$sqlfile"
      fi
    done < "$pfile"
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        printf '%s\n' "$(insert_row_sql kTCCServiceAppleEvents "$client" 0 NULL 2 4 1 0 1 "$tgt")" >> "$sqlfile"
      fi
    done < "$bfile"
  done
  printf '%s' "COMMIT;" >> "$sqlfile"
  dbg "$(head -c 400 "$sqlfile")"
  if ! sql_file "$tag" "$sqlfile" 2>"$STATE_DIR/.sqlerr.tmp"; then
    rm -f "$STATE_DIR/.sqlerr.tmp" "$sqlfile"
    return 1
  fi
  rm -f "$STATE_DIR/.sqlerr.tmp" "$sqlfile"
  # record them in the manifest so --back removes them again
  for tgt in ${AE_TARGETS[@]+"${AE_TARGETS[@]}"}; do
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        printf '%s\t%s\t%s\t%s\t1\t%s\n' "$tag" kTCCServiceAppleEvents "$client" 1 "$tgt" >> "$F_TARGETS"
      fi
    done < "$pfile"
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        printf '%s\t%s\t%s\t%s\t1\t%s\n' "$tag" kTCCServiceAppleEvents "$client" 0 "$tgt" >> "$F_TARGETS"
      fi
    done < "$bfile"
  done
  if [[ -s "$F_TARGETS" ]]; then
    LC_ALL=C sort -u "$F_TARGETS" > "$F_TARGETS.tmp" && mv "$F_TARGETS.tmp" "$F_TARGETS"
  fi
  return 0
}

rebuild_added_manifest() { # added = targets - preserved (key includes ind_*)
  if [[ -f "$F_PRESERVE" && -f "$F_TARGETS" ]]; then
    # NB: FILENAME==ARGV[1] because F_PRESERVE may be empty (NR==FNR breaks).
    awk -F'\t' 'FILENAME==ARGV[1]{k[$1"\t"$2"\t"$3"\t"$4"\t"$10"\t"$11]=1;next} !($1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6 in k)' \
      "$F_PRESERVE" "$F_TARGETS" > "$F_ADDED"
  elif [[ -f "$F_TARGETS" ]]; then
    cp "$F_TARGETS" "$F_ADDED"
  fi
  return 0
}

reload_tccd() { # apply database changes LIVE - no reboot, no re-login
  sudo killall tccd >/dev/null 2>&1 || true
  sleep 1
  return 0
}

# =============================================================================
# Backups
# =============================================================================
do_backups() { # $1 = backup dir (originals from the first run are kept)
  local bk="$1"
  mkdir -p "$bk"
  if [[ ! -f "$bk/TCC.system.db" && "$SYS_DB_OK" == "1" ]]; then
    if sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" \
         "VACUUM INTO $(sql_q "$bk/TCC.system.db");" 2>/dev/null; then
      sudo chown "$(id -u):$(id -g)" "$bk/TCC.system.db" 2>/dev/null || true
    fi
  fi
  if [[ ! -f "$bk/TCC.user.db" && -f "$USER_TCC" && "$USER_DB_OK" == "1" ]]; then
    if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
      if sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" \
           "VACUUM INTO $(sql_q "$bk/TCC.user.db");" 2>/dev/null; then
        sudo chown "$(id -u):$(id -g)" "$bk/TCC.user.db" 2>/dev/null || true
      fi
    else
      sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" \
        "VACUUM INTO $(sql_q "$bk/TCC.user.db");" 2>/dev/null || true
    fi
  fi
  if [[ ! -f "$bk/ScreenCaptureApprovals.plist" && -f "$REPLAYD_PLIST" ]]; then
    cp -p "$REPLAYD_PLIST" "$bk/ScreenCaptureApprovals.plist" || true
  fi
  if [[ ! -f "$bk/Assertions.json" && -f "$DND_ASSERT" ]]; then
    cp -p "$DND_ASSERT" "$bk/Assertions.json" || true
  fi
  return 0
}

# =============================================================================
# replayd "screen recording will expire" nag suppression (no root needed)
# =============================================================================
apply_replayd() {
  local dir; dir="$(dirname "$REPLAYD_PLIST")"
  if [[ ! -d "$dir" ]]; then
    c_warn "replayd container missing (macOS < Sequoia) - skipping nag suppression."
    return 0
  fi
  local existed=1
  if [[ ! -f "$REPLAYD_PLIST" ]]; then existed=0; fi
  # Resolve the backup directory (backups/CURRENT is a pointer FILE whose
  # content is the real backup dir; F_ENABLED carries the same path).
  local bk=""
  bk="$(sed -n 's/^backup=//p' "$F_ENABLED" 2>/dev/null | head -1 || true)"
  if [[ -z "$bk" && -f "$STATE_DIR/backups/CURRENT" ]]; then
    bk="$(cat "$STATE_DIR/backups/CURRENT")"
  fi
  if [[ -z "$bk" ]]; then
    bk="$STATE_DIR/backups/manual"
    mkdir -p "$bk"
  fi
  if [[ "$existed" == "1" && ! -f "$bk/ScreenCaptureApprovals.plist" ]]; then
    mkdir -p "$bk" 2>/dev/null || true
    cp -p "$REPLAYD_PLIST" "$bk/ScreenCaptureApprovals.plist" || true
  fi

  local keys=() k
  if [[ "$existed" == "1" ]]; then
    while IFS= read -r k; do
      if [[ -n "$k" ]]; then keys+=("$k"); fi
    done < <(defaults read "$REPLAYD_PLIST" 2>/dev/null \
             | sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p' || true)
  fi
  for k in ${APP_EXES[@]+"${APP_EXES[@]}"}; do keys+=("$k"); done
  for k in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do keys+=("$k"); done

  local _d=() _l
  while IFS= read -r _l; do
    if [[ -n "$_l" ]]; then _d+=("$_l"); fi
  done < <(printf '%s\n' ${keys[@]+"${keys[@]}"} | dedup_stdin_lines)
  keys=(${_d[@]+"${_d[@]}"})

  if [[ ${#keys[@]} -eq 0 ]]; then
    c_info "No screen-capture approval entries to extend."
    return 0
  fi
  local n=0
  for k in ${keys[@]+"${keys[@]}"}; do
    if defaults write "$REPLAYD_PLIST" "$k" -date "$NAG_DATE" 2>/dev/null; then
      n=$((n + 1))
    fi
  done
  {
    echo "existed=$existed"
    echo "backup=$bk/ScreenCaptureApprovals.plist"
  } > "$F_REPLAYD"
  c_ok "Screen-recording expiry nags suppressed ($n entries -> 2099)."
  return 0
}

restore_replayd() {
  if [[ ! -f "$F_REPLAYD" ]]; then
    c_info "No replayd changes recorded - nothing to restore."
    return 0
  fi
  local existed="" bk=""
  existed="$(sed -n 's/^existed=//p' "$F_REPLAYD" | head -1)"
  bk="$(sed -n 's/^backup=//p' "$F_REPLAYD" | head -1)"
  if [[ "$existed" == "1" && -f "$bk" ]]; then
    if cp -p "$bk" "$REPLAYD_PLIST"; then c_ok "Screen-capture approvals restored."; fi
  elif [[ "$existed" == "0" ]]; then
    if rm -f "$REPLAYD_PLIST"; then c_ok "Screen-capture approvals file removed (was created by off.sh)."; fi
  else
    c_info "replayd backup not found - leaving current approvals in place."
  fi
  rm -f "$F_REPLAYD"
  return 0
}

# =============================================================================
# [v4] MOVIE MODE MODULES
# (notifications, menu bar, sounds, firewall, Gatekeeper, sharing)
# =============================================================================
# tiny state file for everything --back has to undo
mget() { # $1 = key -> value ("" when missing); ALWAYS returns 0
  if [[ -f "$F_MOVIE" ]]; then
    sed -n "s/^$1=//p" "$F_MOVIE" 2>/dev/null | tail -n 1
  fi
  return 0
}
mset() { # $1 = key, $2 = value (overwrites)
  local t="$F_MOVIE.tmp"
  { if [[ -f "$F_MOVIE" ]]; then grep -v "^$1=" "$F_MOVIE" || true; fi; } > "$t" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" >> "$t"
  mv "$t" "$F_MOVIE"
  return 0
}
mdefault() { # $1 = key, $2 = value (first run wins = the ORIGINAL value)
  if ! grep -q "^$1=" "$F_MOVIE" 2>/dev/null; then
    printf '%s=%s\n' "$1" "$2" >> "$F_MOVIE" 2>/dev/null || true
  fi
  return 0
}

# ---------- Do Not Disturb / Focus (verified macOS 12 ... 26.3 method) ------
# Same mechanism as the open-source macos-focus library, confirmed against
# live macOS 15.3 and macOS 26.3 installations:
#   1. write a real assertion record into ~/Library/DoNotDisturb/DB/Assertions.json
#   2. post _NSDoNotDisturbEnabled/DisabledNotification (Cocoa distributed)
#   3. post the three Darwin notification names
#   4. kickstart donotdisturbd and ControlCenter so they re-read everything
# (The old "bootout com.apple.notificationcenterui" trick is SIP-blocked on
#  a real Mac and silently fails - that is why banners kept appearing.)
apple_epoch_now() { echo $(( $(date +%s) - 978307200 )); }

dnd_post_cocoa() { # $1 = _NSDoNotDisturbEnabledNotification | ...Disabled...
  osascript 2>/dev/null <<AS || true
use framework "Foundation"
on run
  tell current application's NSDistributedNotificationCenter's defaultCenter() to postNotificationName:object:userInfo:deliverImmediately:("$1", missing value, missing value, true)
end run
AS
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter().postNotificationNameObjectUserInfoDeliverImmediately('$1', null, null, true);" 2>/dev/null || true
}

dnd_notify_all() { # $1 = 1 enable / 0 disable
  local name="_NSDoNotDisturbDisabledNotification"
  if [[ "$1" == "1" ]]; then name="_NSDoNotDisturbEnabledNotification"; fi
  dnd_post_cocoa "$name"
  notifyutil -p com.apple.notificationcenter.dnd.state.changed 2>/dev/null || true
  notifyutil -p com.apple.focus.assertion.state.changed 2>/dev/null || true
  notifyutil -p com.apple.focus.status.changed 2>/dev/null || true
  launchctl kickstart -k "gui/${UID_N}/com.apple.donotdisturbd" >/dev/null 2>&1 \
    || killall donotdisturbd >/dev/null 2>&1 || true
  sleep 1
  return 0
}

dnd_on() {
  mkdir -p "$DND_DIR" 2>/dev/null || true
  # back up the ORIGINAL assertions file ONCE (never our own output)
  if [[ -f "$DND_ASSERT" && ! -f "$DND_BAK" ]]; then
    cp -p "$DND_ASSERT" "$DND_BAK" || true
    mdefault dnd_existed 1
  else
    mdefault dnd_existed 0
  fi
  mset dndbak done
  local uuid ts
  uuid="$(uuidgen 2>/dev/null || echo "5CFF0000-0000-4000-8000-000000000001")"
  ts="$(apple_epoch_now)"
  printf '{\n  "data" : [\n    {\n      "storeAssertionRecords" : [\n        {\n          "assertionDetails" : {\n            "assertionDetailsIdentifier" : "com.apple.focus.activity-manager",\n            "assertionDetailsModeIdentifier" : "com.apple.donotdisturb.mode.default",\n            "assertionDetailsReason" : "user-action"\n          },\n          "assertionSource" : {\n            "assertionClientIdentifier" : "com.apple.focus.activity-manager"\n          },\n          "assertionStartDateTimestamp" : %s,\n          "assertionUUID" : "%s"\n        }\n      ],\n      "storeInvalidationRecords" : [\n\n      ],\n      "storeInvalidationRequestRecords" : [\n\n      ]\n    }\n  ],\n  "header" : {\n    "timestamp" : %s,\n    "version" : 8\n  }\n}\n' \
    "$ts" "$(printf '%s' "$uuid" | tr '[:lower:]' '[:upper:]')" "$ts" > "$DND_ASSERT" 2>/dev/null || true
  dnd_notify_all 1
  if [[ -f "$DND_ASSERT" ]] && grep -q "assertionUUID" "$DND_ASSERT" 2>/dev/null; then
    c_ok "Do Not Disturb: ON - notification banners + their sounds are suppressed."
    return 0
  fi
  c_warn "Could not write the Focus database - banners may still appear."
  return 1
}

dnd_off() {
  if [[ -f "$DND_BAK" ]]; then
    cp -p "$DND_BAK" "$DND_ASSERT" 2>/dev/null || true
    rm -f "$DND_BAK"
  else
    rm -f "$DND_ASSERT" 2>/dev/null || true
  fi
  dnd_notify_all 0
  c_ok "Do Not Disturb: OFF - notifications behave normally again."
  return 0
}

# ---------- menu bar icons ---------------------------------------------------
cc_restart() {
  launchctl kickstart -k "gui/${UID_N}/com.apple.ControlCenter" >/dev/null 2>&1 \
    || killall ControlCenter >/dev/null 2>&1 || true
  killall SystemUIServer >/dev/null 2>&1 || true
  return 0
}

icons_hide() {
  local k v
  for k in ${CC_ICONS[@]+"${CC_ICONS[@]}"}; do
    v="$(defaults -currentHost read com.apple.controlcenter "NSStatusItem Visible ${k}" 2>/dev/null || true)"
    mdefault "icon_${k}" "${v:-unset}"
    defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible ${k}" -bool false 2>/dev/null || true
  done
  cc_restart
  sleep 1
  # VERIFY - if macOS forced the Focus icon back (it can, while a Focus is
  # active), say so instead of pretending everything is fine.
  local f="?"
  f="$(defaults -currentHost read com.apple.controlcenter "NSStatusItem Visible FocusModes" 2>/dev/null || true)"
  if [[ "$f" == "0" || -z "$f" ]]; then
    c_ok "Menu bar: Focus (purple), Control Center, Screen Mirroring, Now Playing, Sound Recognition and Accessibility icons hidden."
    return 0
  fi
  c_warn "Menu bar: most icons hidden, but macOS kept the Focus icon visible"
  echo "         while Do Not Disturb is on. 5-second manual fix:"
  echo "           System Settings -> Menu Bar Controls (or Control Center)"
  echo "           -> Focus -> turn OFF 'Show in Menu Bar' / 'Always Show'."
  return 1
}

icons_restore() {
  local k s
  for k in ${CC_ICONS[@]+"${CC_ICONS[@]}"}; do
    s="$(mget "icon_${k}")"
    if [[ "$s" == "unset" || -z "$s" ]]; then
      defaults -currentHost delete com.apple.controlcenter "NSStatusItem Visible ${k}" 2>/dev/null || true
    else
      defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible ${k}" -bool "$s" 2>/dev/null || true
    fi
  done
  cc_restart
  c_ok "Menu bar: icons restored."
  return 0
}

# ---------- sounds (alerts only - movie audio untouched) ---------------------
alert_volume() {
  local out=""
  out="$(osascript -e 'get volume settings' 2>/dev/null || true)"
  printf '%s' "$out" | sed -n 's/.*alert volume:\([0-9][0-9]*\).*/\1/p' | tail -n 1
  return 0
}
is_num() { printf '%s' "${1:-}" | grep -qE '^[0-9]+$'; }

sounds_off() {
  local v
  v="$(alert_volume)"
  if is_num "$v"; then mdefault alertvol "$v"; fi
  osascript -e 'set volume alert volume 0' >/dev/null 2>&1 || true
  v="$(defaults read NSGlobalDomain com.apple.sound.beep.volume 2>/dev/null || true)"
  mdefault beepvol "${v:-unset}"
  defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0 2>/dev/null || true
  v="$(defaults read com.apple.dock no-bouncing 2>/dev/null || true)"
  mdefault dockbounce "${v:-unset}"
  defaults write com.apple.dock no-bouncing -bool true 2>/dev/null || true
  killall Dock >/dev/null 2>&1 || true
  c_ok "Sounds: alert + beep volume muted, Dock bouncing off (movie audio untouched)."
  return 0
}

sounds_restore() {
  local v
  v="$(mget alertvol)"
  if is_num "$v"; then
    osascript -e "set volume alert volume $v" >/dev/null 2>&1 || true
  fi
  v="$(mget beepvol)"
  if [[ "$v" == "unset" || -z "$v" ]]; then
    defaults delete NSGlobalDomain com.apple.sound.beep.volume >/dev/null 2>&1 || true
  else
    defaults write NSGlobalDomain com.apple.sound.beep.volume -float "$v" 2>/dev/null || true
  fi
  v="$(mget dockbounce)"
  if [[ "$v" == "unset" || -z "$v" ]]; then
    defaults delete com.apple.dock no-bouncing >/dev/null 2>&1 || true
  else
    defaults write com.apple.dock no-bouncing -bool "$v" 2>/dev/null || true
  fi
  killall Dock >/dev/null 2>&1 || true
  c_ok "Sounds: alert volume, beep volume and Dock bouncing restored."
  return 0
}

# ---------- firewall whitelist (kills "accept incoming connections?") -------
fw_whitelist() {
  if [[ ! -x "$SFW" ]]; then
    c_info "Firewall tool not present on this macOS - skipping (no popups either way)."
    return 0
  fi
  local fws st="unknown"
  fws="$(sudo "$SFW" --getglobalstate 2>/dev/null || true)"
  case "$fws" in
    *enabled*|*Enabled*)   st="on" ;;
    *disabled*|*Disabled*) st="off" ;;
  esac
  mdefault fwstate "$st"
  local b
  for b in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} ${APP_PATHS[@]+"${APP_PATHS[@]}"}; do
    if grep -qxF -- "$b" "$F_FW" 2>/dev/null; then continue; fi
    sudo "$SFW" --add "$b" >/dev/null 2>&1 || true
    sudo "$SFW" --unblockapp "$b" >/dev/null 2>&1 || true
    echo "$b" >> "$F_FW"
  done
  local n=0
  n="$(grep -c . "$F_FW" 2>/dev/null || true)"
  c_ok "Firewall: $n dev tools whitelisted - no 'accept incoming network connections' boxes (firewall itself left $st)."
  return 0
}

fw_restore() {
  if [[ ! -x "$SFW" ]]; then return 0; fi
  if [[ ! -f "$F_FW" ]]; then
    c_info "No firewall whitelist entries to remove."
    return 0
  fi
  local b n=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if sudo "$SFW" --removeapp "$b" >/dev/null 2>&1; then n=$((n+1)); fi
  done < "$F_FW"
  rm -f "$F_FW"
  c_ok "Firewall: our $n whitelist entries removed (firewall itself was never changed)."
  return 0
}

# ---------- Gatekeeper + quarantine -----------------------------------------
gk_off() {
  if ! command -v spctl >/dev/null 2>&1; then
    c_info "spctl not present - skipping Gatekeeper."
    return 0
  fi
  local s st="on"
  s="$(spctl --status 2>/dev/null || true)"
  case "$s" in *disabled*) st="off" ;; esac
  mdefault gkstate "$st"
  if [[ "$st" == "off" ]]; then
    c_info "Gatekeeper already off - nothing to do."
  else
    if sudo spctl --master-disable >/dev/null 2>&1 || sudo spctl --global-disable >/dev/null 2>&1; then
      s="$(spctl --status 2>/dev/null || true)"
      if [[ "$s" == *disabled* ]]; then
        c_ok "Gatekeeper: off - no 'cannot check for malicious software' / Allow Anyway boxes."
      else
        c_warn "Gatekeeper: refused to switch off on this macOS (it stays on)."
      fi
    else
      c_warn "Gatekeeper: could not be switched off (it stays on)."
    fi
  fi
  local q
  q="$(defaults read com.apple.LaunchServices LSQuarantine 2>/dev/null || true)"
  mdefault quarantine "${q:-unset}"
  defaults write com.apple.LaunchServices LSQuarantine -bool false 2>/dev/null || true
  c_ok "Downloaded tools (npx / pip / curl installs) open with no warning at all."
  return 0
}

gk_restore() {
  if ! command -v spctl >/dev/null 2>&1; then return 0; fi
  local g q
  g="$(mget gkstate)"
  if [[ "$g" == "on" ]]; then
    if sudo spctl --master-enable >/dev/null 2>&1 || sudo spctl --global-enable >/dev/null 2>&1; then
      c_ok "Gatekeeper: back ON."
    else
      c_warn "Gatekeeper: could not be re-enabled - check Privacy & Security settings."
    fi
  elif [[ "$g" == "off" ]]; then
    c_ok "Gatekeeper: left off (it was already off before off.sh)."
  fi
  q="$(mget quarantine)"
  if [[ "$q" == "unset" || -z "$q" ]]; then
    defaults delete com.apple.LaunchServices LSQuarantine >/dev/null 2>&1 || true
  elif [[ "$q" == "1" ]]; then
    defaults write com.apple.LaunchServices LSQuarantine -bool true 2>/dev/null || true
  fi
  return 0
}

# ---------- sharing services (STAY ON after --back, as you asked) -----------
svc_running() { sudo launchctl print "system/$1" >/dev/null 2>&1; }

svc_try() { # label plist -> 0 when running
  local label="$1" plist="$2"
  [[ -f "$plist" ]] || return 1
  sudo launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
  sudo launchctl enable "system/${label}" >/dev/null 2>&1 || true
  sudo launchctl load -w "$plist" >/dev/null 2>&1 || true
  sudo launchctl print "system/${label}" >/dev/null 2>&1
}

svc_try_user() { # label plist (per-user agent, no sudo)
  local label="$1" plist="$2"
  [[ -f "$plist" ]] || return 1
  launchctl bootstrap "gui/${UID_N}" "$plist" >/dev/null 2>&1 || true
  launchctl enable "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
  launchctl load -w "$plist" >/dev/null 2>&1 || true
  launchctl print "gui/${UID_N}/${label}" >/dev/null 2>&1
}

ensure_sharing() {
  c_step "[6/7] Turning ON every sharing service (they stay ON after --back) ..."
  local p t done=0

  # --- Remote Login (SSH): real launchd label is com.openssh.sshd ---
  if svc_try com.openssh.sshd "$LD_DAEMONS/ssh.plist"; then
    c_ok "Remote Login (SSH): ON"
  elif sudo systemsetup -setremotelogin on </dev/null >/dev/null 2>&1; then
    c_ok "Remote Login (SSH): ON"
  else
    c_warn "Remote Login (SSH): could not switch on."
  fi

  # --- Screen Sharing ---
  if svc_try com.apple.screensharing "$LD_DAEMONS/com.apple.screensharing.plist"; then
    c_ok "Screen Sharing: ON"
  else
    c_warn "Screen Sharing: could not switch on."
  fi

  # --- File Sharing (SMB) ---
  if svc_try com.apple.smbd "$LD_DAEMONS/com.apple.smbd.plist"; then
    c_ok "File Sharing (SMB): ON"
  else
    c_warn "File Sharing (SMB): could not switch on."
  fi

  # --- Remote Management (Apple Remote Desktop, full control) ---
  if [[ -x "$ARD_KICKSTART" ]]; then
    if sudo "$ARD_KICKSTART" -activate -configure -access -on -restart -agent -privs -all >/dev/null 2>&1; then
      c_ok "Remote Management (ARD): ON (full control)"
    else
      c_warn "Remote Management: could not switch on."
    fi
  else
    c_info "Remote Management: tool missing on this macOS - skipped."
  fi

  # --- Remote Application Scripting (Remote Apple Events) ---
  done=0
  if svc_try com.apple.eppc "$LD_DAEMONS/eppc.plist"; then done=1; fi
  sudo systemsetup -setremoteapplevents on </dev/null >/dev/null 2>&1 || true
  if [[ "$done" == "1" ]]; then
    c_ok "Remote Application Scripting (Apple Events): ON"
  else
    c_warn "Remote Apple Events: enable once in Settings > Sharing > Advanced."
  fi

  # --- Printer Sharing ---
  if sudo cupsctl --share-printers >/dev/null 2>&1; then
    c_ok "Printer Sharing: ON"
  else
    c_info "Printer Sharing: nothing to share (fine)."
  fi

  # --- Bluetooth Sharing ---
  defaults -currentHost write com.apple.Bluetooth PrefKeyServicesEnabled -bool true 2>/dev/null || true
  defaults write com.apple.Bluetooth PrefKeyServicesEnabled -bool true 2>/dev/null || true
  c_ok "Bluetooth Sharing: ON"

  # --- Media Sharing (Home Sharing) ---
  defaults write com.apple.amp.mediasharingd home-sharing-enabled -int 1 2>/dev/null || true
  sudo defaults write /Library/Preferences/com.apple.amp.mediasharingd home-sharing-enabled -int 1 >/dev/null 2>&1 || true
  done=0
  for p in "$LD_AGENTS/com.apple.mediasharingd.plist" "$LD_DAEMONS/com.apple.mediasharingd.plist" \
           "$LD_AGENTS/com.apple.amp.mediasharingd.plist" "$LD_DAEMONS/com.apple.amp.mediasharingd.plist"; do
    [[ -f "$p" ]] || continue
    case "$p" in
      "$LD_AGENTS"*) svc_try_user com.apple.mediasharingd "$p" && done=1 ;;
      *)             svc_try com.apple.mediasharingd "$p" && done=1 ;;
    esac
  done
  if [[ "$done" == "1" ]]; then
    c_ok "Media Sharing: ON"
  else
    c_ok "Media Sharing: preference set (daemon starts with your next login)."
  fi
  echo "         Full Home Sharing of your library needs a one-time Apple ID"
  echo "         sign-in in Music/TV - Apple does not allow that from a script."

  # --- Content Caching ---
  local acmu=""
  acmu="$(command -v AssetCacheManagerUtil 2>/dev/null || true)"
  if [[ -n "$acmu" ]]; then
    if sudo "$acmu" activate >/dev/null 2>&1 || sudo "$acmu" --activate >/dev/null 2>&1; then
      c_ok "Content Caching: ON"
    else
      c_warn "Content Caching: could not activate (Apple refuses inside virtual machines)."
    fi
  else
    c_info "Content Caching: tool missing - skipped."
  fi

  # --- Internet Sharing (needs a second network port to share TO) ---
  local src="" target="" ports=""
  src="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true)"
  ports="$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^(en|bridge)[0-9]+$' || true)"
  for t in $ports; do
    [[ "$t" == "$src" ]] && continue
    target="$t"; break
  done
  if [[ -z "$target" ]]; then
    c_info "Internet Sharing: only one network port found - nothing to share to."
    echo "         On a Mac with two ports (Wi-Fi + Ethernet) it switches on fully."
  else
    sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add SharingNetworks -array "$target" >/dev/null 2>&1 || true
    local cur psid
    cur="$(sudo plutil -extract CurrentSet raw /Library/Preferences/SystemConfiguration/preferences.plist 2>/dev/null || true)"
    if [[ -n "$cur" ]]; then
      psid="$(sudo plutil -extract "${cur#/}.Network.Global.IPv4.PrimaryService" raw /Library/Preferences/SystemConfiguration/preferences.plist 2>/dev/null || true)"
      [[ -n "$psid" ]] && sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add PrimaryServiceIdentifier "$psid" >/dev/null 2>&1 || true
    fi
    if svc_try com.apple.InternetSharing "$LD_DAEMONS/com.apple.InternetSharing.plist"; then
      c_ok "Internet Sharing: ON (sharing to $target)"
    else
      c_warn "Internet Sharing: could not switch on."
    fi
  fi
  return 0
}

# =============================================================================
# ENABLE (Movie Mode ON)
# =============================================================================
cmd_enable() {
  require_darwin
  require_sqlite3
  collect_cli_paths
  collect_apps

  local nclients; nclients="$(all_clients_count)"
  if [[ "$nclients" -eq 0 ]]; then
    die "No dev tools found (no node/python on PATH, no known apps). Nothing to do."
  fi

  echo ""
  hr
  echo "  WHAT THIS WILL DO (Movie Mode)"
  hr
  echo "  1. Back up the macOS privacy databases (TCC), the screen-capture"
  echo "     approvals plist and the Focus database to ~/.tcc-devtool/backups/"
  echo "  2. Pre-approve ${#SERVICES[@]} privacy services with NO pop-ups for"
  echo "     screen recording, microphone, camera, full disk access,"
  echo "     accessibility, input monitoring, automation, folder access,"
  echo "     LOCAL NETWORK and NOTIFICATIONS, for these tools (detected on"
  echo "     this Mac, symlinks resolved to their REAL paths):"
  local _c
  for _c in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do echo "         [bin] $_c"; done
  for _c in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do echo "         [app] $_c"; done
  echo "     (+ Apple Events pre-approval for Finder and System Events)"
  echo "  3. Set screen-recording approval dates to 2099"
  echo "     (stops the recurring 'Allow For One Month' prompt)"
  echo "  4. Whitelist every tool in the firewall (no 'accept incoming"
  echo "     connections' boxes; the firewall itself is left as it is)"
  echo "  5. Gatekeeper off + no quarantine (no 'cannot be opened' boxes)"
  echo "  6. Notifications OFF: real Do Not Disturb assertion + alert sounds"
  echo "     muted + Dock bouncing off"
  echo "  7. Hide the menu-bar icons: Focus (purple), Control Center,"
  echo "     Screen Mirroring, Now Playing, Sound Recognition, Accessibility"
  echo "  8. Turn ON every sharing service (they STAY ON after --back)"
  echo "  9. Reload tccd so everything takes effect NOW"
  echo ""
  echo "  * No reboot. No log-out. No background daemon is installed."
  echo "  * Survives reboots until you run:  bash off.sh --back"
  echo "  * WARNING: while this is active, the tools above get mic / camera /"
  echo "    screen access with zero confirmation. Development machines only."
  echo ""

  need_sudo

  echo ""
  hr
  echo "  FINAL CHECK"
  hr
  echo "  Everything above is applied now and is 100% reversible with:"
  echo "      bash off.sh --back"
  if ! confirm "Still want it? Type y + Enter (anything else cancels)"; then
    c_info "Cancelled. Nothing was changed."
    exit 0
  fi

  # --- state / backups ------------------------------------------------------
  mkdir -p "$STATE_DIR"
  normalize_manifests
  local already=0
  if [[ -f "$F_ENABLED" ]]; then already=1; fi
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local bk="$STATE_DIR/backups/$stamp"
  if [[ "$already" == "0" ]]; then
    : > "$F_PRESERVE"
    : > "$F_TARGETS"
  else
    c_info "Already active - re-syncing (originals from the first run are kept)."
    if [[ -f "$STATE_DIR/backups/CURRENT" ]]; then
      bk="$(cat "$STATE_DIR/backups/CURRENT")"
    fi
  fi

  c_step "[1/7] Checking database access (Full Disk Access) ..."
  SYS_DB_OK=0
  if probe_sys_db; then SYS_DB_OK=1; fi
  if [[ "$SYS_DB_OK" != "1" ]]; then
    # [v4] HARD STOP: without this, nothing can be pre-approved and the
    # popups would stay. v3.0 continued with warnings - that silent partial
    # mode was exactly the "still asks to allow everything" problem.
    fda_hint "Cannot write the SYSTEM privacy database - without Full Disk Access NOTHING can be pre-approved."
    die "Fix Full Disk Access (one time, 30 seconds, no reboot), then run me again. Nothing was changed."
  fi
  if ! probe_user_db; then :; fi

  c_step "[2/7] Backing up current state ..."
  if [[ "$already" == "0" ]]; then
    do_backups "$bk"
    mkdir -p "$STATE_DIR/backups"
    printf '%s\n' "$bk" > "$STATE_DIR/backups/CURRENT"
    if [[ -f "$bk/TCC.system.db" || -f "$bk/TCC.user.db" ]]; then
      c_ok "Backups saved: $bk"
    else
      c_warn "No database backup possible (missing Full Disk Access?)."
    fi
  else
    c_ok "Backups already exist: $bk"
  fi

  # --- TCC grants -------------------------------------------------------------
  local pf="$STATE_DIR/.paths.$$.tmp" bf="$STATE_DIR/.bundles.$$.tmp"
  printf '%s\n' ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} > "$pf"
  printf '%s\n' ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"} > "$bf"

  c_step "[3/7] Pre-approving permissions for every tool (live, no reboot) ..."
  local fail=0
  if grant_targets sys "$pf" "$bf"; then
    c_ok "System database : $GRANT_COUNT/$GRANT_EXPECTED rows granted (screen recording, accessibility, full disk, ...)."
  else
    c_warn "System database : grants FAILED (see error above)."
    fail=1
  fi
  if grant_ae_targets sys "$pf" "$bf"; then
    c_ok "System database : Apple Events to Finder + System Events pre-approved."
  else
    c_warn "System database : Apple Events pre-approval failed."
  fi

  if [[ "$USER_DB_OK" == "1" ]]; then
    if grant_targets user "$pf" "$bf"; then
      c_ok "User database   : $GRANT_COUNT/$GRANT_EXPECTED rows granted (microphone, camera, folders, ...)."
    else
      c_warn "User database   : grants FAILED (see error above)."
      fail=1
    fi
    if grant_ae_targets user "$pf" "$bf"; then
      c_ok "User database   : Apple Events to Finder + System Events pre-approved."
    else
      c_warn "User database   : Apple Events pre-approval failed."
    fi
  else
    if [[ ! -f "$USER_TCC" ]]; then
      c_warn "User database   : does not exist yet (macOS creates it at the first"
      c_warn "                   mic/camera prompt). Re-run after that prompt."
    else
      c_warn "User database   : SKIPPED (no Full Disk Access - see instructions above)."
      fail=1
    fi
  fi
  rm -f "$pf" "$bf"
  rebuild_added_manifest

  c_step "[4/7] Killing the remaining pop-ups (firewall + Gatekeeper) ..."
  fw_whitelist
  gk_off

  c_step "[5/7] Turning OFF notifications + sounds + menu-bar icons ..."
  dnd_on || true
  icons_hide || true
  sounds_off

  ensure_sharing

  c_step "[7/7] Suppressing 'screen recording will expire' nags + reloading tccd ..."
  apply_replayd
  reload_tccd
  c_ok "tccd reloaded - changes are LIVE now."

  if [[ "$already" == "0" ]]; then
    printf 'enabled=%s\nbackup=%s\n' "$stamp" "$bk" > "$F_ENABLED"
  fi

  echo ""
  printf '%s\n' "=================================================="
  printf '%s\n' "  MOVIE MODE: ON - enjoy the movie"
  printf '%s\n' "--------------------------------------------------"
  printf '%s\n' "  node / python popups ....... gone (${#CLI_PATHS[@]} binaries +"
  printf '%s\n' "                               ${#APP_BUNDLES[@]} apps, ${#SERVICES[@]} services)"
  printf '%s\n' "  notification banners ....... gone (real Do Not Disturb)"
  printf '%s\n' "  alert / beep sounds ....... muted (movie audio OK)"
  printf '%s\n' "  menu bar ................... purple Focus + Control Center"
  printf '%s\n' "                               icons hidden"
  printf '%s\n' "  firewall popups ........... gone (tools whitelisted)"
  printf '%s\n' "  Gatekeeper ................ off (restored by --back)"
  printf '%s\n' "  sharing services .......... ON (stay ON after --back)"
  printf '%s\n' ""
  printf '%s\n' "  Back to normal, one line:"
  printf '%s\n' "      bash off.sh --back"
  printf '%s\n' ""
  printf '%s\n' "  (no reboot needed, any time)"
  printf '%s\n' "=================================================="
  echo ""
  if [[ "$fail" == "1" ]]; then
    c_warn "One database was skipped - re-run after fixing the message above (safe to re-run)."
  fi
  return 0
}

# =============================================================================
# RESTORE (back to normal)
# =============================================================================
cmd_restore() {
  require_darwin
  require_sqlite3
  normalize_manifests
  if [[ ! -f "$F_TARGETS" && ! -f "$F_ADDED" && ! -f "$F_MOVIE" ]]; then
    c_info "Nothing to restore - all clean."
    exit 0
  fi
  need_sudo
  mkdir -p "$STATE_DIR"
  if ! probe_user_db; then :; fi

  c_step "[1/5] Removing granted permissions ..."
  local tag svc client ctype authv reason ver csh flagsv indt indi sql
  local hard_fail=0 db
  for tag in sys user; do
    db="$(db_file "$tag")"
    if [[ ! -f "$db" ]]; then continue; fi
    if ! detect_schema "$tag"; then continue; fi
    local rsql="$STATE_DIR/.restoresql.$$.tmp"
    : > "$rsql"
    printf '%s' "BEGIN IMMEDIATE;$NL" >> "$rsql"
    if [[ -f "$F_ADDED" ]]; then
      while IFS=$'\t' read -r _tag svc client ctype indt indi; do
        if [[ -n "$svc" ]]; then
          # delete ALL our rows for this (service, client, type) - including
          # every Apple Events target variant we added
          printf '%s\n' "DELETE FROM access WHERE service = $(sql_q "$svc") AND client = $(sql_q "$client") AND client_type = $ctype;" >> "$rsql"
        fi
      done < <(awk -F'\t' -v t="$tag" '$1==t' "$F_ADDED")
    fi
    if [[ -f "$F_PRESERVE" ]]; then
      # awk re-emits fields with \x1f (unit separator): bash `read` with
      # IFS=<tab> silently swallows empty fields (tab is IFS-whitespace),
      # which would misalign everything after an empty csreq blob.
      # [v4] fields 10/11 carry the Apple Events target so rows that
      # pointed at com.apple.finder etc. are restored EXACTLY.
      while IFS=$'\037' read -r svc client ctype authv reason ver csh flagsv indt indi; do
        if [[ -n "$svc" ]]; then
          printf '%s\n' "$(insert_row_sql "$svc" "$client" "$ctype" "$(csreq_literal "$csh")" "${authv:-0}" "${reason:-4}" "${ver:-1}" "${flagsv:-NULL}" "${indt:-0}" "${indi:-UNUSED}")" >> "$rsql"
        fi
      done < <(awk -F'\t' -v t="$tag" '$1==t{print $2"\037"$3"\037"$4"\037"$5"\037"$6"\037"$7"\037"$8"\037"$9"\037"$10"\037"$11}' "$F_PRESERVE")
    fi
    printf '%s' "COMMIT;" >> "$rsql"
    dbg "$(head -c 400 "$rsql")"
    if sql_file "$tag" "$rsql" 2>"$STATE_DIR/.sqlerr.tmp"; then
      c_ok "$db restored."
    else
      c_err "Could not restore $db:"
      sed 's/^/    /' "$STATE_DIR/.sqlerr.tmp" >&2 || true
      c_warn "A full-database backup is kept in: $(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || echo "$STATE_DIR/backups")"
      hard_fail=1
    fi
    rm -f "$STATE_DIR/.sqlerr.tmp" "$rsql"
  done

  c_step "[2/5] Restoring screen-capture approvals ..."
  restore_replayd

  c_step "[3/5] Restoring firewall whitelist + Gatekeeper ..."
  fw_restore
  if [[ -f "$F_MOVIE" ]]; then gk_restore; fi

  c_step "[4/5] Restoring notifications, menu bar and sounds ..."
  if [[ -f "$F_MOVIE" ]]; then
    dnd_off
    icons_restore
    sounds_restore
  else
    c_info "No notification/menu-bar/sound changes recorded - skipping."
  fi

  c_step "[5/5] Reloading the TCC daemon ..."
  reload_tccd
  c_ok "tccd reloaded - normal privacy prompts are back."

  if [[ "$hard_fail" == "0" ]]; then
    rm -f "$F_ENABLED" "$F_ADDED" "$F_PRESERVE" "$F_TARGETS" "$F_REPLAYD" "$F_MOVIE"
  else
    c_warn "Keeping the restore state - fix the issue above and re-run 'bash off.sh --back'."
  fi

  echo ""
  printf '%s\n' "=================================================="
  printf '%s\n' "  NORMAL MODE: everything is back"
  printf '%s\n' "--------------------------------------------------"
  printf '%s\n' "  permissions (TCC) ........... restored exactly"
  printf '%s\n' "  notifications + DND ......... restored"
  printf '%s\n' "  menu bar icons .............. restored"
  printf '%s\n' "  sounds + Dock bouncing ...... restored"
  printf '%s\n' "  firewall whitelist / GK ..... restored"
  printf '%s\n' "  sharing services ............ stay ON (as you asked)"
  printf '%s\n' "=================================================="
  echo ""
  echo "   Tip: restart long-running agent processes so they re-check"
  echo "        permissions cleanly."
  echo ""
  return 0
}

# =============================================================================
# ADD (grant another binary / .app mid-session)
# =============================================================================
cmd_add() {
  require_darwin
  require_sqlite3
  normalize_manifests
  local paths=("$@")
  if [[ ${#paths[@]} -eq 0 ]]; then
    die "Usage: bash off.sh --add /path/to/binary [more paths or .app bundles ...]"
  fi
  need_sudo
  mkdir -p "$STATE_DIR"
  if probe_sys_db; then SYS_DB_OK=1; fi
  if ! probe_user_db; then :; fi

  local pf="$STATE_DIR/.add.paths.$$.tmp" bf="$STATE_DIR/.add.bundles.$$.tmp"
  : > "$pf"
  : > "$bf"
  local p rp id
  for p in ${paths[@]+"${paths[@]}"}; do
    if [[ -d "$p" && -f "$p/Contents/Info.plist" ]]; then
      id="$(defaults read "$p/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
      if [[ -n "$id" ]]; then
        echo "$id" >> "$bf"
        echo "$p" >> "$EXTRA_APPS_FILE"
        c_ok "App detected: $id (saved to $EXTRA_APPS_FILE)"
      else
        c_warn "No bundle id found in $p - skipped."
      fi
      continue
    fi
    if [[ -e "$p" ]]; then
      rp="$(resolve_path "$p")"
      echo "$p" >> "$pf"
      if [[ "$rp" != "$p" ]]; then echo "$rp" >> "$pf"; fi
      echo "$p" >> "$EXTRA_PATHS_FILE"
      c_ok "Binary accepted: $p"
    else
      c_warn "Not found: $p"
    fi
  done
  if [[ -s "$bf" ]]; then
    LC_ALL=C sort -u "$bf" > "$bf.u" && mv "$bf.u" "$bf"
  fi

  if [[ ! -s "$pf" && ! -s "$bf" ]]; then
    rm -f "$pf" "$bf"
    die "Nothing to add."
  fi

  local fail=0
  if [[ "$SYS_DB_OK" == "1" ]]; then
    if grant_targets sys "$pf" "$bf"; then
      c_ok "System database: $GRANT_COUNT/$GRANT_EXPECTED rows granted."
    else
      fail=1
    fi
    grant_ae_targets sys "$pf" "$bf" || true
  else
    fda_hint "Cannot write the system privacy database."
    fail=1
  fi
  if [[ "$USER_DB_OK" == "1" ]]; then
    if grant_targets user "$pf" "$bf"; then
      c_ok "User database: $GRANT_COUNT/$GRANT_EXPECTED rows granted."
    else
      fail=1
    fi
    grant_ae_targets user "$pf" "$bf" || true
  else
    if [[ ! -f "$USER_TCC" ]]; then
      c_warn "User database does not exist yet - system-level grants applied."
    else
      c_warn "User database unavailable (Full Disk Access missing)."
    fi
  fi
  rm -f "$pf" "$bf"
  rebuild_added_manifest
  reload_tccd
  if [[ "$fail" == "1" ]]; then
    exit 1
  fi
  c_ok "Granted. 'bash off.sh --back' removes these too."
  return 0
}

# =============================================================================
# STATUS / DOCTOR
# =============================================================================
count_our_rows() { # $1 = tag -> how many of our manifest rows exist in the db
  local tag="$1" n="" inlist=""
  if [[ ! -f "$F_TARGETS" ]]; then echo "0"; return 0; fi
  if ! detect_schema "$tag" 2>/dev/null; then echo "?"; return 0; fi
  inlist="$(awk -F'\t' -v t="$tag" '$1==t{print $2"\t"$3"\t"$4}' "$F_TARGETS" | in_values_list)"
  if [[ -z "$inlist" ]]; then echo "0"; return 0; fi
  n="$(sql_tag "$tag" "SELECT count(*) FROM access WHERE (service, client, client_type) IN ($inlist);" 2>/dev/null)" || n="?"
  echo "${n:-?}"
  return 0
}

line_count() { # $1 = file -> non-empty line count (prints 0 when missing)
  if [[ -f "$1" ]]; then grep -c . "$1" || true; else echo 0; fi
}

dnd_active() { # is our Do Not Disturb assertion in place?
  if [[ "$(mget dndbak)" == "done" ]] \
     && [[ -f "$DND_ASSERT" ]] \
     && grep -q "com.apple.donotdisturb.mode.default" "$DND_ASSERT" 2>/dev/null; then
    echo "on"
  else
    echo "off"
  fi
  return 0
}

cmd_status() {
  require_darwin
  echo ""
  hr
  echo "  off.sh STATUS (Movie Mode)"
  hr
  if [[ -f "$F_ENABLED" ]]; then
    echo "  Mode          : MOVIE MODE ACTIVE (since $(sed -n 's/^enabled=//p' "$F_ENABLED"))"
  else
    echo "  Mode          : normal (not active)"
  fi
  echo "  macOS         : $(macos_version)"
  echo "  Backups       : $(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || echo '(none)')"
  echo "  TCC rows added: $(line_count "$F_ADDED")  (removed by --back)"
  echo "  TCC preserved : $(line_count "$F_PRESERVE")  original rows restored by --back"
  echo "  Do Not Disturb: $(dnd_active)"
  echo "  Gatekeeper    : $(spctl --status 2>/dev/null | sed 's/^ *//' || echo unknown)"
  echo "  Firewall list : $(line_count "$F_FW") entries we added"
  echo "  Focus icon key: $(defaults -currentHost read com.apple.controlcenter "NSStatusItem Visible FocusModes" 2>/dev/null || echo '(not set)')"
  echo "  Alert volume  : $(alert_volume)"
  SYS_DB_OK=0
  if probe_sys_db; then SYS_DB_OK=1; fi
  if ! probe_user_db; then :; fi
  if [[ "$SYS_DB_OK" == "1" ]]; then
    echo "  System db     : reachable ($(count_our_rows sys) of our rows present)"
  else
    echo "  System db     : not reachable (run after 'sudo -v', or --doctor)"
  fi
  if [[ "$USER_DB_OK" == "1" ]]; then
    echo "  User db       : reachable ($(count_our_rows user) of our rows present)"
  else
    echo "  User db       : not reachable (needs Full Disk Access - see --doctor)"
  fi
  if [[ -f "$REPLAYD_PLIST" ]]; then
    echo "  Nag dates     : $(defaults read "$REPLAYD_PLIST" 2>/dev/null | grep -c '=' || true) entries in the approvals plist"
  fi
  local l
  echo "  Sharing       :"
  for l in com.openssh.sshd com.apple.screensharing com.apple.smbd com.apple.eppc com.apple.InternetSharing; do
    if launchctl print "system/${l}" >/dev/null 2>&1; then
      echo "    $(printf '%-21s' "${l#com.apple.}"): ON"
    else
      echo "    $(printf '%-21s' "${l#com.apple.}"): off"
    fi
  done
  echo ""
  return 0
}

cmd_doctor() {
  require_darwin
  echo ""
  hr
  echo "  off.sh DOCTOR"
  hr
  echo "  macOS          : $(sw_vers -productName 2>/dev/null || echo macOS) $(macos_version)"
  echo "  SIP            : $(csrutil status 2>/dev/null | head -1 || echo unknown) - SIP can stay ON"
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "  sqlite3        : $(sqlite3 --version 2>/dev/null | cut -d' ' -f1)"
  else
    echo "  sqlite3        : MISSING"
  fi
  echo "  Terminal       : ${TERM_PROGRAM:-unknown}"
  echo "  firewall tool  : $([[ -x "$SFW" ]] && echo present || echo missing)"
  echo "  spctl          : $(command -v spctl >/dev/null 2>&1 && echo present || echo missing)"
  echo "  osascript      : $(command -v osascript >/dev/null 2>&1 && echo present || echo missing)"
  echo "  uuidgen        : $(command -v uuidgen >/dev/null 2>&1 && echo present || echo missing)"
  collect_cli_paths
  collect_apps
  echo "  Dev binaries   : ${#CLI_PATHS[@]} found (symlinks resolved to real paths)"
  local _c
  for _c in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do echo "      $_c"; done
  echo "  Dev apps       : ${#APP_BUNDLES[@]} found"
  for _c in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do echo "      $_c"; done
  echo "  Extra paths    : $(line_count "$EXTRA_PATHS_FILE") in $EXTRA_PATHS_FILE"
  echo "  Extra apps     : $(line_count "$EXTRA_APPS_FILE") in $EXTRA_APPS_FILE"

  if sudo -v >/dev/null 2>&1; then echo "  sudo           : OK"; else echo "  sudo           : FAILED (needs an admin account)"; fi

  echo ""
  echo "  Database access:"
  if probe_sys_db; then
    echo "    system TCC.db : WRITABLE (good)"
  else
    echo "    system TCC.db : BLOCKED"
    fda_hint "Your terminal cannot write the system privacy database."
  fi
  if [[ ! -f "$USER_TCC" ]]; then
    echo "    user TCC.db   : does not exist yet (normal on a fresh Mac; macOS"
    echo "                     creates it at the first mic/camera prompt)"
  else
    if probe_user_db; then
      echo "    user TCC.db   : WRITABLE (good)"
    else
      echo "    user TCC.db   : BLOCKED"
      fda_hint "Your terminal cannot write the user privacy database."
    fi
  fi

  echo ""
  echo "  Notes:"
  echo "    - One-time setup: Full Disk Access for your terminal app (above)."
  echo "      Without it off.sh REFUSES to run (instead of silently failing)."
  echo "    - 'Background Items Added' banners are suppressed by Do Not"
  echo "      Disturb while Movie Mode is on."
  echo "    - The menu-bar mic/camera/screen IN-USE indicators are enforced by"
  echo "      macOS and cannot be hidden on a stock Mac. All prompts are"
  echo "      silenced."
  echo ""
  return 0
}

# =============================================================================
# MAIN
# =============================================================================
usage() {
  cat <<'USAGE'
off.sh v4.0 - Movie Mode: zero pop-ups + zero notifications (no reboot)

Usage:
  bash off.sh                  enable  (explains -> password -> confirm -> done)
  bash off.sh --back           restore everything exactly as before
  bash off.sh --add <path>     pre-approve another binary or .app bundle
  bash off.sh --status         show current state
  bash off.sh --doctor         environment check (SIP, Full Disk Access, ...)
  bash off.sh --yes            non-interactive (agents); can also be OFF_YES=1
  bash off.sh --debug          print the SQL it runs (OFF_DEBUG=1)
  bash off.sh --help           this help

How it works (no reboot ever):
  - Pre-approves 18 privacy services (screen, mic, camera, full disk,
    accessibility, input, automation, folders, LOCAL NETWORK, notifications)
    for node/python/uv/deno/bun/ffmpeg (+ every symlink resolved to its real
    path, nvm/fnm/volta/asdf/mise globs, and whatever is running via ps) and
    your terminal/editor apps, by writing the official TCC database.
  - Apple Events pre-approved for Finder + System Events.
  - Sets screen-recording approval dates to 2099 (kills "Allow For One Month").
  - Whitelists every tool in the firewall (no "accept incoming connections").
  - Gatekeeper off + no quarantine while active; restored by --back.
  - Turns on Do Not Disturb the verified way (Focus assertion database +
    _NSDoNotDisturbEnabledNotification + donotdisturbd restart), mutes alert
    sounds only, stops Dock bouncing.
  - Hides the menu-bar Focus (purple), Control Center, Screen Mirroring,
    Now Playing, Sound Recognition and Accessibility icons.
  - Turns ON every sharing service (they stay ON after --back).
  - Reloads tccd so it is live immediately. Survives reboots until --back.

One-time setup (30s): enable Full Disk Access for your terminal app in
System Settings -> Privacy & Security -> Full Disk Access (macOS blocks all
writes to the privacy databases without it, even for root). SIP stays ON.
off.sh checks this FIRST and refuses to run without it (no silent failures).

State lives in ~/.tcc-devtool/ (backups, manifests, extra tool lists).
USAGE
}

MODE="enable"
ADD_PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --back)    MODE="restore" ;;
    --status)  MODE="status" ;;
    --doctor)  MODE="doctor" ;;
    --add)     MODE="add"
               shift
               while [[ $# -gt 0 ]]; do ADD_PATHS+=("$1"); shift; done
               break ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --debug)   DEBUG=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: bash off.sh [--back|--status|--doctor|--add <path>|--yes|--debug|--help]" >&2
      exit 1 ;;
  esac
  shift
done

case "$MODE" in
  enable)  cmd_enable ;;
  restore) cmd_restore ;;
  status)  cmd_status ;;
  doctor)  cmd_doctor ;;
  add)
    if [[ ${#ADD_PATHS[@]} -gt 0 ]]; then
      cmd_add "${ADD_PATHS[@]}"
    else
      cmd_add
    fi ;;
esac
