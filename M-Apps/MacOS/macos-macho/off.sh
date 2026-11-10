#!/bin/bash
# =============================================================================
#  off.sh v4.0 - "DevMode" for macOS 13/14/15/26
# =============================================================================
#  What this fixes
#    1. TCC prompts (screen recording, microphone, camera, files, automation,
#       accessibility, input monitoring, local network, ...) for node/python
#       and the apps that launch them.
#    2. The recurring "node would like to record this computer's screen"
#       replayd nag (macOS 15.1+ uses a dictionary with two dates, not a
#       single date).
#    3. "App Background Activity" / "Background Items Added" notifications
#       via a one-time com.apple.notificationsettings profile.
#    4. The purple Screen Sharing menu extra, when macOS exposes a Control
#       Center preference for it.  The screen-recording privacy indicator is
#       an Apple security indicator and cannot be hidden by any userspace
#       script; that limit is reported honestly.
#
#  Usage
#    bash off.sh                enable (explains -> sudo -> confirm -> apply)
#    bash off.sh --back         restore exactly what was changed
#    bash off.sh --add PATH ... pre-approve another binary / .app
#    bash off.sh --status       show current state
#    bash off.sh --doctor       deep environment / permission diagnostics
#    bash off.sh --refresh      re-sync grants and replayd dates
#    bash off.sh --yes          non-interactive final confirmation
#    bash off.sh --debug        print SQL and decisions (OFF_DEBUG=1)
#    bash off.sh --help
#
#  Design notes
#    - macOS ships Bash 3.2.  This file deliberately avoids Bash 4 features.
#    - System TCC.db and user TCC.db are separate.  macOS with SIP enabled
#      makes the system DB read-only even for root; Full Disk Access does NOT
#      override SIP.  The script detects this with a real write probe and
#      never pretends a system grant succeeded.
#    - User TCC.db is writable with Full Disk Access (or root on a SIP-off
#      development VM).
#    - Every row is snapshotted before it is overwritten.  --back removes the
#      rows we added and puts the original rows (including denied rows) back.
#    - No LaunchDaemon, no wrapper, no sfltool resetbtm, no reboot.
# =============================================================================

set -euo pipefail

VERSION="4.0"
NL=$'\n'
UMASK_SAVED="$(umask)"
umask 077

# --- Paths -------------------------------------------------------------------
STATE_DIR="${OFF_STATE_DIR:-$HOME/.tcc-devtool}"
SYS_TCC="${OFF_SYS_TCC:-/Library/Application Support/com.apple.TCC/TCC.db}"
USER_TCC="${OFF_USER_TCC:-$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
REPLAYD_PLIST="${OFF_REPLAYD_PLIST:-$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist}"

EXTRA_PATHS_FILE="$STATE_DIR/paths.txt"
EXTRA_APPS_FILE="$STATE_DIR/apps.txt"
EXTRA_AE_FILE="$STATE_DIR/ae-targets.txt"

F_ENABLED="$STATE_DIR/enabled.flag"
F_VERSION="$STATE_DIR/version"
F_ADDED="$STATE_DIR/added.tsv"
F_PRESERVE="$STATE_DIR/preserved.tsv"
F_TARGETS="$STATE_DIR/all_targets.tsv"
F_REPLAYD="$STATE_DIR/replayd.state"
F_PROFILE="$STATE_DIR/profile.state"
F_NCPREFS="$STATE_DIR/ncprefs.state"
F_CC="$STATE_DIR/controlcenter.state"
F_MENU="$STATE_DIR/menu.state"
F_AGENT="$STATE_DIR/agent.state"
F_BTM="$STATE_DIR/btm-agent.state"
F_DEVTOOLS="$STATE_DIR/devtools.state"

BTM_PROFILE_ID="com.off.devtool.btm-notifications"
BTM_PROFILE="$STATE_DIR/profiles/Disable-BTM-Notifications.mobileconfig"
AGENT_LABEL="com.off.devtool.replayd-refresh"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_SCRIPT="$STATE_DIR/refresh-replayd.sh"
AGENT_KEYS="$STATE_DIR/replayd-keys.tsv"
AGENT_LOG="$STATE_DIR/replayd-refresh.log"
CC_PLIST="$HOME/Library/Preferences/com.apple.controlcenter.plist"
CC_BACKUP="$STATE_DIR/com.apple.controlcenter.plist"
NCPREFS="$HOME/Library/Preferences/com.apple.ncprefs.plist"
NCPREFS_BACKUP="$STATE_DIR/com.apple.ncprefs.plist"
SS_PLIST="$HOME/Library/Preferences/com.apple.systemuiserver.plist"
SS_BACKUP="$STATE_DIR/com.apple.systemuiserver.plist"
BTM_AGENT_DOMAIN="com.apple.backgroundtaskmanagementagent"

NAG_DATE="2099-01-01 00:00:00 +0000"
SQLITE_TIMEOUT_MS=10000
CSREQ_BIN="$(command -v csreq 2>/dev/null || true)"
CODEDESIGN_BIN="/usr/bin/codesign"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
DEFAULTS_BIN="/usr/bin/defaults"
PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
[[ -x /usr/bin/python3 ]] && PYTHON_BIN="/usr/bin/python3"

# --- State -------------------------------------------------------------------
ASSUME_YES="${OFF_YES:-0}"
DEBUG="${OFF_DEBUG:-0}"
SKIP_PROFILE="${OFF_SKIP_PROFILE:-0}"
SKIP_MENU="${OFF_SKIP_MENU:-0}"
SKIP_AGENT="${OFF_SKIP_AGENT:-0}"

MACOS_MAJOR=0
MACOS_MINOR=0
MACOS_PATCH=0
SIP_ENABLED=0
SIP_DISABLED=0
SIP_UNKNOWN=0
IS_VM=0
BOOT_UUID=""

SYS_DB_PRESENT=0
SYS_DB_READABLE=0
SYS_DB_WRITABLE=0
SYS_DB_STATE="missing"
USER_DB_PRESENT=0
USER_DB_WRITABLE=0
USER_DB_VIA_SUDO=0
USER_DB_STATE="missing"

HAS_CSREQ=0; HAS_POLICY_ID=0; HAS_IND_TYPE=0; HAS_IND_ID=0; HAS_IND_CODE=0
HAS_FLAGS=0; HAS_LASTMOD=0; HAS_LAST_REMINDED=0; HAS_PID=0; HAS_PID_VERSION=0
HAS_BOOT_UUID=0; REQ_LASTMOD=0; REQ_LAST_REMINDED=0; REQ_PID=0; REQ_PID_VERSION=0
REQ_BOOT_UUID=0

GRANT_COUNT=0
GRANT_EXPECTED=0
GRANT_FAIL=0
AGENT_FDA_OK=0
MENU_CHANGED=0
PROFILE_PENDING=0

CLI_PATHS=()
APP_BUNDLES=()
APP_EXES=()
APP_PATHS=()
AE_TARGETS=()

# --- Privacy services --------------------------------------------------------
# Apple does not publish a complete list.  These are the services that matter
# for a JS/Python/Electron development machine; unknown service names are
# harmless (tccd simply has no row to match).
SERVICES=(
  kTCCServiceScreenCapture
  kTCCServiceMicrophone
  kTCCServiceCamera
  kTCCServiceSystemPolicyAllFiles
  kTCCServiceAccessibility
  kTCCServiceListenEvent
  kTCCServicePostEvent
  kTCCServiceAppleEvents
  kTCCServiceSystemPolicyAppBundles
  kTCCServiceSystemPolicyAppData
  kTCCServiceSystemPolicySysAdminFiles
  kTCCServiceSystemPolicyDesktopFolder
  kTCCServiceSystemPolicyDocumentsFolder
  kTCCServiceSystemPolicyDownloadsFolder
  kTCCServiceSystemPolicyRemovableVolumes
  kTCCServiceSystemPolicyNetworkVolumes
  kTCCServiceSystemPolicyDeveloperFiles
  kTCCServiceBluetoothAlways
  kTCCServiceBluetoothPeripheral
  kTCCServiceCalendar
  kTCCServiceContacts
  kTCCServiceReminders
  kTCCServicePhotos
  kTCCServicePhotosAdd
  kTCCServiceMediaLibrary
  kTCCServiceSpeechRecognition
  kTCCServiceUserTracking
  kTCCServiceFileProviderDomain
  kTCCServiceFileProviderPresence
  kTCCServiceUbiquity
  kTCCServiceCloudKit
  kTCCServiceExposeToSystem
  kTCCServiceKeyboardNetwork
  kTCCServiceAccessory
  kTCCServiceLocalNetwork
  kTCCServiceLocation
  kTCCServiceFocusStatus
  kTCCServiceShareKit
)

# --- Apps that commonly run dev agents / terminals / IDEs -------------------
APP_CANDIDATES=(
  "/System/Applications/Utilities/Terminal.app"
  "/Applications/iTerm.app"
  "/Applications/Visual Studio Code.app"
  "/Applications/Cursor.app"
  "/Applications/Windsurf.app"
  "/Applications/Warp.app"
  "/Applications/Claude.app"
  "/Applications/ChatGPT.app"
  "/Applications/OpenCode.app"
  "/Applications/Codex.app"
  "/Applications/Zed.app"
  "/Applications/Xcode.app"
  "/Applications/Sublime Text.app"
  "/Applications/Nova.app"
  "/Applications/BBEdit.app"
  "/Applications/TextMate.app"
  "/Applications/Hyper.app"
  "/Applications/kitty.app"
  "/Applications/Alacritty.app"
  "/Applications/WezTerm.app"
  "/Applications/Ghostty.app"
  "/Applications/Tabby.app"
  "/Applications/Android Studio.app"
  "/Applications/IntelliJ IDEA.app"
  "/Applications/IntelliJ IDEA CE.app"
  "/Applications/PyCharm.app"
  "/Applications/PyCharm CE.app"
  "/Applications/WebStorm.app"
  "/Applications/GoLand.app"
  "/Applications/DataGrip.app"
  "/Applications/Docker.app"
  "/Applications/OrbStack.app"
  "/Applications/UTM.app"
  "/Applications/VMware Fusion.app"
  "/Applications/Parallels Desktop.app"
  "/Applications/Postman.app"
  "/Applications/Insomnia.app"
  "/Applications/Safari.app"
  "/System/Applications/Mail.app"
  "/System/Applications/Messages.app"
  "/System/Applications/FaceTime.app"
  "/System/Applications/Photos.app"
  "/System/Applications/Preview.app"
  "/System/Applications/QuickTime Player.app"
  "/Applications/Google Chrome.app"
  "/Applications/Firefox.app"
  "/Applications/Microsoft Edge.app"
  "/Applications/Brave Browser.app"
  "/Applications/Arc.app"
  "/Applications/zoom.us.app"
  "/Applications/Microsoft Teams.app"
  "/Applications/Slack.app"
  "/Applications/Discord.app"
  "/Applications/Webex.app"
  "/Applications/OBS.app"
  "/Applications/ScreenFlow.app"
  "/Applications/Camtasia.app"
  "/Applications/Figma.app"
  "/Applications/Dropbox.app"
  "/Applications/Google Drive.app"
  "/Applications/OneDrive.app"
  "/Applications/Cyberduck.app"
  "/Applications/Transmit.app"
  "/Applications/VLC.app"
  "/Applications/HandBrake.app"
  "/Applications/Blender.app"
  "/Applications/GIMP.app"
)

# --- Dev executables found on PATH or in common version managers ------------
CLI_COMMANDS=(
  node nodejs npm npx yarn pnpm bun bunx deno
  python python3 uv uvx pip pip3 pipx poetry rye conda
  electron tsx ts-node playwright ffmpeg ffprobe
  osascript swift ruby php java dotnet
)
CLI_STATIC=(
  /usr/bin/python3
  /usr/bin/osascript
  /usr/bin/screencapture
)

# --- AppleEvents targets (automation) ---------------------------------------
AE_TARGET_IDS=(
  com.apple.systemevents
  com.apple.finder
  com.apple.Terminal
  com.apple.Safari
  com.apple.ScriptEditor2
  com.apple.mail
  com.apple.Preview
  com.apple.Photos
  com.apple.QuickTimePlayerX
  com.google.Chrome
  com.microsoft.edgemac
  org.mozilla.firefox
)

# =============================================================================
#  Output / small helpers
# =============================================================================
c_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
c_step() { printf '\033[1;36m[STEP]\033[0m %s\n' "$1"; }
c_ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"; }
c_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
c_err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$1" >&2; }
die()    { c_err "$1"; exit 1; }
hr()     { printf '%s\n' "-------------------------------------------------------------------"; }

dbg() {
  if [[ "$DEBUG" == "1" ]]; then printf '[DEBUG] %s\n' "$1" >&2; fi
  return 0
}

sql_q() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

resolve_path() {
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

dedup_lines() {
  awk 'NF && !seen[$0]++'
}

line_count() {
  if [[ -f "$1" ]]; then grep -c . "$1" 2>/dev/null || true; else echo 0; fi
}

now_epoch() { date +%s 2>/dev/null || echo 0; }

save_umask() { umask "$UMASK_SAVED"; }

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# =============================================================================
#  Bash 3.2-safe array helpers
# =============================================================================
array_add_unique() { # $1 = name of array; $2 = value
  local name="$1" val="$2" item qval
  # Bash 3.2 has no namerefs.  Quote the value for the eval so paths with
  # spaces/quotes cannot become shell code.
  printf -v qval '%q' "$val"
  eval "for item in \"\${${name}[@]+\${${name}[@]}}\"; do
          [[ \"\$item\" == $qval ]] && return 0
        done
        ${name}+=($qval)"
}

dedup_array() { # $1 = name of array; rebuilds it in place
  local name="$1" item
  local -a _out=()
  eval "for item in \"\${${name}[@]+\${${name}[@]}}\"; do _out+=(\"\$item\"); done"
  local _dedup=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && _dedup+=("$item")
  done < <(printf '%s\n' ${_out[@]+"${_out[@]}"} | dedup_lines)
  eval "${name}=(\"\${_dedup[@]+\${_dedup[@]}}\")"
}

# =============================================================================
#  macOS / SIP / environment
# =============================================================================
require_darwin() {
  if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" ]]; then
    die "This script only works on macOS."
  fi
}

require_user() {
  if [[ "$(id -u)" == "0" ]]; then
    die "Run this as your normal user: bash off.sh   (the script asks sudo itself)."
  fi
}

require_sqlite3() {
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found (it ships with macOS)."
}

macos_version() { sw_vers -productVersion 2>/dev/null || echo "0.0.0"; }

macos_init() {
  local v major minor patch
  v="$(macos_version)"
  IFS=. read -r major minor patch <<< "$v"
  MACOS_MAJOR=$((10#${major:-0}))
  MACOS_MINOR=$((10#${minor:-0}))
  MACOS_PATCH=$((10#${patch:-0}))
  if [[ "$(csrutil status 2>/dev/null || true)" == *"disabled"* ]]; then
    SIP_DISABLED=1
  elif [[ "$(csrutil status 2>/dev/null || true)" == *"enabled"* ]]; then
    SIP_ENABLED=1
  else
    SIP_UNKNOWN=1
  fi
  if sysctl -n machdep.cpu.features 2>/dev/null | grep -qi 'VMM'; then
    IS_VM=1
  elif system_profiler SPHardwareDataType 2>/dev/null | grep -qiE 'Virtual|VMware|Parallels|QEMU|UTM'; then
    IS_VM=1
  fi
  BOOT_UUID="$(sysctl -n kern.bootsessionuuid 2>/dev/null || true)"
  [[ -n "$BOOT_UUID" ]] || BOOT_UUID="00000000-0000-0000-0000-000000000000"
}

macos_at_least() { # $1 major, $2 minor
  local want_major="$1" want_minor="${2:-0}"
  if (( MACOS_MAJOR > want_major )); then return 0; fi
  if (( MACOS_MAJOR == want_major && MACOS_MINOR >= want_minor )); then return 0; fi
  return 1
}

terminal_name() {
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) echo "Terminal" ;;
    iTerm.app)      echo "iTerm2" ;;
    vscode)         echo "VS Code" ;;
    Cursor)         echo "Cursor" ;;
    WarpTerminal)   echo "Warp" ;;
    ghostty)        echo "Ghostty" ;;
    WezTerm)        echo "WezTerm" ;;
    *)              echo "${TERM_PROGRAM:-your terminal app}" ;;
  esac
}

terminal_bundle_id() {
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) echo "com.apple.Terminal" ;;
    iTerm.app)      echo "com.googlecode.iterm2" ;;
    vscode)         echo "com.microsoft.VSCode" ;;
    Cursor)         echo "com.todesktop.230313mzl4w4u92" ;;
    WarpTerminal)   echo "dev.warp.Warp-Stable" ;;
    ghostty)        echo "com.mitchellh.ghostty" ;;
    *)              echo "" ;;
  esac
}

# =============================================================================
#  sudo / prompts
# =============================================================================
need_sudo() {
  if ! sudo -v; then
    die "Admin password is required (sudo failed)."
  fi
}

confirm() {
  local answer=""
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "stdin is not a terminal. Run interactively, or pass --yes."
  fi
  if ! read -r -p "$1 " answer; then die "No input received."; fi
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

open_url() {
  [[ -n "$1" ]] || return 0
  /usr/bin/open "$1" >/dev/null 2>&1 || true
}

open_fda_settings() {
  open_url 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'
}

open_control_center_settings() {
  open_url 'x-apple.systempreferences:com.apple.ControlCenter-Settings.extension'
}

open_device_management() {
  open_url 'x-apple.systempreferences:com.apple.preferences.configurationprofiles'
}

# =============================================================================
#  SQLite plumbing
# =============================================================================
sql_sys() {
  sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" "$1"
}
sql_user() {
  if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
    sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" "$1"
  else
    sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" "$1"
  fi
}
sql_tag() {
  if [[ "$1" == "sys" ]]; then sql_sys "$2"; else sql_user "$2"; fi
}
sql_stdin_sys() {
  sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC"
}
sql_stdin_user() {
  if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
    sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC"
  else
    sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC"
  fi
}
sql_stdin_tag() {
  if [[ "$1" == "sys" ]]; then sql_stdin_sys; else sql_stdin_user; fi
}
db_file() {
  if [[ "$1" == "sys" ]]; then printf '%s' "$SYS_TCC"; else printf '%s' "$USER_TCC"; fi
}

run_sql_file() { # $1 = tag, $2 = SQL file
  local tag="$1" file="$2" err="$STATE_DIR/.sqlerr.$$.tmp"
  : > "$err"
  if [[ "$DEBUG" == "1" ]]; then
    echo "--- SQL for $tag db ---" >&2
    sed 's/^/    /' "$file" >&2
    echo "--- end SQL ---" >&2
  fi
  # .bail is essential: without it the sqlite3 shell keeps executing after a
  # failed statement and can COMMIT a partially applied transaction.
  if [[ "$tag" == "sys" ]]; then
    if { printf '.bail on\n'; cat "$file"; } \
         | sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" 2>"$err"; then
      rm -f "$err"; return 0
    fi
  else
    if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
      if { printf '.bail on\n'; cat "$file"; } \
           | sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" 2>"$err"; then
        rm -f "$err"; return 0
      fi
    else
      if { printf '.bail on\n'; cat "$file"; } \
           | sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" 2>"$err"; then
        rm -f "$err"; return 0
      fi
    fi
  fi
  c_err "SQL failed on the $tag TCC database:"
  sed 's/^/    /' "$err" >&2 || true
  rm -f "$err"
  return 1
}

sql_query_file() { # $1 = tag, $2 = SQL file; prints query output
  local tag="$1" file="$2"
  if [[ "$tag" == "sys" ]]; then
    sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" < "$file"
  else
    if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
      sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" < "$file"
    else
      sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" < "$file"
    fi
  fi
}

detect_schema() { # $1 = tag; sets HAS_* / REQ_* for the current db
  local tag="$1" info="" name="" notnull="" dflt="" type="" pk="" unknown_bad="" cid=""
  if ! info="$(sql_tag "$tag" "PRAGMA table_info(access);")"; then return 1; fi
  if [[ -z "$info" ]]; then return 1; fi
  HAS_CSREQ=0; HAS_POLICY_ID=0; HAS_IND_TYPE=0; HAS_IND_ID=0; HAS_IND_CODE=0
  HAS_FLAGS=0; HAS_LASTMOD=0; HAS_LAST_REMINDED=0; HAS_PID=0; HAS_PID_VERSION=0
  HAS_BOOT_UUID=0; REQ_LASTMOD=0; REQ_LAST_REMINDED=0; REQ_PID=0
  REQ_PID_VERSION=0; REQ_BOOT_UUID=0
  while IFS='|' read -r cid name type notnull dflt pk; do
    [[ -n "$name" ]] || continue
    case "$name" in
      service|client|client_type|auth_value|auth_reason|auth_version) ;;
      csreq)                            HAS_CSREQ=1 ;;
      policy_id)                        HAS_POLICY_ID=1 ;;
      indirect_object_identifier_type)  HAS_IND_TYPE=1 ;;
      indirect_object_identifier)       HAS_IND_ID=1 ;;
      indirect_object_code_identity)    HAS_IND_CODE=1 ;;
      flags)                            HAS_FLAGS=1 ;;
      last_modified)                    HAS_LASTMOD=1; [[ "$notnull" == "1" && -z "$dflt" ]] && REQ_LASTMOD=1 ;;
      last_reminded)                    HAS_LAST_REMINDED=1; [[ "$notnull" == "1" && -z "$dflt" ]] && REQ_LAST_REMINDED=1 ;;
      pid)                              HAS_PID=1; [[ "$notnull" == "1" && -z "$dflt" ]] && REQ_PID=1 ;;
      pid_version)                      HAS_PID_VERSION=1; [[ "$notnull" == "1" && -z "$dflt" ]] && REQ_PID_VERSION=1 ;;
      boot_uuid)                        HAS_BOOT_UUID=1; [[ "$notnull" == "1" && -z "$dflt" ]] && REQ_BOOT_UUID=1 ;;
      *)
        if [[ "$notnull" == "1" && -z "$dflt" ]]; then
          unknown_bad="$unknown_bad $name"
        fi
        ;;
    esac
  done <<< "$info"
  if [[ -n "$unknown_bad" ]]; then
    c_warn "The access table in the $tag database has unknown required columns:$unknown_bad"
    c_warn "Refusing to write that database rather than corrupting it."
    return 1
  fi
  return 0
}

csreq_literal() {
  if [[ -n "$1" ]]; then printf "x'%s'" "$1"; else printf 'NULL'; fi
}

insert_row_sql() {
  # $1=service $2=client $3=client_type $4=csreq_hex $5=auth_value
  # $6=auth_reason $7=auth_version $8=flags $9=indirect_id $10=indirect_code_hex
  local svc="$1" client="$2" ctype="$3" csh="$4" authv="$5"
  local reason="${6:-4}" ver="${7:-1}" flagsv="${8:-0}"
  local indid="${9:-UNUSED}" indcode="${10:-}"
  local cols="service, client, client_type, auth_value, auth_reason, auth_version"
  local vals
  vals="$(sql_q "$svc"), $(sql_q "$client"), $ctype, $authv, $reason, $ver"
  if [[ "$HAS_CSREQ" == "1" ]]; then
    cols="$cols, csreq"; vals="$vals, $(csreq_literal "$csh")"
  fi
  if [[ "$HAS_POLICY_ID" == "1" ]]; then
    cols="$cols, policy_id"; vals="$vals, NULL"
  fi
  if [[ "$HAS_IND_TYPE" == "1" ]]; then
    cols="$cols, indirect_object_identifier_type"; vals="$vals, 0"
  fi
  if [[ "$HAS_IND_ID" == "1" ]]; then
    cols="$cols, indirect_object_identifier"; vals="$vals, $(sql_q "$indid")"
  fi
  if [[ "$HAS_IND_CODE" == "1" ]]; then
    cols="$cols, indirect_object_code_identity"; vals="$vals, $(csreq_literal "$indcode")"
  fi
  if [[ "$HAS_FLAGS" == "1" ]]; then
    if [[ -z "$flagsv" ]]; then cols="$cols, flags"; vals="$vals, NULL"
    else cols="$cols, flags"; vals="$vals, $flagsv"; fi
  fi
  if [[ "$HAS_PID" == "1" && "$REQ_PID" == "1" ]]; then
    cols="$cols, pid"; vals="$vals, 0"
  fi
  if [[ "$HAS_PID_VERSION" == "1" && "$REQ_PID_VERSION" == "1" ]]; then
    cols="$cols, pid_version"; vals="$vals, 0"
  fi
  if [[ "$HAS_BOOT_UUID" == "1" && "$REQ_BOOT_UUID" == "1" ]]; then
    cols="$cols, boot_uuid"; vals="$vals, $(sql_q "$BOOT_UUID")"
  fi
  if [[ "$HAS_LAST_REMINDED" == "1" && "$REQ_LAST_REMINDED" == "1" ]]; then
    cols="$cols, last_reminded"; vals="$vals, $(now_epoch)"
  fi
  if [[ "$HAS_LASTMOD" == "1" ]]; then
    cols="$cols, last_modified"; vals="$vals, $(now_epoch)"
  fi
  printf 'INSERT OR REPLACE INTO access (%s) VALUES (%s);%s' "$cols" "$vals" "$NL"
}

in_values_list() { # stdin: service<TAB>client<TAB>ctype<TAB>indirect_id
  local first=1 svc client ctype ind
  while IFS=$'\t' read -r svc client ctype ind; do
    [[ -n "$svc" ]] || continue
    if [[ "$first" == "1" ]]; then first=0; else printf ', '; fi
    if [[ "$HAS_IND_ID" == "1" ]]; then
      [[ -n "$ind" ]] || ind="UNUSED"
      printf '(%s, %s, %s, %s)' "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$(sql_q "$ind")"
    else
      printf '(%s, %s, %s)' "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype"
    fi
  done
  return 0
}

in_values_list_noind() { # stdin: service<TAB>client<TAB>ctype
  local first=1 svc client ctype
  while IFS=$'\t' read -r svc client ctype; do
    [[ -n "$svc" ]] || continue
    if [[ "$first" == "1" ]]; then first=0; else printf ', '; fi
    printf '(%s, %s, %s)' "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype"
  done
  return 0
}

# =============================================================================
#  DB availability probes (real writes, not read-only lies)
# =============================================================================
write_probe_tag() { # $1 = sys|user
  local tag="$1" i
  for i in 1 2 3; do
    # A BEGIN IMMEDIATE/ROLLBACK pair alone does not prove that the main
    # database is writable.  Create and drop a real table inside the
    # transaction: on a SIP-protected/read-only file this fails; the rollback
    # guarantees that the probe leaves no trace.
    if printf '.bail on\nPRAGMA busy_timeout=%s;\nBEGIN IMMEDIATE;\nCREATE TABLE __off_write_probe (x INTEGER);\nDROP TABLE __off_write_probe;\nROLLBACK;\n' "$SQLITE_TIMEOUT_MS" \
         | sql_stdin_tag "$tag" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

probe_sys_db() {
  SYS_DB_PRESENT=0; SYS_DB_READABLE=0; SYS_DB_WRITABLE=0; SYS_DB_STATE="missing"
  if [[ ! -f "$SYS_TCC" ]]; then return 1; fi
  SYS_DB_PRESENT=1
  if sudo -n sqlite3 -batch -readonly "$SYS_TCC" "PRAGMA quick_check;" >/dev/null 2>&1; then
    SYS_DB_READABLE=1
  fi
  if [[ "$SYS_DB_READABLE" == "1" ]]; then
    if write_probe_tag sys; then
      SYS_DB_WRITABLE=1; SYS_DB_STATE="writable"
    else
      SYS_DB_STATE="readonly"
    fi
  else
    SYS_DB_STATE="blocked"
  fi
  [[ "$SYS_DB_WRITABLE" == "1" ]]
}

probe_user_db() {
  USER_DB_PRESENT=0; USER_DB_WRITABLE=0; USER_DB_VIA_SUDO=0; USER_DB_STATE="missing"
  if [[ ! -f "$USER_TCC" ]]; then return 1; fi
  USER_DB_PRESENT=1
  # Try as the user first.
  if write_probe_tag user; then
    USER_DB_WRITABLE=1; USER_DB_STATE="writable"; return 0
  fi
  # Root can still work if the user's TCC database is not TCC-protected from
  # this process, or on a SIP-off development VM.
  if sudo -n true >/dev/null 2>&1; then
    USER_DB_VIA_SUDO=1
    if write_probe_tag user; then
      USER_DB_WRITABLE=1; USER_DB_STATE="writable-via-root"; return 0
    fi
    USER_DB_VIA_SUDO=0
  fi
  USER_DB_STATE="blocked"
  return 1
}

fda_hint() { # $1 = context
  local term; term="$(terminal_name)"
  c_warn "$1"
  echo "    Full Disk Access is needed for the app that runs this script: $term"
  echo "    System Settings -> Privacy & Security -> Full Disk Access -> enable $term"
  echo "    The settings panel will be opened for you."
  open_fda_settings
}

sip_hint() {
  echo "    macOS SIP is enabled.  SIP protects the SYSTEM TCC database"
  echo "    (/Library/Application Support/com.apple.TCC/TCC.db) from writes,"
  echo "    even for root.  Full Disk Access does NOT override SIP."
  echo "    Consequences: screen recording, microphone, camera, accessibility, input"
  echo "    monitoring and full-disk-access rows cannot be written automatically"
  echo "    on this Mac.  Options: (a) approve those once in System Settings,"
  echo "    (b) disable SIP in Recovery on a disposable development VM, or"
  echo "    (c) use an MDM PPPC profile.  Per-user rows (automation, contacts,"
  echo "    calendar, photos and some file/folder services) can still be written"
  echo "    with Full Disk Access."
}

# =============================================================================
#  Client discovery
# =============================================================================
add_cli_path() { # $1 = path
  local p="$1" rp
  [[ -n "$p" && -e "$p" ]] || return 0
  # -f follows symlinks, so a symlink to a regular binary is accepted while a
  # directory (or a broken symlink) is not.
  [[ -f "$p" ]] || return 0
  # TCC client_type=1 requires an absolute path.  Resolve relative inputs
  # first so a ps/EXTRA_PATHS entry can never create a relative client_type=1
  # row (which tccd would not match).
  if [[ "$p" != /* ]]; then p="$PWD/$p"; fi
  array_add_unique CLI_PATHS "$p"
  rp="$(resolve_path "$p")"
  if [[ -n "$rp" && "$rp" == /* && "$rp" != "$p" && -e "$rp" ]]; then
    array_add_unique CLI_PATHS "$rp"
  fi
  return 0
}

collect_cli_paths() {
  CLI_PATHS=()
  local c p g
  for c in ${CLI_COMMANDS[@]+"${CLI_COMMANDS[@]}"}; do
    p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" ]] && add_cli_path "$p"
  done
  for p in ${CLI_STATIC[@]+"${CLI_STATIC[@]}"}; do
    [[ -e "$p" ]] && add_cli_path "$p"
  done

  shopt -s nullglob
  for g in \
    /opt/homebrew/bin/node /opt/homebrew/bin/nodejs \
    /opt/homebrew/bin/python3 /opt/homebrew/bin/python \
    /opt/homebrew/opt/python@3*/bin/python3* \
    /usr/local/bin/node /usr/local/bin/nodejs \
    /usr/local/bin/python3 /usr/local/bin/python \
    /usr/local/opt/python@3*/bin/python3* \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.volta/bin/node \
    "$HOME"/.fnm/node-versions/*/installation/bin/node \
    "$HOME"/.asdf/installs/nodejs/*/bin/node \
    "$HOME"/.asdf/installs/python/*/bin/python3* \
    "$HOME"/.local/share/mise/installs/node/*/bin/node \
    "$HOME"/.local/share/mise/installs/python/*/bin/python3* \
    "$HOME"/.pyenv/versions/*/bin/python3* \
    "$HOME"/.local/share/uv/python/*/bin/python3* \
    "$HOME"/.local/share/uv/tools/*/bin/* \
    "$HOME"/.deno/bin/deno \
    "$HOME"/.bun/bin/bun \
    "$HOME"/miniconda3/bin/python* \
    "$HOME"/anaconda3/bin/python* \
    "$HOME"/miniforge3/bin/python* \
    "$HOME"/.venv/bin/python* \
    "$HOME"/venv/bin/python*
  do
    [[ -e "$g" ]] && add_cli_path "$g"
  done
  shopt -u nullglob

  # Running dev processes are the most reliable source when node/python was
  # started from a project-local venv or a non-standard runtime manager.
  if command -v ps >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      # If a running Electron/Chromium/Playwright helper is inside an .app,
      # grant the app bundle too (TCC keys apps by bundle id, not by the
      # helper executable path).
      case "$p" in
        *"/Contents/MacOS/"*)
          local _app="${p%%/Contents/MacOS/*}"
          if [[ -d "$_app" ]]; then add_app_bundle "$_app"; fi
          ;;
      esac
      add_cli_path "$p"
    done < <(
      ps -axo comm= 2>/dev/null | awk '
        {
          n=$0; sub(/.*\//,"",n);
          if (n ~ /^(node|nodejs|python|python3(\.[0-9]+)?|uv|uvx|deno|bun|electron|ffmpeg|ffprobe|osascript|Chromium|Google Chrome for Testing|headless_shell|chrome)$/) print $0
        }'
    )
  fi

  # Also catch a running, unpackaged Electron/CEF app from a project directory
  # (its executable is named after the app, so the name filter above cannot see
  # it).  Only add real Electron/CEF bundles, not every running app.
  if command -v ps >/dev/null 2>&1; then
    local _app2
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      case "$p" in
        *"/Contents/MacOS/"*)
          _app2="${p%%/Contents/MacOS/*}"
          if [[ -d "$_app2" ]] && is_electron_bundle "$_app2"; then
            add_app_bundle "$_app2"
          fi
          ;;
      esac
    done < <(ps -axo comm= 2>/dev/null)
  fi

  if [[ -f "$EXTRA_PATHS_FILE" ]]; then
    while IFS= read -r p; do
      p="${p%$'\r'}"
      [[ -z "$p" || "$p" == \#* ]] && continue
      [[ -e "$p" ]] && add_cli_path "$p"
    done < "$EXTRA_PATHS_FILE"
  fi
  dedup_array CLI_PATHS
}

add_app_bundle() { # $1 = .app path
  local app="$1" id exe path
  [[ -d "$app" && -f "$app/Contents/Info.plist" ]] || return 0
  id="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "$id" ]] || return 0
  exe="$("$PLIST_BUDDY" -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "$exe" ]] || exe="$(basename "$app" .app)"
  path="$app/Contents/MacOS/$exe"
  array_add_unique APP_BUNDLES "$id"
  array_add_unique APP_PATHS "$app"
  [[ -x "$path" ]] && array_add_unique APP_EXES "$path"
  return 0
}

is_electron_bundle() {
  local app="$1"
  [[ -d "$app/Contents/Frameworks/Electron Framework.framework" ||
     -d "$app/Contents/Frameworks/Chromium Embedded Framework.framework" ]]
}

collect_apps() {
  # Do not clear these arrays here: collect_cli_paths may already have added
  # app bundles discovered from running Electron/Chromium/Playwright processes.
  # collect_apps merges candidate/nested/extra apps into that set.
  local app nested
  for app in ${APP_CANDIDATES[@]+"${APP_CANDIDATES[@]}"}; do
    [[ -d "$app" ]] && add_app_bundle "$app"
  done
  if [[ -f "$EXTRA_APPS_FILE" ]]; then
    while IFS= read -r app; do
      app="${app%$'\r'}"
      [[ -z "$app" || "$app" == \#* ]] && continue
      [[ -d "$app" ]] && add_app_bundle "$app"
    done < "$EXTRA_APPS_FILE"
  fi
  # Browser automation (Playwright/Puppeteer) ships its own Chromium builds
  # outside /Applications.  Grant those app bundles when present.
  shopt -s nullglob
  for app in \
    "$HOME"/Library/Caches/ms-playwright/*/chrome-mac*/*.app \
    "$HOME"/.cache/ms-playwright/*/chrome-mac*/*.app \
    "$HOME"/.cache/puppeteer/*/*/*/*.app \
    "$HOME"/.cache/puppeteer/*/*/*/*/*.app
  do
    [[ -d "$app" ]] && add_app_bundle "$app"
  done
  # Custom Electron/CEF apps (for example the user's own interview app) are
  # not in the fixed candidate list.  Detect them by framework, never by name,
  # so a project-specific app gets the same grants as the known dev apps.
  local installed
  for installed in /Applications/*.app "$HOME"/Applications/*.app; do
    [[ -d "$installed" ]] || continue
    if is_electron_bundle "$installed"; then
      add_app_bundle "$installed"
    fi
  done
  shopt -u nullglob

  # Electron/IDE helper bundles: camera/mic/screen permission is often
  # attributed to a helper, not to the outer .app.
  local app_count="${#APP_PATHS[@]}"
  local i=0
  while [[ "$i" -lt "$app_count" ]]; do
    app="${APP_PATHS[$i]}"
    while IFS= read -r nested; do
      [[ -n "$nested" ]] && add_app_bundle "$nested"
    done < <(find "$app/Contents" -maxdepth 5 -name '*.app' -type d 2>/dev/null | head -40)
    i=$((i + 1))
    app_count="${#APP_PATHS[@]}"
  done

  dedup_array APP_BUNDLES
  dedup_array APP_EXES
  dedup_array APP_PATHS
}

collect_ae_targets() {
  AE_TARGETS=()
  local id
  for id in ${AE_TARGET_IDS[@]+"${AE_TARGET_IDS[@]}"}; do
    array_add_unique AE_TARGETS "$id"
  done
  if [[ -f "$EXTRA_AE_FILE" ]]; then
    while IFS= read -r id; do
      id="${id%$'\r'}"
      [[ -z "$id" || "$id" == \#* ]] && continue
      array_add_unique AE_TARGETS "$id"
    done < "$EXTRA_AE_FILE"
  fi
}

bundle_path_for() { # $1 = bundle id -> app path or empty
  local id="$1" app="" candidate cid
  case "$id" in
    com.apple.systemevents) app="/System/Library/CoreServices/System Events.app" ;;
    com.apple.finder)       app="/System/Library/CoreServices/Finder.app" ;;
    com.apple.Terminal)
      if [[ -d /System/Applications/Utilities/Terminal.app ]]; then
        app="/System/Applications/Utilities/Terminal.app"
      else
        app="/Applications/Utilities/Terminal.app"
      fi
      ;;
    com.apple.Safari)       app="/Applications/Safari.app" ;;
    com.apple.mail)         app="/System/Applications/Mail.app" ;;
    com.apple.Preview)      app="/System/Applications/Preview.app" ;;
    com.apple.Photos)       app="/System/Applications/Photos.app" ;;
    com.apple.QuickTimePlayerX) app="/System/Applications/QuickTime Player.app" ;;
    com.apple.ScriptEditor2)
      if [[ -d "/System/Applications/Utilities/Script Editor.app" ]]; then
        app="/System/Applications/Utilities/Script Editor.app"
      else
        app="/Applications/Utilities/Script Editor.app"
      fi
      ;;
    com.google.Chrome)      app="/Applications/Google Chrome.app" ;;
    com.microsoft.edgemac)  app="/Applications/Microsoft Edge.app" ;;
    org.mozilla.firefox)    app="/Applications/Firefox.app" ;;
  esac
  if [[ -n "$app" && -d "$app" ]]; then
    printf '%s' "$app"; return 0
  fi
  # We already collected the real app paths; use those before Spotlight.
  for candidate in ${APP_PATHS[@]+"${APP_PATHS[@]}"}; do
    [[ -d "$candidate" ]] || continue
    cid="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$cid" == "$id" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  # A small mdfind fallback, but never let Spotlight hang the script.
  if command -v mdfind >/dev/null 2>&1; then
    app="$(mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null | head -1 || true)"
    if [[ -n "$app" && -d "$app" ]]; then printf '%s' "$app"; return 0; fi
  fi
  return 1
}

app_path_for() { # $1 = bundle id or absolute path
  local k="$1"
  if [[ -d "$k" ]]; then printf '%s' "$k"; return 0; fi
  if [[ -x "$k" || -f "$k" ]]; then printf '%s' "$k"; return 0; fi
  bundle_path_for "$k"
}

client_type_for() {
  # TCC uses client_type 0 for bundle identifiers and 1 for absolute paths.
  case "$1" in
    /*) printf '1' ;;
    *)  printf '0' ;;
  esac
}

# =============================================================================
#  Code-signing requirement (csreq)
# =============================================================================
csreq_hex_for_path() { # $1 = app bundle or binary; prints hex or nothing
  local p="$1" req tmp hex
  [[ -n "$CSREQ_BIN" && -e "$p" ]] || return 1
  req="$("$CODEDESIGN_BIN" -d -r- "$p" 2>&1 | sed -n 's/^designated => //p' | head -1 || true)"
  [[ -n "$req" ]] || return 1
  tmp="$STATE_DIR/.csreq.$$.tmp"
  if "$CSREQ_BIN" -r="$req" -b "$tmp" >/dev/null 2>&1; then
    hex="$(/usr/bin/od -An -v -tx1 "$tmp" 2>/dev/null | tr -d ' \n' || true)"
    rm -f "$tmp"
    if [[ -n "$hex" ]]; then printf '%s' "$hex"; return 0; fi
  fi
  rm -f "$tmp"
  return 1
}

# =============================================================================
#  Snapshot / manifests
# =============================================================================
normalize_legacy_manifests() {
  mkdir -p "$STATE_DIR"
  if [[ -f "$F_ADDED" ]]; then
    awk -F'\t' 'BEGIN{OFS="\t"}
      NF==4 { print $1,$2,$3,$4,"UNUSED"; next }
      NF>=5 { if ($5=="") $5="UNUSED"; print; next }' \
      "$F_ADDED" > "$F_ADDED.norm" && mv "$F_ADDED.norm" "$F_ADDED"
  fi
  if [[ -f "$F_PRESERVE" ]]; then
    awk -F'\t' 'BEGIN{OFS="\t"}
      NF==9 {
        print $1,$2,$3,$4,"UNUSED",$5,$6,$7,($8==""?"-":$8),($9==""?"-":$9),"-"; next
      }
      NF>=5 {
        while (NF < 11) $(NF+1)="-";
        for (i=9; i<=11; i++) if ($i=="") $i="-";
        print; next
      }' \
      "$F_PRESERVE" > "$F_PRESERVE.norm" && mv "$F_PRESERVE.norm" "$F_PRESERVE"
  fi
  if [[ -f "$F_TARGETS" ]]; then
    awk -F'\t' 'BEGIN{OFS="\t"}
      NF==4 { print $1,$2,$3,$4,"UNUSED"; next }
      NF>=5 { if ($5=="") $5="UNUSED"; print; next }' \
      "$F_TARGETS" > "$F_TARGETS.norm" && mv "$F_TARGETS.norm" "$F_TARGETS"
  fi
}

# =============================================================================
#  Grant engine
# =============================================================================
grant_targets() { # $1 = tag, $2 = file of CLI paths, $3 = file of bundle ids
  local tag="$1" pfile="$2" bfile="$3" db
  db="$(db_file "$tag")"
  GRANT_COUNT=0; GRANT_EXPECTED=0

  if [[ ! -f "$db" ]]; then
    c_warn "The $tag TCC database does not exist; skipping."
    return 1
  fi
  if ! detect_schema "$tag"; then return 1; fi

  local tgt="$STATE_DIR/.targets.$$.tsv"
  : > "$tgt"
  local svc client target
  for svc in ${SERVICES[@]+"${SERVICES[@]}"}; do
    if [[ "$tag" == "sys" && "$svc" == "kTCCServiceAppleEvents" ]]; then
      continue
    fi
    if [[ "$svc" == "kTCCServiceAppleEvents" && "$HAS_IND_ID" != "1" ]]; then
      # AppleEvents is keyed by its indirect object; without that column
      # separate automation targets cannot be represented safely.
      continue
    fi
    if [[ "$svc" == "kTCCServiceAppleEvents" ]]; then
      while IFS= read -r client; do
        [[ -n "$client" ]] || continue
        for target in ${AE_TARGETS[@]+"${AE_TARGETS[@]}"}; do
          printf '%s\t%s\t%s\t%s\n' "$svc" "$client" "$(client_type_for "$client")" "$target" >> "$tgt"
        done
      done < <(cat "$pfile" "$bfile" 2>/dev/null || true)
    else
      while IFS= read -r client; do
        [[ -n "$client" ]] && printf '%s\t%s\t1\tUNUSED\n' "$svc" "$client" >> "$tgt"
      done < "$pfile"
      while IFS= read -r client; do
        [[ -n "$client" ]] && printf '%s\t%s\t0\tUNUSED\n' "$svc" "$client" >> "$tgt"
      done < "$bfile"
    fi
  done
  LC_ALL=C sort -u "$tgt" > "$tgt.u" && mv "$tgt.u" "$tgt"
  local expected; expected="$(grep -c . "$tgt" 2>/dev/null || true)"
  GRANT_EXPECTED="${expected:-0}"
  if [[ "$GRANT_EXPECTED" -eq 0 ]]; then
    rm -f "$tgt"
    c_warn "No clients to grant in the $tag database."
    return 1
  fi

  # Existing code signatures (fallback when codesign/csreq cannot run).
  local exist_csreq="$STATE_DIR/.exist-csreq.$$.tsv"
  local exist_ae="$STATE_DIR/.exist-ae.$$.tsv"
  : > "$exist_csreq"; : > "$exist_ae"
  if [[ "$HAS_CSREQ" == "1" ]]; then
    sql_tag "$tag" \
      "SELECT client || '|' || COALESCE(hex(csreq),'') FROM access WHERE csreq IS NOT NULL AND length(csreq) > 0 GROUP BY client;" \
      2>/dev/null | while IFS='|' read -r client hex; do
        [[ -n "$client" && -n "$hex" ]] && printf '%s\t%s\n' "$client" "$hex" >> "$exist_csreq"
      done || true
  fi
  if [[ "$HAS_IND_CODE" == "1" ]]; then
    sql_tag "$tag" \
      "SELECT indirect_object_identifier || '|' || COALESCE(hex(indirect_object_code_identity),'') FROM access WHERE indirect_object_code_identity IS NOT NULL AND length(indirect_object_code_identity) > 0 GROUP BY indirect_object_identifier;" \
      2>/dev/null | while IFS='|' read -r client hex; do
        [[ -n "$client" && -n "$hex" ]] && printf '%s\t%s\n' "$client" "$hex" >> "$exist_ae"
      done || true
  fi

  # Code-signing requires are expensive (codesign + csreq per object).  The
  # same client/target is repeated for every service, so resolve each unique
  # object exactly once.
  local keyfile="$STATE_DIR/.reqkeys.$$.tsv"
  local client_reqs="$STATE_DIR/.clientreqs.$$.tsv"
  local target_reqs="$STATE_DIR/.targetreqs.$$.tsv"
  : > "$client_reqs"; : > "$target_reqs"
  awk -F'\t' '{print $2}' "$tgt" | LC_ALL=C sort -u > "$keyfile"
  local key path req_hex
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    path="$(app_path_for "$key" 2>/dev/null || true)"
    req_hex=""
    if [[ -n "$path" ]]; then
      req_hex="$(csreq_hex_for_path "$path" 2>/dev/null || true)"
    fi
    if [[ -z "$req_hex" ]]; then
      req_hex="$(grep -F -m1 -e "$key"$'\t' "$exist_csreq" 2>/dev/null | cut -f2 || true)"
    fi
    printf '%s\t%s\n' "$key" "$req_hex" >> "$client_reqs"
  done < "$keyfile"
  awk -F'\t' '$4!="UNUSED"{print $4}' "$tgt" | LC_ALL=C sort -u > "$keyfile"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    path="$(app_path_for "$key" 2>/dev/null || true)"
    req_hex=""
    if [[ -n "$path" ]]; then
      req_hex="$(csreq_hex_for_path "$path" 2>/dev/null || true)"
    fi
    if [[ -z "$req_hex" ]]; then
      req_hex="$(grep -F -m1 -e "$key"$'\t' "$exist_ae" 2>/dev/null | cut -f2 || true)"
    fi
    printf '%s\t%s\n' "$key" "$req_hex" >> "$target_reqs"
  done < "$keyfile"

  # Old rows we already own should not be treated as "pre-existing".
  local old_added_keys="$STATE_DIR/.old-added.$$.tsv"
  : > "$old_added_keys"
  if [[ -f "$F_ADDED" ]]; then
    awk -F'\t' -v t="$tag" '$1==t{print $2"\t"$3"\t"$4"\t"($5?$5:"UNUSED")}' "$F_ADDED" >> "$old_added_keys"
  fi
  LC_ALL=C sort -u "$old_added_keys" > "$old_added_keys.u" && mv "$old_added_keys.u" "$old_added_keys"

  # Snapshot every existing row we are about to overwrite.  Non-AppleEvents
  # rows are matched by (service, client, client_type) on purpose: macOS may
  # store their indirect id as NULL, '' or 'UNUSED', and matching only
  # 'UNUSED' leaves a stale denied row behind that tccd can still use.
  local tmp_pres="$STATE_DIR/.preserve.$$.tsv"
  : > "$tmp_pres"
  local tgt_no="$STATE_DIR/.targets-noind.$$.tsv"
  local tgt_ae="$STATE_DIR/.targets-ae.$$.tsv"
  awk -F'\t' '$4=="UNUSED"' "$tgt" > "$tgt_no"
  awk -F'\t' '$4!="UNUSED"' "$tgt" > "$tgt_ae"

  local out_no="" out_ae="" sel line
  if [[ -s "$tgt_no" ]]; then
    local in_no
    in_no="$(awk -F'\t' '{print $1"\t"$2"\t"$3}' "$tgt_no" | LC_ALL=C sort -u | in_values_list_noind)"
    if [[ -n "$in_no" ]]; then
      if [[ "$HAS_IND_ID" == "1" ]]; then
        sel="SELECT service || '|' || client || '|' || client_type || '|' || COALESCE(indirect_object_identifier,'UNUSED') || '|' || auth_value || '|' || auth_reason || '|' || auth_version || '|' || COALESCE(hex(csreq),'') || '|' || COALESCE(flags,'') || '|' || COALESCE(hex(indirect_object_code_identity),'') FROM access WHERE (service, client, client_type) IN ($in_no);"
      else
        sel="SELECT service || '|' || client || '|' || client_type || '|' || 'UNUSED' || '|' || auth_value || '|' || auth_reason || '|' || auth_version || '|' || COALESCE(hex(csreq),'') || '|' || COALESCE(flags,'') || '|' || '' FROM access WHERE (service, client, client_type) IN ($in_no);"
      fi
      local qfile="$STATE_DIR/.snapshot.$$.sql"
      printf '%s\n' "$sel" > "$qfile"
      if ! out_no="$(sql_query_file "$tag" "$qfile" 2>/dev/null)"; then
        rm -f "$qfile" "$tmp_pres" "$tgt_no" "$tgt_ae"
        c_warn "Could not read existing $tag TCC rows; refusing to change permissions without a snapshot."
        return 1
      fi
      rm -f "$qfile"
    fi
  fi
  if [[ -s "$tgt_ae" && "$HAS_IND_ID" == "1" ]]; then
    local in_ae
    in_ae="$(in_values_list < "$tgt_ae")"
    if [[ -n "$in_ae" ]]; then
      sel="SELECT service || '|' || client || '|' || client_type || '|' || COALESCE(indirect_object_identifier,'UNUSED') || '|' || auth_value || '|' || auth_reason || '|' || auth_version || '|' || COALESCE(hex(csreq),'') || '|' || COALESCE(flags,'') || '|' || COALESCE(hex(indirect_object_code_identity),'') FROM access WHERE (service, client, client_type, indirect_object_identifier) IN ($in_ae);"
      local qfile_ae="$STATE_DIR/.snapshot-ae.$$.sql"
      printf '%s\n' "$sel" > "$qfile_ae"
      if ! out_ae="$(sql_query_file "$tag" "$qfile_ae" 2>/dev/null)"; then
        rm -f "$qfile_ae" "$tmp_pres" "$tgt_no" "$tgt_ae"
        c_warn "Could not read existing $tag TCC rows; refusing to change permissions without a snapshot."
        return 1
      fi
      rm -f "$qfile_ae"
    fi
  fi
  local out; out="$(printf '%s\n%s\n' "$out_no" "$out_ae" | dedup_lines)"
  if [[ -n "$out" ]]; then
    local svc2 client2 ctype2 ind2 authv reason ver csh flagsv indcode
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS='|' read -r svc2 client2 ctype2 ind2 authv reason ver csh flagsv indcode <<< "$line"
      [[ -n "$svc2" ]] || continue
      # Skip rows that we added in a previous run.
      if awk -F'\t' -v k="$svc2"$'\t'"$client2"$'\t'"$ctype2"$'\t'"${ind2:-UNUSED}" '$0==k{found=1;exit} END{exit !found}' "$old_added_keys"; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$tag" "$svc2" "$client2" "$ctype2" "${ind2:-UNUSED}" \
        "${authv:-0}" "${reason:-0}" "${ver:-1}" "${csh:--}" "${flagsv:--}" "${indcode:--}" >> "$tmp_pres"
    done <<< "$out"
  fi
  rm -f "$tgt_no" "$tgt_ae"

  # Keep the true original snapshot for keys we have seen before.  Merge
  # through a separate file: appending awk output back into the file awk is
  # reading is not safe on all awk implementations.
  if [[ ! -f "$F_PRESERVE" ]]; then : > "$F_PRESERVE"; fi
  local merged_pres="$STATE_DIR/.preserve-merged.$$.tsv"
  if [[ -s "$F_PRESERVE" ]]; then
    awk -F'\t' 'FILENAME==ARGV[1]{print; k[$1"\t"$2"\t"$3"\t"$4"\t"$5]=1; next} !(($1"\t"$2"\t"$3"\t"$4"\t"$5) in k)' \
      "$F_PRESERVE" "$tmp_pres" > "$merged_pres"
  else
    cp "$tmp_pres" "$merged_pres"
  fi
  if [[ -s "$merged_pres" ]]; then
    # Keep exactly one original row per TCC key, then sort for stable diffs.
    awk -F'\t' '!seen[$1 FS $2 FS $3 FS $4 FS $5]++' "$merged_pres" > "$merged_pres.one" \
      && LC_ALL=C sort -u "$merged_pres.one" > "$F_PRESERVE" \
      && rm -f "$merged_pres.one"
  else
    : > "$F_PRESERVE"
  fi
  rm -f "$merged_pres"

  # Added = every target key that is not a preserved pre-existing row.  Rows
  # from an earlier off.sh run stay in F_ADDED so --back can remove them.
  local tmp_added="$STATE_DIR/.added.$$.tsv"
  : > "$tmp_added"
  while IFS=$'\t' read -r svc client ctype ind; do
    [[ -n "$svc" ]] || continue
    local key="$tag"$'\t'"$svc"$'\t'"$client"$'\t'"$ctype"$'\t'"${ind:-UNUSED}"
    if grep -F -q -e "$key"$'\t' "$F_PRESERVE" 2>/dev/null; then continue; fi
    if grep -F -x -q -e "$svc"$'\t'"$client"$'\t'"$ctype"$'\t'"${ind:-UNUSED}" "$old_added_keys" 2>/dev/null; then
      printf '%s\n' "$key" >> "$tmp_added"
      continue
    fi
    printf '%s\n' "$key" >> "$tmp_added"
  done < "$tgt"
  if [[ -f "$F_ADDED" ]]; then
    cat "$F_ADDED" "$tmp_added" | LC_ALL=C sort -u > "$F_ADDED.tmp" && mv "$F_ADDED.tmp" "$F_ADDED"
  else
    LC_ALL=C sort -u "$tmp_added" > "$F_ADDED"
  fi

  # Record every target key.
  if [[ ! -f "$F_TARGETS" ]]; then : > "$F_TARGETS"; fi
  while IFS=$'\t' read -r svc client ctype ind; do
    [[ -n "$svc" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$svc" "$client" "$ctype" "${ind:-UNUSED}" >> "$F_TARGETS"
  done < "$tgt"
  LC_ALL=C sort -u "$F_TARGETS" > "$F_TARGETS.tmp" && mv "$F_TARGETS.tmp" "$F_TARGETS"

  # Build one transaction.
  local sqlfile="$STATE_DIR/.grant.$$.sql"
  : > "$sqlfile"
  printf 'BEGIN IMMEDIATE;%s' "$NL" >> "$sqlfile"
  local csh indcode
  while IFS=$'\t' read -r svc client ctype ind; do
    [[ -n "$svc" ]] || continue
    csh="$(grep -F -m1 -e "$client"$'\t' "$client_reqs" 2>/dev/null | cut -f2 || true)"
    indcode=""
    if [[ "${ind:-UNUSED}" != "UNUSED" ]]; then
      indcode="$(grep -F -m1 -e "$ind"$'\t' "$target_reqs" 2>/dev/null | cut -f2 || true)"
    fi
    if [[ "${ind:-UNUSED}" == "UNUSED" ]]; then
      # Remove every legacy spelling of this non-AppleEvents row first
      # (NULL / '' / 'UNUSED'), otherwise a stale denied row can win.
      if [[ "$HAS_IND_ID" == "1" ]]; then
        printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s;%s' \
          "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$NL" >> "$sqlfile"
      else
        printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s;%s' \
          "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$NL" >> "$sqlfile"
      fi
    else
      if [[ "$HAS_IND_ID" == "1" ]]; then
        printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s AND indirect_object_identifier=%s;%s' \
          "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$(sql_q "$ind")" "$NL" >> "$sqlfile"
      fi
    fi
    insert_row_sql "$svc" "$client" "$ctype" "$csh" 2 4 1 0 "${ind:-UNUSED}" "$indcode" >> "$sqlfile"
  done < "$tgt"
  printf 'COMMIT;%s' "$NL" >> "$sqlfile"

  if ! run_sql_file "$tag" "$sqlfile"; then
    rm -f "$sqlfile" "$tgt" "$tmp_pres" "$tmp_added" "$exist_csreq" "$exist_ae" "$old_added_keys" \
      "$keyfile" "$client_reqs" "$target_reqs"
    return 1
  fi
  # Verify against the current target set (F_TARGETS also contains keys from
  # earlier runs and the /bin/bash FDA helper, which must not inflate the count).
  local verify_no verify_ae verify_n
  if ! detect_schema "$tag"; then
    rm -f "$sqlfile" "$tgt" "$tmp_pres" "$tmp_added" "$exist_csreq" "$exist_ae" "$old_added_keys" \
      "$keyfile" "$client_reqs" "$target_reqs"
    return 1
  fi
  verify_no="$(awk -F'\t' '$4=="UNUSED"{print $1"\t"$2"\t"$3}' "$tgt" | LC_ALL=C sort -u | in_values_list_noind)"
  if [[ "$HAS_IND_ID" == "1" ]]; then
    verify_ae="$(awk -F'\t' '$4!="UNUSED"{print $1"\t"$2"\t"$3"\t"$4}' "$tgt" | LC_ALL=C sort -u | in_values_list)"
  else
    verify_ae=""
  fi
  if [[ -n "$verify_no" || -n "$verify_ae" ]]; then
    local vq="$STATE_DIR/.verify.$$.sql"
    if [[ -n "$verify_no" && -n "$verify_ae" ]]; then
      printf 'SELECT (SELECT count(*) FROM access WHERE auth_value=2 AND (service, client, client_type) IN (%s)) + (SELECT count(*) FROM access WHERE auth_value=2 AND (service, client, client_type, indirect_object_identifier) IN (%s));\n' \
        "$verify_no" "$verify_ae" > "$vq"
    elif [[ -n "$verify_no" ]]; then
      printf 'SELECT count(*) FROM access WHERE auth_value=2 AND (service, client, client_type) IN (%s);\n' "$verify_no" > "$vq"
    else
      printf 'SELECT count(*) FROM access WHERE auth_value=2 AND (service, client, client_type, indirect_object_identifier) IN (%s);\n' "$verify_ae" > "$vq"
    fi
    verify_n="$(sql_query_file "$tag" "$vq" 2>/dev/null || echo 0)"
    rm -f "$vq"
  else
    verify_n=0
  fi
  verify_n="${verify_n:-0}"; verify_n="${verify_n%%[!0-9]*}"; [[ -n "$verify_n" ]] || verify_n=0
  GRANT_COUNT="$verify_n"
  rm -f "$sqlfile" "$tgt" "$tmp_pres" "$tmp_added" "$exist_csreq" "$exist_ae" "$old_added_keys" \
    "$keyfile" "$client_reqs" "$target_reqs"
  if [[ "$GRANT_COUNT" -lt "$GRANT_EXPECTED" ]]; then
    c_warn "Only $GRANT_COUNT of $GRANT_EXPECTED target rows are present in the $tag database."
  fi
  return 0
}

establish_added_baseline() {
  # On a first run, everything currently in the DB is "pre-existing"; the
  # snapshot in grant_targets handles the rows we actually touch.  This helper
  # exists for --add runs before enable.
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  [[ -f "$F_PRESERVE" ]] || : > "$F_PRESERVE"
  [[ -f "$F_TARGETS" ]] || : > "$F_TARGETS"
  [[ -f "$F_ADDED" ]] || : > "$F_ADDED"
}

# =============================================================================
#  Backups
# =============================================================================
backup_db() { # $1 = tag, $2 = destination
  local tag="$1" dest="$2" db; db="$(db_file "$tag")"
  [[ -f "$db" ]] || return 0
  rm -f "$dest"
  if [[ "$tag" == "sys" ]]; then
    if sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$db" \
         "VACUUM INTO $(sql_q "$dest");" >/dev/null 2>&1; then
      sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
      chmod 600 "$dest" 2>/dev/null || true
      return 0
    fi
    if sudo cp -p "$db" "$dest" 2>/dev/null; then
      sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
      chmod 600 "$dest" 2>/dev/null || true
      return 0
    fi
    sudo rm -f "$dest" 2>/dev/null || true
  else
    if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
      if sudo -n sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$db" \
           "VACUUM INTO $(sql_q "$dest");" >/dev/null 2>&1; then
        sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
        chmod 600 "$dest" 2>/dev/null || true
        return 0
      fi
      if sudo cp -p "$db" "$dest" 2>/dev/null; then
        sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
        chmod 600 "$dest" 2>/dev/null || true
        return 0
      fi
      sudo rm -f "$dest" 2>/dev/null || true
    else
      if sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$db" \
           "VACUUM INTO $(sql_q "$dest");" >/dev/null 2>&1; then
        chmod 600 "$dest" 2>/dev/null || true
        return 0
      fi
      if cp -p "$db" "$dest" 2>/dev/null; then
        chmod 600 "$dest" 2>/dev/null || true
        return 0
      fi
      rm -f "$dest" 2>/dev/null || true
    fi
  fi
  rm -f "$dest" 2>/dev/null || true
  return 1
}

do_backups() { # $1 = backup dir
  local bk="$1" zf
  mkdir -p "$bk"
  chmod 700 "$bk" 2>/dev/null || true
  # A failed earlier backup must not be mistaken for a good original.
  for zf in "$bk/TCC.system.db" "$bk/TCC.user.db" "$bk/ScreenCaptureApprovals.plist" \
            "$bk/com.apple.controlcenter.plist" "$bk/com.apple.systemuiserver.plist" \
            "$bk/com.apple.ncprefs.plist"; do
    if [[ -f "$zf" && ! -s "$zf" ]]; then rm -f "$zf" 2>/dev/null || true; fi
  done
  if [[ "$SYS_DB_PRESENT" == "1" && ! -f "$bk/TCC.system.db" ]]; then
    backup_db sys "$bk/TCC.system.db" || true
  fi
  if [[ "$USER_DB_PRESENT" == "1" && ! -f "$bk/TCC.user.db" ]]; then
    backup_db user "$bk/TCC.user.db" || true
  fi
  if [[ ! -f "$bk/ScreenCaptureApprovals.plist" ]]; then
    local rbk="" rexisted=""
    if [[ -f "$F_REPLAYD" ]]; then
      rexisted="$(sed -n 's/^existed=//p' "$F_REPLAYD" | head -1)"
      rbk="$(sed -n 's/^backup=//p' "$F_REPLAYD" | head -1)"
    fi
    if [[ -n "$rbk" && -f "$rbk" ]]; then
      cp -p "$rbk" "$bk/ScreenCaptureApprovals.plist" 2>/dev/null || true
    elif [[ "$rexisted" == "1" ]]; then
      # The only current copy may already be modified by an earlier run.
      c_warn "Original replayd backup is missing; not treating the current file as original."
    elif [[ "$rexisted" == "0" ]]; then
      : # It did not exist before; nothing to back up.
    elif [[ -f "$REPLAYD_PLIST" ]]; then
      cp -p "$REPLAYD_PLIST" "$bk/ScreenCaptureApprovals.plist" 2>/dev/null || true
    fi
  fi
  if "$DEFAULTS_BIN" read com.apple.controlcenter >/dev/null 2>&1; then
    "$DEFAULTS_BIN" export com.apple.controlcenter "$bk/com.apple.controlcenter.plist" >/dev/null 2>&1 || true
  fi
  if "$DEFAULTS_BIN" read com.apple.systemuiserver >/dev/null 2>&1; then
    "$DEFAULTS_BIN" export com.apple.systemuiserver "$bk/com.apple.systemuiserver.plist" >/dev/null 2>&1 || true
  fi
  if [[ -f "$NCPREFS" && ! -f "$bk/com.apple.ncprefs.plist" ]]; then
    cp -p "$NCPREFS" "$bk/com.apple.ncprefs.plist" 2>/dev/null || true
  fi
  return 0
}

# =============================================================================
#  replayd screen-recording nag (macOS 15+)
# =============================================================================
replayd_key_list() {
  # plutil's "raw" format only supports scalar strings/data, not a dictionary
  # root.  PlistBuddy prints top-level keys at four-space indentation; keys may
  # be quoted when they contain spaces.
  if [[ -f "$REPLAYD_PLIST" ]]; then
    "$PLIST_BUDDY" -c 'Print' "$REPLAYD_PLIST" 2>/dev/null |
      awk '
        /^    [^ ]/ {
          line = substr($0, 5)
          sub(/ = .*$/, "", line)
          if (line ~ /^".*"$/) line = substr(line, 2, length(line) - 2)
          if (line != "") print line
        }' |
      while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        case "$k" in kScreenCaptureApproval*) continue ;; esac
        # Only app identifiers/paths are approval records.  Metadata keys
        # (version numbers, counters, ...) must never be replaced by a dict.
        case "$k" in
          /*|*.*) ;;
          *) continue ;;
        esac
        printf '%s\n' "$k"
      done || true
  fi
}

apply_replayd() {
  if ! macos_at_least 15 0; then
    c_info "replayd nag suppression is only needed on macOS 15+; skipping."
    return 0
  fi
  local dir; dir="$(dirname "$REPLAYD_PLIST")"
  if [[ ! -d "$dir" ]]; then
    c_warn "replayd container not found; skipping screen-recording nag suppression."
    return 0
  fi
  local current_exists=0
  [[ -f "$REPLAYD_PLIST" ]] && current_exists=1
  local existed="$current_exists"
  local bk="" recorded_bk="" recorded_existed=""
  if [[ -f "$F_REPLAYD" ]]; then
    recorded_existed="$(sed -n 's/^existed=//p' "$F_REPLAYD" | head -1)"
    recorded_bk="$(sed -n 's/^backup=//p' "$F_REPLAYD" | head -1)"
    [[ -n "$recorded_existed" ]] && existed="$recorded_existed"
    if [[ -n "$recorded_bk" && -f "$recorded_bk" ]]; then
      bk="$(dirname "$recorded_bk")"
    fi
  fi
  if [[ -z "$bk" ]]; then
    local current_bk=""
    if [[ -f "$STATE_DIR/backups/CURRENT" ]]; then
      current_bk="$(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || true)"
    fi
    if [[ -n "$current_bk" && -f "$current_bk/ScreenCaptureApprovals.plist" ]]; then
      bk="$current_bk"
    fi
  fi
  if [[ -z "$bk" ]]; then
    if [[ -f "$F_REPLAYD" && "$existed" == "1" ]]; then
      c_warn "The original ScreenCaptureApprovals.plist backup is missing;"
      c_warn "refusing to overwrite it because --back could not restore it."
      return 1
    fi
    # Use a fresh directory rather than a fixed "manual" name: a stale
    # directory from an earlier off.sh/--back cycle must never be mistaken
    # for this run's original.
    bk="$STATE_DIR/backups/replayd-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo 0)-$$"
    mkdir -p "$bk" 2>/dev/null || true
  fi
  if [[ "$existed" == "1" && ! -f "$bk/ScreenCaptureApprovals.plist" ]]; then
    mkdir -p "$bk" 2>/dev/null || true
    if ! cp -p "$REPLAYD_PLIST" "$bk/ScreenCaptureApprovals.plist" 2>/dev/null; then
      c_warn "Could not back up ScreenCaptureApprovals.plist; refusing to modify it."
      return 1
    fi
  fi

  local keys=() k
  while IFS= read -r k; do [[ -n "$k" ]] && keys+=("$k"); done < <(replayd_key_list)
  for k in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do keys+=("$k"); done
  for k in ${APP_EXES[@]+"${APP_EXES[@]}"}; do keys+=("$k"); done
  for k in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do keys+=("$k"); done
  # replayd sometimes keys an approval by the executable name ("node"), not
  # only by its absolute path.  Add both spellings.
  local base kc="${#keys[@]}" ki=0
  while [[ "$ki" -lt "$kc" ]]; do
    k="${keys[$ki]}"
    case "$k" in
      /*) base="${k##*/}"; [[ -n "$base" ]] && keys+=("$base") ;;
    esac
    ki=$((ki + 1))
  done
  local _dedup=()
  while IFS= read -r k; do [[ -n "$k" ]] && _dedup+=("$k"); done \
    < <(printf '%s\n' ${keys[@]+"${keys[@]}"} | dedup_lines)
  keys=(${_dedup[@]+"${_dedup[@]}"})
  if [[ "${#keys[@]}" -eq 0 ]]; then
    c_info "No replayd approval keys to extend."
    return 0
  fi

  local mode="date"
  if macos_at_least 15 1; then mode="dict"; fi
  local n=0 success=0
  : > "$AGENT_KEYS"
  # Record the rollback information before the first write.  An interrupted
  # run can then still restore the original plist on --back.
  {
    echo "existed=$existed"
    echo "backup=$bk/ScreenCaptureApprovals.plist"
    echo "mode=$mode"
  } > "$F_REPLAYD"
  for k in ${keys[@]+"${keys[@]}"}; do
    n=$((n + 1))
    printf '%s\t%s\n' "$mode" "$k" >> "$AGENT_KEYS"
    if [[ "$mode" == "dict" ]]; then
      if "$DEFAULTS_BIN" write "$REPLAYD_PLIST" "$k" -dict \
           kScreenCaptureApprovalLastAlerted -date "$NAG_DATE" \
           kScreenCaptureApprovalLastUsed -date "$NAG_DATE" 2>/dev/null; then
        success=$((success + 1))
      fi
    else
      if "$DEFAULTS_BIN" write "$REPLAYD_PLIST" "$k" -date "$NAG_DATE" 2>/dev/null; then
        success=$((success + 1))
      fi
    fi
  done
  if [[ "$success" -eq 0 ]]; then
    c_warn "Could not write ScreenCaptureApprovals.plist."
    fda_hint "The terminal needs Full Disk Access for the replayd approvals file."
    return 1
  fi
  chmod 600 "$REPLAYD_PLIST" 2>/dev/null || true
  /usr/bin/killall -HUP replayd >/dev/null 2>&1 || sudo -n /usr/bin/killall -HUP replayd >/dev/null 2>&1 || true
  /usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
  c_ok "Screen-recording expiry nags extended ($success/$n keys -> 2099, format=$mode)."
  return 0
}

restore_replayd() {
  if [[ ! -f "$F_REPLAYD" ]]; then
    c_info "No replayd changes recorded - nothing to restore."
    return 0
  fi
  local existed bk
  existed="$(sed -n 's/^existed=//p' "$F_REPLAYD" | head -1)"
  bk="$(sed -n 's/^backup=//p' "$F_REPLAYD" | head -1)"
  if [[ "$existed" == "1" ]]; then
    if [[ ! -f "$bk" ]]; then
      c_warn "Screen-capture approvals backup is missing: $bk"
      c_warn "Leaving the current approvals file in place; the manifest is kept."
      return 1
    fi
    if ! cp -p "$bk" "$REPLAYD_PLIST" 2>/dev/null; then
      c_warn "Could not restore ScreenCaptureApprovals.plist (Full Disk Access missing)."
      return 1
    fi
    c_ok "Screen-capture approvals restored."
  elif [[ "$existed" == "0" ]]; then
    if ! rm -f "$REPLAYD_PLIST" 2>/dev/null; then
      c_warn "Could not remove ScreenCaptureApprovals.plist."
      return 1
    fi
    c_ok "Screen-capture approvals file removed (it did not exist before)."
  else
    c_warn "replayd state is incomplete; leaving current approvals in place."
    return 1
  fi
  /usr/bin/killall -HUP replayd >/dev/null 2>&1 || sudo -n /usr/bin/killall -HUP replayd >/dev/null 2>&1 || true
  /usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
  rm -f "$F_REPLAYD"
  return 0
}

install_replayd_agent() {
  if [[ "$SKIP_AGENT" == "1" ]]; then
    c_info "Skipping replayd LaunchAgent (--no-agent)."
    return 0
  fi
  if ! macos_at_least 15 1; then
    c_info "LaunchAgent is only needed on macOS 15.1+; skipping."
    return 0
  fi
  mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"
  cat > "$AGENT_SCRIPT" <<EOF
#!/bin/bash
# Generated by off.sh v$VERSION.  Do not edit by hand.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PLIST="$REPLAYD_PLIST"
KEYS="$AGENT_KEYS"
DATE="$NAG_DATE"
LOG="$AGENT_LOG"
FDAFLAG="$STATE_DIR/agent.fda-ok"
RSTATE="$F_REPLAYD"
exec >>"\$LOG" 2>&1
echo "--- \$(/bin/date) replayd refresh ---"
# Do not touch the protected approvals file until Full Disk Access has been
# granted, otherwise launchd would cause a new TCC prompt every day.
[[ -f "\$FDAFLAG" ]] || { echo "Full Disk Access not granted yet; skipping"; exit 0; }
# Never write if --back has removed the rollback manifest, or if the original
# backup it names has gone missing.
[[ -f "\$RSTATE" ]] || { echo "rollback manifest missing; skipping"; exit 0; }
grep -q '^existed=' "\$RSTATE" || { echo "rollback manifest incomplete; skipping"; exit 0; }
if grep -q '^existed=1' "\$RSTATE"; then
  BK="\$(sed -n 's/^backup=//p' "\$RSTATE" | head -1)"
  [[ -n "\$BK" && -f "\$BK" ]] || { echo "original backup missing; skipping"; exit 0; }
fi
[[ -f "\$PLIST" ]] || { echo "approvals plist missing"; exit 0; }
[[ -f "\$KEYS" ]] || { echo "keys file missing"; exit 0; }
while IFS=\$'\\t' read -r fmt key; do
  [[ -n "\$key" ]] || continue
  if [[ "\$fmt" == "dict" ]]; then
    /usr/bin/defaults write "\$PLIST" "\$key" -dict \\
      kScreenCaptureApprovalLastAlerted -date "\$DATE" \\
      kScreenCaptureApprovalLastUsed -date "\$DATE" || true
  else
    /usr/bin/defaults write "\$PLIST" "\$key" -date "\$DATE" || true
  fi
done < "\$KEYS"
/usr/bin/killall -HUP replayd >/dev/null 2>&1 || true
/usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
echo "done"
EOF
  chmod 700 "$AGENT_SCRIPT"

  local agent_script_xml state_xml
  agent_script_xml="$(xml_escape "$AGENT_SCRIPT")"
  state_xml="$(xml_escape "$STATE_DIR")"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>--noprofile</string>
		<string>--norc</string>
		<string>$agent_script_xml</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>86400</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$state_xml/replayd-agent.out</string>
	<key>StandardErrorPath</key>
	<string>$state_xml/replayd-agent.err</string>
</dict>
</plist>
EOF
  chmod 644 "$AGENT_PLIST"

  ensure_bash_fda
  if [[ "$AGENT_FDA_OK" == "1" ]]; then
    : > "$STATE_DIR/agent.fda-ok"
  else
    rm -f "$STATE_DIR/agent.fda-ok"
  fi
  /bin/launchctl bootout "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
  local agent_ok=0
  if /bin/launchctl bootstrap "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1; then
    echo "installed=1" > "$F_AGENT"
    agent_ok=1
    c_ok "Installed replayd refresh LaunchAgent (runs daily and at login)."
  else
    echo "installed=0" > "$F_AGENT"
    c_warn "Could not load the replayd LaunchAgent; immediate nag suppression still works, but it will not refresh after reboot."
  fi
  if [[ "$AGENT_FDA_OK" != "1" ]]; then
    c_warn "The LaunchAgent needs Full Disk Access for /bin/bash to keep the nag suppressed after reboot."
    echo "    System Settings -> Privacy & Security -> Full Disk Access -> + -> /bin/bash"
    echo "    then run: bash off.sh --refresh"
    echo "    (This is a one-time manual step only when SIP is enabled.)"
    open_fda_settings
  fi
  if [[ "$agent_ok" != "1" ]]; then return 1; fi
  return 0
}

remove_replayd_agent() {
  local loaded=0 had_plist=0
  [[ -f "$AGENT_PLIST" ]] && had_plist=1
  # Stop the job by label first: a crash may have removed the plist while the
  # job is still loaded in launchd.
  /bin/launchctl bootout "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1 || true
  if [[ "$had_plist" == "1" ]]; then
    /bin/launchctl bootout "gui/$UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
    /bin/launchctl unload "$AGENT_PLIST" >/dev/null 2>&1 || true
    rm -f "$AGENT_PLIST"
  fi
  if /bin/launchctl print "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1; then
    loaded=1
  fi
  # Remove the keys/FDA flag even if the job is still loaded, so a final run
  # cannot rewrite replayd after the restore.  Keep a state flag so --back can
  # retry after launchd releases it.
  rm -f "$AGENT_SCRIPT" "$AGENT_KEYS" "$STATE_DIR/agent.fda-ok"
  if [[ "$loaded" == "1" ]]; then
    printf 'loaded=1\n' > "$F_AGENT"
    c_warn "The replayd refresh agent is still loaded; it is disabled and will disappear at logout."
    return 1
  fi
  rm -f "$F_AGENT"
  [[ "$had_plist" == "1" ]] && c_ok "Removed replayd refresh LaunchAgent."
  return 0
}

# =============================================================================
#  Full Disk Access for /bin/bash (needed by the LaunchAgent)
# =============================================================================
ensure_bash_fda() {
  AGENT_FDA_OK=0
  if [[ ! -x /bin/bash ]]; then return 0; fi
  if ! detect_schema sys 2>/dev/null; then
    c_warn "Cannot inspect the system TCC database for /bin/bash Full Disk Access."
    return 0
  fi
  local count=""
  if ! count="$(sql_tag sys "SELECT count(*) FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client='/bin/bash' AND client_type=1 AND auth_value=2;" 2>/dev/null)"; then
    c_warn "Could not check /bin/bash Full Disk Access; skipping the daily-agent grant."
    return 0
  fi
  count="${count:-0}"; count="${count%%[!0-9]*}"
  if [[ "${count:-0}" -gt 0 ]]; then
    AGENT_FDA_OK=1
    return 0
  fi
  if [[ "$SYS_DB_WRITABLE" != "1" ]]; then
    return 0
  fi
  # Snapshot/record this one row through the same manifest format.  Match by
  # service/client/client_type, not by the legacy 'UNUSED' spelling.
  local key="sys"$'\t'"kTCCServiceSystemPolicyAllFiles"$'\t'"/bin/bash"$'\t'"1"$'\t'"UNUSED"
  local existing
  if ! existing="$(sql_tag sys "SELECT COALESCE(indirect_object_identifier,'UNUSED') || '|' || auth_value || '|' || auth_reason || '|' || auth_version || '|' || COALESCE(hex(csreq),'') || '|' || COALESCE(flags,'') || '|' || COALESCE(hex(indirect_object_code_identity),'') FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client='/bin/bash' AND client_type=1;" 2>/dev/null)"; then
    c_warn "Could not snapshot the existing /bin/bash TCC row; refusing to change Full Disk Access."
    return 0
  fi
  if [[ -n "$existing" ]]; then
    local existing_line a r v c f ic ind2 pkey
    while IFS= read -r existing_line; do
      [[ -n "$existing_line" ]] || continue
      IFS='|' read -r ind2 a r v c f ic <<< "$existing_line"
      pkey="sys"$'\t'"kTCCServiceSystemPolicyAllFiles"$'\t'"/bin/bash"$'\t'"1"$'\t'"${ind2:-UNUSED}"
      if ! grep -F -q -e "$pkey"$'\t' "$F_PRESERVE" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "sys" "kTCCServiceSystemPolicyAllFiles" "/bin/bash" "1" "${ind2:-UNUSED}" \
          "${a:-0}" "${r:-0}" "${v:-1}" "${c:--}" "${f:--}" "${ic:--}" >> "$F_PRESERVE"
      fi
    done <<< "$existing"
  fi
  # We delete+reinsert this key below, so it must be in F_ADDED even when a
  # denied/stale row existed; --back then removes our row and reinserts the
  # snapshot above.  Without this, a pre-existing row with a different
  # indirect id would be duplicated on restore.
  printf '%s\n' "$key" >> "$F_ADDED"
  printf '%s\n' "$key" >> "$F_TARGETS"
  local csh sqlfile="$STATE_DIR/.bashfda.$$.sql"
  csh="$(csreq_hex_for_path /bin/bash 2>/dev/null || true)"
  : > "$sqlfile"
  printf 'BEGIN IMMEDIATE;%s' "$NL" >> "$sqlfile"
  printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s;%s' \
    "$(sql_q "kTCCServiceSystemPolicyAllFiles")" "$(sql_q "/bin/bash")" "1" "$NL" >> "$sqlfile"
  insert_row_sql "kTCCServiceSystemPolicyAllFiles" "/bin/bash" 1 "$csh" 2 4 1 0 "UNUSED" "" >> "$sqlfile"
  printf 'COMMIT;%s' "$NL" >> "$sqlfile"
  if run_sql_file sys "$sqlfile"; then
    AGENT_FDA_OK=1
    c_ok "Granted Full Disk Access to /bin/bash for the daily nag-refresh agent."
  else
    c_warn "Could not grant Full Disk Access to /bin/bash automatically."
  fi
  rm -f "$sqlfile"
  for f in "$F_ADDED" "$F_PRESERVE" "$F_TARGETS"; do
    [[ -f "$f" ]] && { LC_ALL=C sort -u "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
  done
  return 0
}

# =============================================================================
#  BTM notification profile
# =============================================================================
write_btm_profile() {
  mkdir -p "$(dirname "$BTM_PROFILE")"
  # Stable identifiers keep repeated runs/approvals from creating duplicates.
  local u1="A1B2C3D4-E5F6-47A8-9B0C-0D1E2F3A4B5C"
  local u2="B2C3D4E5-F6A7-48B9-8C0D-1E2F3A4B5C6D"
  cat > "$BTM_PROFILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>NotificationSettings</key>
			<array>
				<dict>
					<key>BundleIdentifier</key><string>com.apple.BTMNotificationAgent</string>
					<key>NotificationsEnabled</key><false/>
					<key>ShowInNotificationCenter</key><false/>
					<key>ShowInLockScreen</key><false/>
					<key>ShowInAlert</key><false/>
					<key>GroupingType</key><integer>0</integer>
					<key>SoundsEnabled</key><false/>
					<key>BadgesEnabled</key><false/>
					<key>CriticalAlertEnabled</key><false/>
					<key>AlertType</key><integer>0</integer>
				</dict>
				<dict>
					<key>BundleIdentifier</key><string>com.apple.btmnotificationagent</string>
					<key>NotificationsEnabled</key><false/>
					<key>ShowInNotificationCenter</key><false/>
					<key>ShowInLockScreen</key><false/>
					<key>ShowInAlert</key><false/>
					<key>GroupingType</key><integer>0</integer>
					<key>SoundsEnabled</key><false/>
					<key>BadgesEnabled</key><false/>
					<key>CriticalAlertEnabled</key><false/>
					<key>AlertType</key><integer>0</integer>
				</dict>
				<dict>
					<key>BundleIdentifier</key><string>_system_center_:com.apple.btmnotificationagent</string>
					<key>NotificationsEnabled</key><false/>
					<key>ShowInNotificationCenter</key><false/>
					<key>ShowInLockScreen</key><false/>
					<key>ShowInAlert</key><false/>
					<key>GroupingType</key><integer>0</integer>
					<key>SoundsEnabled</key><false/>
					<key>BadgesEnabled</key><false/>
					<key>CriticalAlertEnabled</key><false/>
					<key>AlertType</key><integer>0</integer>
				</dict>
			</array>
			<key>PayloadDisplayName</key><string>Silence App Background Activity notices</string>
			<key>PayloadIdentifier</key><string>com.off.devtool.btm-notifications.payload.$u2</string>
			<key>PayloadType</key><string>com.apple.notificationsettings</string>
			<key>PayloadUUID</key><string>$u2</string>
			<key>PayloadVersion</key><integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key><string>Suppresses macOS Background Items Added / App Background Activity notifications without disabling the background items themselves.</string>
	<key>PayloadDisplayName</key><string>Disable App Background Activity notifications</string>
	<key>PayloadIdentifier</key><string>$BTM_PROFILE_ID</string>
	<key>PayloadOrganization</key><string>off.sh</string>
	<key>PayloadScope</key><string>System</string>
	<key>PayloadRemovalDisallowed</key><false/>
	<key>PayloadType</key><string>Configuration</string>
	<key>PayloadUUID</key><string>$u1</string>
	<key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
EOF
  chmod 600 "$BTM_PROFILE"
  return 0
}

profile_installed() {
  {
    sudo -n /usr/bin/profiles -P 2>/dev/null || /usr/bin/profiles -P 2>/dev/null || true
  } | grep -F -q "$BTM_PROFILE_ID"
}

install_btm_profile() {
  if [[ "$SKIP_PROFILE" == "1" ]]; then
    c_info "Skipping BTM notification profile (--no-profile)."
    return 0
  fi
  write_btm_profile
  # Mark the work before installing, so an interrupted run is still reversible.
  echo "installed=pending" > "$F_PROFILE"
  if profile_installed; then
    c_ok "BTM notification suppression profile is already installed."
    echo "installed=1" > "$F_PROFILE"
    return 0
  fi
  # Some macOS builds allow a local root install.  If Apple blocks it, open
  # the profile so the user can approve it once in Device Management.
  if sudo -n /usr/bin/profiles install -path "$BTM_PROFILE" >/dev/null 2>&1 && profile_installed; then
    c_ok "Installed BTM notification suppression profile."
    echo "installed=1" > "$F_PROFILE"
    /usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
    return 0
  fi
  /usr/bin/open "$BTM_PROFILE" >/dev/null 2>&1 || true
  echo "installed=pending" > "$F_PROFILE"
  PROFILE_PENDING=1
  c_warn "macOS requires one approval for the notification-silencing profile."
  echo "    System Settings -> General -> Device Management -> approve"
  echo "    'Disable App Background Activity notifications'."
  echo "    The profile file is: $BTM_PROFILE"
  echo "    This profile is the most reliable way to suppress Apple's BTM banners."
  return 0
}

remove_btm_profile() {
  local try_remove=0 out=""
  if [[ -f "$F_PROFILE" ]]; then
    try_remove=1
  fi
  if profile_installed; then try_remove=1; fi
  if [[ "$try_remove" == "1" ]]; then
    # F_PROFILE is authoritative: it may say installed=1 even if profiles -P
    # cannot see the profile (stale sudo timestamp or a listing quirk).
    if out="$(sudo -n /usr/bin/profiles remove -identifier "$BTM_PROFILE_ID" 2>&1)" \
       || out="$(/usr/bin/profiles remove -identifier "$BTM_PROFILE_ID" 2>&1)"; then
      c_ok "Removed BTM notification suppression profile."
    elif printf '%s' "$out" | grep -qiE 'not found|does not exist|no profile'; then
      c_ok "BTM notification profile was already absent."
    else
      c_warn "Could not remove the BTM notification profile automatically."
      echo "    Remove it in System Settings -> General -> Device Management."
      open_device_management
      return 1
    fi
  fi
  rm -f "$F_PROFILE" "$BTM_PROFILE"
  return 0
}

# Some macOS releases post the BTM banner from backgroundtaskmanagementagent
# itself.  This key is a best-effort, fully reversible supplement to the
# profile above.
apply_btm_agent_prefs() {
  local key old existed
  [[ -f "$F_BTM" ]] || : > "$F_BTM"
  for key in notificationsEnabled BackgroundItemsAddedNotificationsEnabled; do
    # Record the value only the first time.  A refresh/re-enable must not
    # replace the user's original value with our already-written "false".
    if ! awk -F'\t' -v k="$key" '$1==k{found=1;exit} END{exit !found}' "$F_BTM" 2>/dev/null; then
      existed=0; old=""
      if old="$("$DEFAULTS_BIN" read "$BTM_AGENT_DOMAIN" "$key" 2>/dev/null)"; then
        existed=1
      else
        old=""
      fi
      # The values are normally scalar booleans; do not record multi-line data.
      case "$old" in
        *$'\n'*) existed=0; old="" ;;
      esac
      printf '%s\t%s\t%s\n' "$key" "$existed" "$old" >> "$F_BTM"
    fi
    if ! "$DEFAULTS_BIN" write "$BTM_AGENT_DOMAIN" "$key" -bool false >/dev/null 2>&1; then
      c_warn "Could not set $BTM_AGENT_DOMAIN $key."
      return 1
    fi
  done
  /usr/bin/killall backgroundtaskmanagementagent >/dev/null 2>&1 || true
  c_ok "Disabled Background Task Management notification banners."
  return 0
}

restore_btm_agent_prefs() {
  [[ -f "$F_BTM" ]] || return 0
  local key existed old failed=0
  while IFS=$'\t' read -r key existed old; do
    [[ -n "$key" ]] || continue
    if [[ "$existed" == "1" ]]; then
      case "$old" in
        0|1|true|false) "$DEFAULTS_BIN" write "$BTM_AGENT_DOMAIN" "$key" -bool "$old" >/dev/null 2>&1 || failed=1 ;;
        *)              "$DEFAULTS_BIN" write "$BTM_AGENT_DOMAIN" "$key" -string "$old" >/dev/null 2>&1 || failed=1 ;;
      esac
    else
      "$DEFAULTS_BIN" delete "$BTM_AGENT_DOMAIN" "$key" >/dev/null 2>&1 || true
    fi
  done < "$F_BTM"
  if [[ "$failed" == "1" ]]; then
    c_warn "Could not restore all Background Task Management preferences."
    return 1
  fi
  /usr/bin/killall backgroundtaskmanagementagent >/dev/null 2>&1 || true
  rm -f "$F_BTM"
  c_ok "Background Task Management preferences restored."
  return 0
}

# =============================================================================
#  ncprefs fallback (when the profile is pending / must be avoided)
# =============================================================================
apply_ncprefs_fallback() {
  [[ -n "$PYTHON_BIN" ]] || return 0
  [[ -f "$NCPREFS" ]] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local tmp="$STATE_DIR/.ncprefs.$$.plist"
  if [[ ! -f "$NCPREFS_BACKUP" ]]; then
    "$DEFAULTS_BIN" export com.apple.ncprefs "$NCPREFS_BACKUP" >/dev/null 2>&1 \
      || cp -p "$NCPREFS" "$NCPREFS_BACKUP" 2>/dev/null || true
  fi
  if [[ ! -f "$NCPREFS_BACKUP" ]]; then
    c_warn "Could not back up Notification Center preferences; skipping that fallback."
    return 1
  fi
  if ! "$DEFAULTS_BIN" export com.apple.ncprefs "$tmp" >/dev/null 2>&1; then
    cp -p "$NCPREFS" "$tmp" 2>/dev/null || return 0
  fi
  local result
  result="$("$PYTHON_BIN" - "$tmp" <<'PY' 2>/dev/null || true
import plistlib, sys
p = sys.argv[1]
ids = {
    "com.apple.BTMNotificationAgent",
    "com.apple.btmnotificationagent",
    "_system_center_:com.apple.btmnotificationagent",
    "_system_center_:com.apple.BTMNotificationAgent",
}
try:
    with open(p, "rb") as f:
        d = plistlib.load(f)
except Exception:
    sys.exit(0)
apps = d.get("apps")
if not isinstance(apps, list):
    sys.exit(0)
changed = 0
for app in apps:
    if not isinstance(app, dict):
        continue
    bid = app.get("bundle-id") or app.get("bundle_id")
    if bid not in ids:
        continue
    flags = app.get("flags", 0)
    if not isinstance(flags, int):
        try:
            flags = int(flags)
        except Exception:
            flags = 0
    new = flags & ~(1 << 25)
    if new != flags:
        app["flags"] = new
        changed += 1
if changed:
    try:
        with open(p, "wb") as f:
            plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
    except Exception:
        sys.exit(0)
    print(changed)
PY
)"
  if [[ -n "$result" ]]; then
    # Mark the work before importing, so an interrupted import is reversible.
    echo "changed=$result" > "$F_NCPREFS"
    # Import through cfprefsd so the on-disk file and its cache agree.
    if ! "$DEFAULTS_BIN" import com.apple.ncprefs "$tmp" >/dev/null 2>&1; then
      cp -p "$tmp" "$NCPREFS" 2>/dev/null || true
      /usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
    fi
    /usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
    c_ok "Disabled existing BTM notification entries in Notification Center preferences."
  fi
  rm -f "$tmp"
  return 0
}

restore_ncprefs() {
  [[ -f "$F_NCPREFS" ]] || return 0
  if [[ ! -f "$NCPREFS_BACKUP" ]]; then
    c_warn "Notification Center backup is missing; cannot restore it."
    return 1
  fi
  if "$DEFAULTS_BIN" import com.apple.ncprefs "$NCPREFS_BACKUP" >/dev/null 2>&1; then
    /usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
    c_ok "Notification Center preferences restored."
  elif cp -p "$NCPREFS_BACKUP" "$NCPREFS" 2>/dev/null; then
    /usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
    /usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
    c_ok "Notification Center preferences restored."
  else
    c_warn "Could not restore Notification Center preferences."
    return 1
  fi
  rm -f "$F_NCPREFS"
  return 0
}

# =============================================================================
#  Screen Sharing menu extra (best effort; privacy indicator is not hideable)
# =============================================================================
screen_sharing_enabled() {
  sudo -n /bin/launchctl print system/com.apple.screensharing >/dev/null 2>&1
}

hide_screen_sharing_menu_extra() {
  MENU_CHANGED=0
  MENU_FAIL=0
  if [[ "$SKIP_MENU" == "1" ]]; then
    c_info "Skipping menu-bar extra handling (--no-menu)."
    return 0
  fi

  local candidates=(
    "NSStatusItem Visible Screen Sharing"
    "NSStatusItem Visible ScreenSharing"
    "NSStatusItem Visible com.apple.menuextra.screensharing"
    "NSStatusItem Visible ScreenShare"
    "NSStatusItem Visible com.apple.ScreenSharing"
    "ScreenSharingMenuExtra"
  )
  local keys=() k e old dup lower
  if "$DEFAULTS_BIN" read com.apple.controlcenter >/dev/null 2>&1; then
    # Discover any status-item key whose name mentions Screen + Sharing, in
    # addition to the known candidates.  Only scalar old values are touched.
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      lower="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in
        *screen*shar*|*shar*screen*) ;;
        *) continue ;;
      esac
      # Only menu-extra visibility keys.  Never touch service toggles such as
      # ScreenSharingEnabled: the user needs the Screen Sharing service for VM
      # access, and only the purple menu-bar extra should disappear.
      case "$k" in
        NSStatusItem*|*MenuExtra*) ;;
        *) continue ;;
      esac
      dup=0
      for e in ${keys[@]+"${keys[@]}"}; do [[ "$e" == "$k" ]] && dup=1; done
      [[ "$dup" == "0" ]] && keys+=("$k")
    done < <(
      "$DEFAULTS_BIN" read com.apple.controlcenter 2>/dev/null | awk '
        /^    [^ ]/ {
          line = substr($0, 5)
          sub(/ = .*$/, "", line)
          if (line ~ /^".*"$/) line = substr(line, 2, length(line) - 2)
          if (line != "") print line
        }'
    )
  fi
  for k in ${candidates[@]+"${candidates[@]}"}; do
    if "$DEFAULTS_BIN" read com.apple.controlcenter "$k" >/dev/null 2>&1; then
      dup=0
      for e in ${keys[@]+"${keys[@]}"}; do [[ "$e" == "$k" ]] && dup=1; done
      [[ "$dup" == "0" ]] && keys+=("$k")
    fi
  done

  if [[ "${#keys[@]}" -gt 0 ]]; then
    if [[ ! -f "$CC_BACKUP" ]]; then
      "$DEFAULTS_BIN" export com.apple.controlcenter "$CC_BACKUP" >/dev/null 2>&1 || true
    fi
    if [[ ! -f "$CC_BACKUP" ]]; then
      c_warn "Could not back up Control Center preferences; refusing to change them."
    else
      for k in ${keys[@]+"${keys[@]}"}; do
        old="$("$DEFAULTS_BIN" read com.apple.controlcenter "$k" 2>/dev/null || true)"
        [[ -n "$old" ]] || continue
        # Never rewrite a dictionary/array value: only scalar menu-item state.
        case "$old" in *$'\n'*) continue ;; esac
        case "$old" in
          0|1|true|false|YES|NO) ;;
          *)
            if ! [[ "$old" =~ ^[0-9]+$ ]]; then continue; fi
            ;;
        esac
        case "$k" in
          NSStatusItem*) printf '%s\t%s\n' "$k" "$old" >> "$F_CC"; "$DEFAULTS_BIN" write com.apple.controlcenter "$k" -bool false >/dev/null 2>&1 || { MENU_FAIL=1; continue; } ;;
          *)             printf '%s\t%s\n' "$k" "$old" >> "$F_CC"; "$DEFAULTS_BIN" write com.apple.controlcenter "$k" -bool false >/dev/null 2>&1 || { MENU_FAIL=1; continue; } ;;
        esac
        MENU_CHANGED=1
      done
      if [[ "$MENU_CHANGED" == "1" ]]; then
        /usr/bin/killall ControlCenter >/dev/null 2>&1 || true
        c_ok "Hid detected Screen Sharing Control Center menu-extra setting(s)."
      elif [[ "$MENU_FAIL" == "1" ]]; then
        c_warn "Could not change a Screen Sharing Control Center setting; --back will restore it."
      elif [[ -f "$F_CC" ]]; then
        c_info "Screen Sharing Control Center keys are already hidden."
      else
        c_info "No Screen Sharing menu-extra status-item key was found."
        echo "    If you still see the purple service icon, turn it off once in:"
        echo "      System Settings -> Control Center -> Screen Share -> Don't show in Menu Bar"
        open_control_center_settings
      fi
    fi
  else
    c_info "No Control Center Screen Sharing menu-extra key was found."
    open_control_center_settings
  fi

  hide_systemuiserver_menu_extra
  if screen_sharing_enabled; then
    c_info "Screen Sharing service is ON (needed to reach this Mac remotely)."
  fi
  echo "    A purple screen+person *service* icon is the Screen Sharing menu extra."
  echo "    The separate screen-recording privacy indicator shown while an app is"
  echo "    actively capturing is an Apple security indicator and cannot be hidden"
  echo "    by userspace software; hiding it would require stopping the capture."
  return 0
}

hide_systemuiserver_menu_extra() {
  # Older macOS versions keep menu extras in com.apple.systemuiserver.
  if ! "$DEFAULTS_BIN" read com.apple.systemuiserver menuExtras >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f "$SS_BACKUP" ]]; then
    "$DEFAULTS_BIN" export com.apple.systemuiserver "$SS_BACKUP" >/dev/null 2>&1 || true
  fi
  if [[ ! -f "$SS_BACKUP" ]]; then
    c_warn "Could not back up SystemUIServer menu extras; skipping them."
    return 0
  fi
  local tmp="$STATE_DIR/.systemuiserver.$$.plist"
  if ! "$DEFAULTS_BIN" export com.apple.systemuiserver "$tmp" >/dev/null 2>&1; then
    cp -p "$SS_PLIST" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  fi
  local n=0 i entry lower changed=0
  n="$("$PLIST_BUDDY" -c 'Print :menuExtras' "$tmp" 2>/dev/null | grep -c '^    ' || true)"
  n="${n:-0}"
  i=$((n - 1))
  while [[ "$i" -ge 0 ]]; do
    entry="$("$PLIST_BUDDY" -c "Print :menuExtras:$i" "$tmp" 2>/dev/null || true)"
    lower="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *screen*shar*|*shar*screen*)
        if "$PLIST_BUDDY" -c "Delete :menuExtras:$i" "$tmp" >/dev/null 2>&1; then
          changed=1
        fi
        ;;
    esac
    i=$((i - 1))
  done
  if [[ "$changed" == "1" ]]; then
    # Record the rollback before importing, so a crash between the import and
    # the flag still leaves --back able to restore the original.
    printf 'changed=1\n' > "$F_MENU"
    if "$DEFAULTS_BIN" import com.apple.systemuiserver "$tmp" >/dev/null 2>&1; then
      /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
      c_ok "Removed the legacy Screen Sharing SystemUIServer menu extra."
    else
      MENU_FAIL=1
      c_warn "Could not update SystemUIServer menu extras."
    fi
  fi
  rm -f "$tmp"
  return 0
}

restore_control_center() {
  [[ -f "$F_CC" ]] || return 0
  if [[ ! -f "$CC_BACKUP" ]]; then
    c_warn "Control Center backup is missing; cannot restore it."
    return 1
  fi
  if "$DEFAULTS_BIN" import com.apple.controlcenter "$CC_BACKUP" >/dev/null 2>&1; then
    /usr/bin/killall ControlCenter >/dev/null 2>&1 || true
    c_ok "Control Center settings restored."
  else
    c_warn "Could not restore Control Center preferences from $CC_BACKUP."
    return 1
  fi
  rm -f "$F_CC"
  return 0
}

restore_systemuiserver() {
  [[ -f "$F_MENU" ]] || return 0
  if [[ ! -f "$SS_BACKUP" ]]; then
    c_warn "SystemUIServer menu-extra backup is missing; cannot restore it."
    return 1
  fi
  if "$DEFAULTS_BIN" import com.apple.systemuiserver "$SS_BACKUP" >/dev/null 2>&1; then
    /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
    c_ok "SystemUIServer menu extras restored."
  elif cp -p "$SS_BACKUP" "$SS_PLIST" 2>/dev/null; then
    /usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
    /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
    c_ok "SystemUIServer menu extras restored."
  else
    c_warn "Could not restore SystemUIServer menu extras."
    return 1
  fi
  rm -f "$F_MENU"
  return 0
}

# =============================================================================
#  Developer Tools authorization prompt
# =============================================================================
enable_devtools() {
  local st=""
  if [[ ! -x /usr/sbin/DevToolsSecurity ]]; then
    return 0
  fi
  st="$(/usr/sbin/DevToolsSecurity -status 2>/dev/null || true)"
  st="$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')"
  case "$st" in
    *enabled*)
      c_info "Developer Tools mode is already enabled."
      return 0
      ;;
  esac
  # Mark the rollback before changing the system setting.
  printf 'changed=1\n' > "$F_DEVTOOLS"
  if sudo -n /usr/sbin/DevToolsSecurity -enable >/dev/null 2>&1; then
    c_ok "Enabled Developer Tools mode (no repeated developer-tool authorization prompts)."
  else
    rm -f "$F_DEVTOOLS"
    c_warn "Could not enable Developer Tools mode (not required for TCC)."
  fi
  return 0
}

restore_devtools() {
  [[ -f "$F_DEVTOOLS" ]] || return 0
  if grep -q '^changed=1' "$F_DEVTOOLS" 2>/dev/null; then
    if ! sudo -n /usr/sbin/DevToolsSecurity -disable >/dev/null 2>&1; then
      c_warn "Could not disable Developer Tools mode again."
      return 1
    fi
    c_ok "Developer Tools mode restored to disabled."
  fi
  rm -f "$F_DEVTOOLS"
  return 0
}

# =============================================================================
#  TCC daemon reload
# =============================================================================
reload_tccd() {
  if sudo -n /usr/bin/killall tccd >/dev/null 2>&1; then
    sleep 1
    return 0
  fi
  # killall also fails when tccd is not currently running.  In that case the
  # next TCC request starts a fresh daemon with the new database contents.
  if ! sudo -n true >/dev/null 2>&1; then
    return 1
  fi
  if sudo -n /usr/bin/pgrep -x tccd >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# =============================================================================
#  Explain / plan
# =============================================================================
explain_plan() {
  local nclients=$(( ${#CLI_PATHS[@]} + ${#APP_BUNDLES[@]} ))
  echo ""
  hr
  echo "  off.sh v$VERSION  -  DEV MODE"
  hr
  echo "  This will:"
  echo "   1. Back up both TCC privacy databases and the screen-capture plist"
  echo "      to $STATE_DIR/backups/"
  echo "   2. Pre-approve ${#SERVICES[@]} privacy services for $nclients dev clients:"
  echo "      screen recording, microphone, camera, full disk, accessibility,"
  echo "      input monitoring, automation, local network, Bluetooth, folders,"
  echo "      photos/calendar/contacts/reminders and related services."
  echo "   3. Extend the macOS 15/26 screen-recording approval dates to 2099"
  echo "      using the correct per-app dictionary format."
  echo "   4. Install a daily LaunchAgent that keeps those dates extended."
  echo "   5. Suppress App Background Activity / Background Items Added"
  echo "      notifications with a profile plus the BTM agent preference."
  echo "   6. Hide the Screen Sharing menu extra when macOS exposes a setting."
  echo "   7. Enable Developer Tools mode so lldb/debugger authorization stops."
  echo ""
  echo "  Detected clients:"
  local c
  for c in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do echo "    [bin] $c"; done
  for c in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do echo "    [app] $c"; done
  echo ""
  echo "  WARNING: while active, these tools can capture the screen, microphone,"
  echo "  camera and files without asking.  Use this on a development machine."
  echo ""
  echo "  Note: on a stock Mac with SIP enabled, Apple makes the system TCC"
  echo "  database read-only even for root.  off.sh detects that and reports it;"
  echo "  it never claims those system-wide grants succeeded."
  echo ""
  echo "  No reboot.  No log-out.  Restore with: bash off.sh --back"
  echo "  Some one-time approvals may still be requested by macOS (the"
  echo "  notification profile and /bin/bash Full Disk Access); off.sh prints"
  echo "  the exact steps if they are needed."
  hr
  echo ""
}

# =============================================================================
#  ENABLE
# =============================================================================
cmd_enable() {
  require_darwin
  require_user
  require_sqlite3
  macos_init
  collect_cli_paths
  collect_apps
  collect_ae_targets

  local nclients=$(( ${#CLI_PATHS[@]} + ${#APP_BUNDLES[@]} ))
  if [[ "$nclients" -eq 0 ]]; then
    die "No node/python/dev apps found. Add one with: bash off.sh --add /path/to/binary"
  fi
  explain_plan

  c_info "Admin password needed to write the privacy databases."
  need_sudo

  echo ""
  hr
  echo "  FINAL CHECK"
  hr
  echo "  This enables dev mode for $nclients clients: broad TCC grants,"
  echo "  screen-recording nag suppression, BTM notification silencing, and"
  echo "  the Screen Sharing menu-extra fix where macOS exposes it."
  echo "  Everything above is reversible with: bash off.sh --back"
  if ! confirm "Apply now? Type y + Enter (anything else cancels)"; then
    c_info "Cancelled. Nothing was changed."
    exit 0
  fi

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  normalize_legacy_manifests
  establish_added_baseline
  printf '%s\n' "$VERSION" > "$F_VERSION"

  local already=0
  [[ -f "$F_ENABLED" ]] && already=1
  local stamp bk have_current=0 cur_bk=""
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo 0)"
  bk="$STATE_DIR/backups/$stamp"
  if [[ -f "$STATE_DIR/backups/CURRENT" ]]; then
    cur_bk="$(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || true)"
    if [[ -n "$cur_bk" && -d "$cur_bk" ]]; then
      bk="$cur_bk"
      have_current=1
    fi
  fi
  if [[ "$already" == "1" ]]; then
    c_info "Already active - re-syncing (the original snapshot is kept)."
    if [[ "$have_current" == "0" ]]; then
      c_warn "The original backup record is missing; a new backup will be created."
    fi
  fi

  c_step "[1/8] Probing TCC database permissions ..."
  if probe_sys_db; then
    c_ok "System TCC.db: WRITABLE (system-wide grants will apply)."
  else
    case "$SYS_DB_STATE" in
      readonly)
        c_warn "System TCC.db: READ-ONLY (SIP is blocking writes)."
        sip_hint
        ;;
      blocked|missing)
        c_warn "System TCC.db: NOT ACCESSIBLE."
        if [[ "$SIP_ENABLED" == "1" ]]; then sip_hint; else fda_hint "Cannot read the system TCC database."; fi
        ;;
    esac
  fi
  if probe_user_db; then
    c_ok "User TCC.db: WRITABLE ($USER_DB_STATE)."
  else
    case "$USER_DB_STATE" in
      missing) c_warn "User TCC.db: does not exist yet (macOS creates it at the first mic/camera prompt)." ;;
      *) fda_hint "Cannot write the user TCC database." ;;
    esac
  fi

  c_step "[2/8] Backing up current state ..."
  mkdir -p "$STATE_DIR/backups"
  # do_backups only fills in missing files, so reusing CURRENT is safe and
  # keeps the true pre-off.sh snapshot across --add and --refresh.
  do_backups "$bk"
  if [[ "$have_current" == "0" ]]; then
    printf '%s\n' "$bk" > "$STATE_DIR/backups/CURRENT"
  fi
  if [[ -f "$bk/TCC.system.db" || -f "$bk/TCC.user.db" || -f "$bk/ScreenCaptureApprovals.plist" ]]; then
    if [[ "$have_current" == "1" ]]; then
      c_ok "Using original backups: $bk"
    else
      c_ok "Backups saved: $bk"
    fi
  else
    c_warn "No database backup was possible (permission issue)."
  fi

  local pf="$STATE_DIR/.paths.$$.tmp" bf="$STATE_DIR/.bundles.$$.tmp"
  printf '%s\n' ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} > "$pf"
  printf '%s\n' ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"} > "$bf"

  c_step "[3/8] Granting permissions in the system TCC database ..."
  GRANT_FAIL=0
  if [[ "$SYS_DB_WRITABLE" == "1" ]]; then
    if grant_targets sys "$pf" "$bf"; then
      c_ok "System database: $GRANT_COUNT/$GRANT_EXPECTED rows present."
      [[ "$GRANT_COUNT" -lt "$GRANT_EXPECTED" ]] && GRANT_FAIL=1
    else
      c_warn "System database: grant pass failed."
      GRANT_FAIL=1
    fi
  else
    c_warn "System database: SKIPPED (SIP/permission block)."
    GRANT_FAIL=1
  fi

  c_step "[4/8] Granting permissions in the user TCC database ..."
  if [[ "$USER_DB_WRITABLE" == "1" ]]; then
    if grant_targets user "$pf" "$bf"; then
      c_ok "User database: $GRANT_COUNT/$GRANT_EXPECTED rows present."
      [[ "$GRANT_COUNT" -lt "$GRANT_EXPECTED" ]] && GRANT_FAIL=1
    else
      c_warn "User database: grant pass failed."
      GRANT_FAIL=1
    fi
  else
    c_warn "User database: SKIPPED (Full Disk Access or database missing)."
    GRANT_FAIL=1
  fi
  rm -f "$pf" "$bf"

  c_step "[5/8] Extending screen-recording approvals (replayd) ..."
  if ! apply_replayd; then GRANT_FAIL=1; fi

  c_step "[6/8] Silencing App Background Activity notifications ..."
  install_btm_profile || true
  apply_btm_agent_prefs || true
  apply_ncprefs_fallback || true

  c_step "[7/8] Installing the daily replayd refresh agent ..."
  if ! install_replayd_agent; then GRANT_FAIL=1; fi

  c_step "[8/8] Menu-bar extra + developer tools + live reload ..."
  hide_screen_sharing_menu_extra || true
  local menu_pending=0
  if [[ "$SKIP_MENU" != "1" ]]; then
    if [[ "$MENU_FAIL" == "1" || ( ! -f "$F_CC" && ! -f "$F_MENU" ) ]]; then
      menu_pending=1
    fi
  fi
  enable_devtools || true
  if reload_tccd; then
    c_ok "tccd reloaded - changes are live now (no reboot, no log-out)."
  else
    c_warn "tccd could not be restarted; the changes are saved but may not take effect until it restarts."
    GRANT_FAIL=1
  fi

  printf 'enabled=%s\nversion=%s\nbackup=%s\n' "$stamp" "$VERSION" "$bk" > "$F_ENABLED"

  echo ""
  hr
  if [[ "$GRANT_FAIL" == "1" ]]; then
    c_warn "Partially applied - see the warnings above. Re-running is safe."
  elif [[ "$PROFILE_PENDING" == "1" || ( -f "$F_AGENT" && "$AGENT_FDA_OK" != "1" ) || "$menu_pending" == "1" ]]; then
    c_ok "DEV MODE ACTIVE - core grants applied; finish the one-time actions below."
  else
    c_ok "DEV MODE ACTIVE - all requested grant passes succeeded."
  fi
  echo "   Persistence : user-level rows + replayd agent + notification profile"
  echo "   Restore     : bash off.sh --back"
  echo "   Diagnostics : bash off.sh --doctor"
  if [[ "$PROFILE_PENDING" == "1" ]]; then
    echo "   Action      : approve the notification profile in Device Management."
  fi
  if [[ "$SYS_DB_WRITABLE" != "1" ]]; then
    echo "   Limit       : system TCC rows need SIP off or an MDM PPPC profile."
  fi
  if [[ -f "$F_AGENT" && "$AGENT_FDA_OK" != "1" ]]; then
    echo "   Action      : give /bin/bash Full Disk Access, then run --refresh."
  fi
  if [[ -f "$F_AGENT" ]] && grep -q '^installed=0' "$F_AGENT" 2>/dev/null; then
    echo "   Action      : the daily replayd agent could not be loaded; re-run --refresh."
  fi
  if [[ "$menu_pending" == "1" ]]; then
    echo "   Action      : turn off Screen Share in System Settings > Control Center."
  fi
  hr
  echo ""
  if [[ "$GRANT_FAIL" == "1" ]]; then return 1; fi
  return 0
}

# =============================================================================
#  RESTORE
# =============================================================================
restore_tag() { # $1 = tag
  local tag="$1" db sqlfile
  db="$(db_file "$tag")"
  if [[ ! -f "$db" ]]; then
    c_warn "The $tag TCC database is missing; cannot restore its rows."
    return 1
  fi
  if ! detect_schema "$tag"; then return 1; fi
  local added="$STATE_DIR/.restore-added.$$.tsv"
  local pres="$STATE_DIR/.restore-pres.$$.tsv"
  local pkeys="$STATE_DIR/.restore-pkeys.$$.tsv"
  : > "$added"; : > "$pres"; : > "$pkeys"
  if [[ -f "$F_ADDED" ]]; then awk -F'\t' -v t="$tag" '$1==t' "$F_ADDED" > "$added"; fi
  if [[ -f "$F_PRESERVE" ]]; then awk -F'\t' -v t="$tag" '$1==t' "$F_PRESERVE" > "$pres"; fi
  # Every non-AppleEvents key with a preserved original must be cleared before
  # reinserting it.  Relying on INSERT OR REPLACE leaves our 'UNUSED' grant
  # behind when the original row used a different indirect-object spelling.
  awk -F'\t' 'NF>=4 && $2!="" && $2!="kTCCServiceAppleEvents" {print $1"\t"$2"\t"$3"\t"$4}' "$pres" \
    | LC_ALL=C sort -u > "$pkeys"

  sqlfile="$STATE_DIR/.restore.$$.sql"
  : > "$sqlfile"
  printf 'BEGIN IMMEDIATE;%s' "$NL" >> "$sqlfile"
  local svc client ctype ind
  while IFS=$'\t' read -r _tag svc client ctype ind; do
    [[ -n "$svc" ]] || continue
    if [[ "$svc" == "kTCCServiceAppleEvents" && "${ind:-UNUSED}" == "UNUSED" && "$HAS_IND_ID" == "1" ]]; then
      # v3 had no indirect-object column in its manifest.  Its AppleEvents
      # rows were written with UNUSED; deleting every AppleEvents row for
      # this client would also delete the user's real per-target rows that v3
      # never captured.  Remove only the bogus spellings.
      printf "DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s AND (indirect_object_identifier IS NULL OR indirect_object_identifier='' OR indirect_object_identifier='UNUSED');%s" \
        "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$NL" >> "$sqlfile"
    elif [[ "${ind:-UNUSED}" == "UNUSED" ]]; then
      # Non-AppleEvents rows may exist with NULL / '' / 'UNUSED' indirect ids.
      printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s;%s' \
        "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$NL" >> "$sqlfile"
    elif [[ "$HAS_IND_ID" == "1" ]]; then
      printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s AND indirect_object_identifier=%s;%s' \
        "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$(sql_q "$ind")" "$NL" >> "$sqlfile"
    else
      printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s;%s' \
        "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$NL" >> "$sqlfile"
    fi
  done < "$added"

  # Clear all spellings for preserved non-AppleEvents keys, even if they were
  # not in F_ADDED (for example a pre-existing row that the snapshot kept).
  while IFS=$'\t' read -r _tag svc client ctype; do
    [[ -n "$svc" ]] || continue
    printf 'DELETE FROM access WHERE service=%s AND client=%s AND client_type=%s;%s' \
      "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype" "$NL" >> "$sqlfile"
  done < "$pkeys"

  local authv reason ver csh flagsv indcode line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r _tag svc client ctype ind authv reason ver csh flagsv indcode <<< "$line"
    [[ -n "$svc" ]] || continue
    if [[ "$svc" == "kTCCServiceAppleEvents" && "${ind:-UNUSED}" == "UNUSED" ]]; then
      # Legacy v3 snapshot: the real automation target was never recorded.
      # Inserting an UNUSED row would create a bogus automation grant; the
      # real per-target rows were not touched by the delete above.
      continue
    fi
    [[ "$csh" == "-" ]] && csh=""
    [[ "$flagsv" == "-" ]] && flagsv=""
    [[ "$indcode" == "-" ]] && indcode=""
    insert_row_sql "$svc" "$client" "$ctype" "$csh" "${authv:-0}" "${reason:-4}" "${ver:-1}" "${flagsv:-}" "${ind:-UNUSED}" "${indcode:-}" >> "$sqlfile"
  done < "$pres"
  printf 'COMMIT;%s' "$NL" >> "$sqlfile"

  if ! run_sql_file "$tag" "$sqlfile"; then
    rm -f "$added" "$pres" "$pkeys" "$sqlfile"
    return 1
  fi
  rm -f "$added" "$pres" "$pkeys" "$sqlfile"
  c_ok "$tag TCC database restored."
  return 0
}

cmd_restore() {
  require_darwin
  require_user
  require_sqlite3
  macos_init
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  # Upgrade v3 manifests before any reader touches them.
  normalize_legacy_manifests
  local has_work=0
  local f
  for f in "$F_ENABLED" "$F_PROFILE" "$F_REPLAYD" "$F_AGENT" "$F_CC" "$F_MENU" "$F_NCPREFS" "$F_BTM" "$F_DEVTOOLS"; do
    [[ -f "$f" ]] && has_work=1
  done
  for f in "$F_ADDED" "$F_PRESERVE" "$F_TARGETS"; do
    [[ -s "$f" ]] && has_work=1
  done
  # A crash can leave a loaded agent before its state flag was written.
  # Treat it as work too, otherwise the daily job can survive --back.
  [[ -f "$AGENT_PLIST" ]] && has_work=1
  if [[ "$has_work" == "0" ]]; then
    c_info "Nothing to restore - already clean."
    exit 0
  fi
  local current_bk=""
  [[ -f "$STATE_DIR/backups/CURRENT" ]] && current_bk="$(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || true)"

  c_info "Admin password needed to restore the privacy databases."
  need_sudo

  c_step "[1/6] Probing TCC databases ..."
  if probe_sys_db; then
    c_ok "System TCC.db: writable."
  else
    c_warn "System TCC.db: $SYS_DB_STATE (system rows may not be removable)."
  fi
  if probe_user_db; then
    c_ok "User TCC.db: writable."
  else
    c_warn "User TCC.db: $USER_DB_STATE."
  fi

  local hard_fail=0

  c_step "[2/6] Removing background refresh agent ..."
  remove_replayd_agent || hard_fail=1

  c_step "[3/6] Removing notification profile ..."
  remove_btm_profile || hard_fail=1

  c_step "[4/6] Restoring screen-capture approvals ..."
  restore_replayd || hard_fail=1

  c_step "[5/6] Restoring TCC rows ..."
  if [[ "$SYS_DB_WRITABLE" == "1" ]]; then
    restore_tag sys || hard_fail=1
  elif [[ -s "$F_ADDED" ]] && awk -F'\t' '$1=="sys"' "$F_ADDED" | grep -q .; then
    c_warn "System TCC rows cannot be removed while SIP protects the database."
    hard_fail=1
  fi
  if [[ "$USER_DB_WRITABLE" == "1" ]]; then
    restore_tag user || hard_fail=1
  elif [[ -s "$F_ADDED" ]] && awk -F'\t' '$1=="user"' "$F_ADDED" | grep -q .; then
    c_warn "User TCC rows cannot be removed (Full Disk Access missing)."
    hard_fail=1
  fi

  c_step "[6/6] Restoring preferences, developer mode + reloading tccd ..."
  restore_control_center || hard_fail=1
  restore_systemuiserver || hard_fail=1
  restore_ncprefs || hard_fail=1
  restore_btm_agent_prefs || hard_fail=1
  restore_devtools || hard_fail=1
  if reload_tccd; then
    c_ok "tccd reloaded - normal privacy prompts are back."
  else
    c_warn "tccd could not be restarted; restored settings may not take effect until it restarts."
    hard_fail=1
  fi

  if [[ "$hard_fail" == "0" ]]; then
    rm -f "$F_ENABLED" "$F_ADDED" "$F_PRESERVE" "$F_TARGETS" "$F_REPLAYD" \
      "$F_PROFILE" "$F_NCPREFS" "$F_CC" "$F_AGENT" "$F_MENU" "$F_BTM" \
      "$F_DEVTOOLS" "$F_VERSION"
    # Start a fresh snapshot next time; full DB backups stay on disk.  The
    # fixed-path preference backups must also be dropped, otherwise a later
    # enable would restore an older snapshot than the one it took.
    rm -f "$STATE_DIR/backups/CURRENT" "$CC_BACKUP" "$SS_BACKUP" "$NCPREFS_BACKUP"
    c_ok "NORMAL MODE RESTORED - exactly the recorded prior state."
  else
    c_warn "Restore is incomplete; the manifests are kept so you can retry."
    echo "   Retry: bash off.sh --back"
  fi
  if [[ -n "$current_bk" ]]; then
    echo "   Full database backups remain in: $current_bk"
  else
    echo "   Full database backups remain in: $STATE_DIR/backups"
  fi
  echo ""
  [[ "$hard_fail" == "0" ]] && return 0 || return 1
}

# =============================================================================
#  ADD
# =============================================================================
cmd_add() {
  require_darwin
  require_user
  require_sqlite3
  macos_init
  local paths=("$@")
  if [[ "${#paths[@]}" -eq 0 ]]; then
    die "Usage: bash off.sh --add /path/to/binary [more paths or .app bundles ...]"
  fi
  need_sudo
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  normalize_legacy_manifests
  establish_added_baseline

  local p rp id accepted=0
  for p in ${paths[@]+"${paths[@]}"}; do
    if [[ -d "$p" && -f "$p/Contents/Info.plist" ]]; then
      id="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$p/Contents/Info.plist" 2>/dev/null || true)"
      rp="$(resolve_path "$p")"
      [[ "$rp" == /* ]] || rp="$PWD/$p"
      if [[ -n "$id" ]]; then
        mkdir -p "$(dirname "$EXTRA_APPS_FILE")"
        printf '%s\n' "$rp" >> "$EXTRA_APPS_FILE"
        c_ok "App accepted: $id ($rp)"
        accepted=1
      else
        c_warn "No CFBundleIdentifier in $p - skipped."
      fi
      continue
    fi
    if [[ -f "$p" ]]; then
      rp="$(resolve_path "$p")"
      [[ "$rp" == /* ]] || rp="$PWD/$p"
      [[ -f "$rp" ]] || { c_warn "Not a regular file: $p"; continue; }
      mkdir -p "$(dirname "$EXTRA_PATHS_FILE")"
      printf '%s\n' "$rp" >> "$EXTRA_PATHS_FILE"
      c_ok "Binary accepted: $rp"
      accepted=1
    else
      c_warn "Not found or not a regular file/app bundle: $p"
    fi
  done
  if [[ "$accepted" == "0" ]]; then
    die "Nothing to add."
  fi
  if [[ -f "$EXTRA_PATHS_FILE" ]]; then
    LC_ALL=C sort -u "$EXTRA_PATHS_FILE" > "$EXTRA_PATHS_FILE.tmp" 2>/dev/null \
      && mv "$EXTRA_PATHS_FILE.tmp" "$EXTRA_PATHS_FILE" || true
  fi
  if [[ -f "$EXTRA_APPS_FILE" ]]; then
    LC_ALL=C sort -u "$EXTRA_APPS_FILE" > "$EXTRA_APPS_FILE.tmp" 2>/dev/null \
      && mv "$EXTRA_APPS_FILE.tmp" "$EXTRA_APPS_FILE" || true
  fi

  if probe_sys_db; then :; fi
  if probe_user_db; then :; fi

  # Take the original snapshot before the first write, exactly like enable.
  local stamp bk have_current=0 cur_bk=""
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo 0)"
  bk="$STATE_DIR/backups/$stamp"
  if [[ -f "$STATE_DIR/backups/CURRENT" ]]; then
    cur_bk="$(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || true)"
    if [[ -n "$cur_bk" && -d "$cur_bk" ]]; then
      bk="$cur_bk"; have_current=1
    fi
  fi
  mkdir -p "$STATE_DIR/backups"
  do_backups "$bk"
  if [[ "$have_current" == "0" ]]; then
    printf '%s\n' "$bk" > "$STATE_DIR/backups/CURRENT"
  fi

  # Re-collect so an added .app also contributes its helper bundles/executables.
  collect_cli_paths
  collect_apps
  collect_ae_targets
  local pf="$STATE_DIR/.add-paths.$$.tmp" bf="$STATE_DIR/.add-bundles.$$.tmp"
  printf '%s\n' ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} > "$pf"
  printf '%s\n' ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"} > "$bf"

  local fail=0
  if [[ "$SYS_DB_WRITABLE" == "1" ]]; then
    if grant_targets sys "$pf" "$bf"; then c_ok "System db: $GRANT_COUNT/$GRANT_EXPECTED rows present."; else fail=1; fi
  else
    c_warn "System db not writable; system-level rows not added."
    fail=1
  fi
  if [[ "$USER_DB_WRITABLE" == "1" ]]; then
    if grant_targets user "$pf" "$bf"; then c_ok "User db: $GRANT_COUNT/$GRANT_EXPECTED rows present."; else fail=1; fi
  else
    c_warn "User db not writable; user-level rows not added."
    fail=1
  fi
  rm -f "$pf" "$bf"

  if macos_at_least 15 0; then
    if ! apply_replayd; then
      c_warn "Could not extend screen-recording approvals for the added item."
      fail=1
    fi
  fi
  if ! reload_tccd; then
    c_warn "tccd could not be restarted; the added rows may not take effect yet."
    fail=1
  fi
  if [[ "$fail" == "0" ]]; then
    c_ok "Added. 'bash off.sh --back' removes these rows too."
    return 0
  fi
  return 1
}

# =============================================================================
#  STATUS / DOCTOR
# =============================================================================
count_our_rows() { # $1 = tag
  local tag="$1" n="" inlist="" qf="$STATE_DIR/.count.$$.sql"
  [[ -f "$F_TARGETS" ]] || { echo 0; return 0; }
  if ! detect_schema "$tag" 2>/dev/null; then echo "?"; return 0; fi
  : > "$qf"
  if [[ "$HAS_IND_ID" == "1" ]]; then
    inlist="$(awk -F'\t' -v t="$tag" '$1==t{print $2"\t"$3"\t"$4"\t"($5==""?"UNUSED":$5)}' "$F_TARGETS" | in_values_list)"
    [[ -n "$inlist" ]] || { rm -f "$qf"; echo 0; return 0; }
    printf 'SELECT count(*) FROM access WHERE (service, client, client_type, indirect_object_identifier) IN (%s);\n' "$inlist" > "$qf"
  else
    inlist="$(awk -F'\t' -v t="$tag" '$1==t{print $2"\t"$3"\t"$4}' "$F_TARGETS" | in_values_list_noind)"
    [[ -n "$inlist" ]] || { rm -f "$qf"; echo 0; return 0; }
    printf 'SELECT count(*) FROM access WHERE (service, client, client_type) IN (%s);\n' "$inlist" > "$qf"
  fi
  n="$(sql_query_file "$tag" "$qf" 2>/dev/null || echo '?')"
  rm -f "$qf"
  echo "${n:-?}"
}

agent_loaded() {
  /bin/launchctl list "$AGENT_LABEL" >/dev/null 2>&1
}

cmd_status() {
  require_darwin
  require_user
  macos_init
  echo ""
  hr
  echo "  off.sh STATUS"
  hr
  if [[ -f "$F_ENABLED" ]]; then
    echo "  Mode      : DEV MODE ACTIVE"
    sed -n 's/^enabled=/  Since     : /p;s/^version=/  Version   : /p;s/^backup=/  Backup    : /p' "$F_ENABLED" | head -3
  else
    echo "  Mode      : normal (not active)"
  fi
  echo "  macOS     : $(macos_version) (SIP: $([[ "$SIP_ENABLED" == "1" ]] && echo enabled || { [[ "$SIP_DISABLED" == "1" ]] && echo disabled || echo unknown; }))"
  echo "  Rows added: $(line_count "$F_ADDED")   Preserved: $(line_count "$F_PRESERVE")"
  if sudo -n true >/dev/null 2>&1; then
    if probe_sys_db; then echo "  System db : WRITABLE ($(count_our_rows sys) of our rows present)"; else echo "  System db : $SYS_DB_STATE"; fi
    if probe_user_db; then echo "  User db   : WRITABLE ($(count_our_rows user) of our rows present)"; else echo "  User db   : $USER_DB_STATE"; fi
  else
    echo "  Databases : run 'bash off.sh --doctor' (needs sudo) for exact state"
  fi
  if agent_loaded; then echo "  Agent     : loaded"; else echo "  Agent     : not loaded"; fi
  if profile_installed; then echo "  BTM profile: installed"; elif [[ -f "$F_PROFILE" ]]; then echo "  BTM profile: $(sed -n 's/^installed=//p' "$F_PROFILE")"; else echo "  BTM profile: not installed"; fi
  if [[ -f "$REPLAYD_PLIST" ]]; then
    echo "  replayd   : $(replayd_key_list 2>/dev/null | grep -c . || true) keys"
  else
    echo "  replayd   : approvals plist not present"
  fi
  if [[ -f "$F_CC" ]]; then
    echo "  Menu extra: Control Center modified ($(line_count "$F_CC") keys)"
  elif [[ -f "$F_MENU" ]]; then
    echo "  Menu extra: SystemUIServer modified"
  else
    echo "  Menu extra: not modified by off.sh"
  fi
  if [[ -f "$F_BTM" ]]; then echo "  BTM prefs : modified"; else echo "  BTM prefs : not modified"; fi
  if [[ -f "$F_DEVTOOLS" ]]; then echo "  DevTools  : enabled by off.sh"; else echo "  DevTools  : not changed"; fi
  echo ""
  return 0
}

cmd_doctor() {
  require_darwin
  require_user
  macos_init
  echo ""
  hr
  echo "  off.sh DOCTOR"
  hr
  echo "  macOS          : $(sw_vers -productName 2>/dev/null || echo macOS) $(macos_version)"
  echo "  SIP            : $([[ "$SIP_ENABLED" == "1" ]] && echo enabled || { [[ "$SIP_DISABLED" == "1" ]] && echo disabled || echo unknown; })"
  echo "  Virtual machine: $([[ "$IS_VM" == "1" ]] && echo yes || echo no/unknown)"
  echo "  Terminal       : $(terminal_name)  (${TERM_PROGRAM:-unknown})"
  echo "  Bash           : $BASH_VERSION"
  echo "  sqlite3        : $(sqlite3 --version 2>/dev/null | cut -d' ' -f1 || echo missing)"
  echo "  csreq          : ${CSREQ_BIN:-MISSING}"
  echo "  python3        : ${PYTHON_BIN:-MISSING}"

  collect_cli_paths
  collect_apps
  collect_ae_targets
  echo "  Dev binaries   : ${#CLI_PATHS[@]}"
  local c
  for c in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do echo "      $c"; done
  echo "  Dev apps       : ${#APP_BUNDLES[@]}"
  for c in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do echo "      $c"; done
  echo "  Extra paths    : $(line_count "$EXTRA_PATHS_FILE")"
  echo "  Extra apps     : $(line_count "$EXTRA_APPS_FILE")"

  echo ""
  echo "  Database access (real write probes):"
  need_sudo
  if probe_sys_db; then
    echo "    system TCC.db : WRITABLE"
  else
    echo "    system TCC.db : $SYS_DB_STATE"
    [[ "$SYS_DB_STATE" == "readonly" && "$SIP_ENABLED" == "1" ]] && sip_hint
    [[ "$SYS_DB_STATE" == "blocked" ]] && fda_hint "The terminal cannot read the system database."
  fi
  if ! [[ -f "$USER_TCC" ]]; then
    echo "    user TCC.db   : MISSING (created by macOS at the first mic/camera prompt)"
  elif probe_user_db; then
    echo "    user TCC.db   : WRITABLE ($USER_DB_STATE)"
  else
    echo "    user TCC.db   : $USER_DB_STATE"
    fda_hint "The terminal cannot write the user privacy database."
  fi

  echo ""
  echo "  replayd:"
  if [[ -f "$REPLAYD_PLIST" ]]; then
    echo "    plist         : $REPLAYD_PLIST"
    echo "    format        : $(macos_at_least 15 1 && echo dict || echo date)"
    local k; k="$(replayd_key_list 2>/dev/null | grep -c . || true)"
    echo "    keys          : ${k:-0}"
    if /usr/bin/plutil -convert xml1 -o - "$REPLAYD_PLIST" 2>/dev/null | grep -q 'kScreenCaptureApprovalLastAlerted'; then
      echo "    last alerted  : present"
    else
      echo "    last alerted  : MISSING (nag will recur)"
    fi
  else
    echo "    plist         : not present"
  fi

  echo ""
  echo "  Background refresh agent:"
  if [[ -f "$AGENT_PLIST" ]]; then
    echo "    plist         : $AGENT_PLIST"
    if agent_loaded; then echo "    loaded        : yes"; else echo "    loaded        : NO"; fi
    if [[ -f "$AGENT_LOG" ]]; then echo "    last log      : $(tail -3 "$AGENT_LOG" 2>/dev/null | tr '\n' ' ' || true)"; fi
  else
    echo "    plist         : not installed"
  fi
  if detect_schema sys 2>/dev/null; then
    local bashfda; bashfda="$(sql_tag sys "SELECT count(*) FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client='/bin/bash' AND client_type=1 AND auth_value=2;" 2>/dev/null || echo '?')"
    echo "    /bin/bash FDA : ${bashfda:-?}"
  fi

  echo ""
  echo "  BTM notifications:"
  if profile_installed; then echo "    profile       : installed"; else echo "    profile       : not installed"; fi
  if [[ -f "$F_PROFILE" ]]; then echo "    state         : $(cat "$F_PROFILE" 2>/dev/null || true)"; fi
  if [[ -f "$NCPREFS" ]]; then echo "    ncprefs       : present"; else echo "    ncprefs       : missing"; fi
  local btm_notify btm_added
  btm_notify="$("$DEFAULTS_BIN" read "$BTM_AGENT_DOMAIN" notificationsEnabled 2>/dev/null || echo unset)"
  btm_added="$("$DEFAULTS_BIN" read "$BTM_AGENT_DOMAIN" BackgroundItemsAddedNotificationsEnabled 2>/dev/null || echo unset)"
  echo "    agent notify  : $btm_notify (BackgroundItemsAdded=$btm_added)"
  if [[ -f "$F_BTM" ]]; then echo "    off.sh state  : modified"; else echo "    off.sh state  : not modified"; fi

  echo ""
  echo "  Sharing / menu bar:"
  if screen_sharing_enabled; then echo "    Screen Sharing: ON (remote access; purple service extra may be present)"; else echo "    Screen Sharing: off/unknown"; fi
  if [[ -f "$F_CC" ]]; then echo "    Control Center keys changed: $(line_count "$F_CC")"; else echo "    Control Center keys changed: 0"; fi
  if [[ -f "$F_MENU" ]]; then echo "    SystemUIServer extras changed: yes"; else echo "    SystemUIServer extras changed: no"; fi
  echo "    NOTE: the purple screen-recording privacy indicator is an Apple"
  echo "          security indicator; it cannot be hidden by a script while"
  echo "          an app is capturing the screen.  The Screen Sharing service"
  echo "          extra can be hidden in System Settings > Control Center."

  echo ""
  if [[ -x /usr/sbin/DevToolsSecurity ]]; then
    echo "    DevToolsSecurity: $(/usr/sbin/DevToolsSecurity -status 2>/dev/null || echo unknown)"
  fi
  echo ""
  echo "  Notes:"
  echo "    - The notification profile must be approved once in"
  echo "      System Settings > General > Device Management if it is pending."
  echo "    - On SIP-enabled Macs, system TCC rows (screen, accessibility,"
  echo "      input monitoring, FDA) cannot be written.  That is an Apple"
  echo "      boundary, not a script bug."
  echo ""
  return 0
}

# =============================================================================
#  Refresh
# =============================================================================
cmd_refresh() {
  cmd_enable "$@"
}

# =============================================================================
#  USAGE / MAIN
# =============================================================================
usage() {
  cat <<'USAGE'
off.sh v4.0 - silence macOS TCC pop-ups and background-item notices for dev

Usage:
  bash off.sh                  enable  (explain -> sudo -> confirm -> apply)
  bash off.sh --back           restore exactly what was changed
  bash off.sh --add PATH ...   pre-approve another binary or .app bundle
  bash off.sh --status         show current state
  bash off.sh --doctor         deep environment / permission diagnostics
  bash off.sh --refresh        re-sync grants and replayd dates
  bash off.sh --yes            non-interactive final confirmation
  bash off.sh --no-profile     do not install the BTM notification profile
  bash off.sh --no-agent       do not install the daily replayd agent
  bash off.sh --no-menu        do not touch Control Center menu-extra keys
  bash off.sh --debug          print SQL / decisions (OFF_DEBUG=1)
  bash off.sh --help

What is covered:
  - TCC grants for node, npm/npx, python, uv, deno, bun, Electron and the
    terminal/IDE apps that launch them: screen capture, mic, camera, full
    disk, accessibility, input monitoring, automation, local network,
    Bluetooth, folders and related services.
  - macOS 15.1+ replayd screen-recording nag: per-app dictionary dates plus a
    daily LaunchAgent that keeps them in the future.
  - "App Background Activity" / "Background Items Added": one-time
    com.apple.notificationsettings profile.
  - Screen Sharing menu extra: hidden when a Control Center preference exists.

Known Apple limits (reported honestly):
  - The purple screen-recording privacy indicator cannot be hidden by a
    userspace script while an app is capturing the screen.
  - With SIP enabled, the SYSTEM TCC database is read-only even for root;
    Full Disk Access does not override SIP.  The script detects this and
    never claims those grants succeeded.
  - The BTM notification profile needs one approval in Device Management.

State: ~/.tcc-devtool (backups, manifests, extra paths/apps).
USAGE
}

MODE="enable"
ADD_PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --back|--restore) MODE="restore" ;;
    --status)          MODE="status" ;;
    --doctor)          MODE="doctor" ;;
    --refresh)         MODE="enable" ;;
    --add)
      MODE="add"; shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes|-y) ASSUME_YES=1; shift ;;
          --debug) DEBUG=1; shift ;;
          --no-profile) SKIP_PROFILE=1; shift ;;
          --no-agent) SKIP_AGENT=1; shift ;;
          --no-menu) SKIP_MENU=1; shift ;;
          --help|-h) usage; exit 0 ;;
          --) shift; while [[ $# -gt 0 ]]; do ADD_PATHS+=("$1"); shift; done ;;
          -*) echo "Unknown argument: $1" >&2; exit 1 ;;
          *) ADD_PATHS+=("$1"); shift ;;
        esac
      done
      break ;;
    --yes|-y)          ASSUME_YES=1 ;;
    --debug)           DEBUG=1 ;;
    --no-profile)      SKIP_PROFILE=1 ;;
    --no-agent)        SKIP_AGENT=1 ;;
    --no-menu)         SKIP_MENU=1 ;;
    --help|-h)         usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Try: bash off.sh --help" >&2
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
    if [[ "${#ADD_PATHS[@]}" -gt 0 ]]; then cmd_add "${ADD_PATHS[@]}"; else cmd_add; fi ;;
esac
