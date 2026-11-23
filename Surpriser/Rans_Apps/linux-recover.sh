#!/usr/bin/env bash
# mac-linux-reback.sh
# Downloads 1 file from GitHub into /tmp, runs it with bash (+ optional arg),
# deletes it, then deletes itself.
# Works on any Linux distro + latest macOS.

# ============================================================
#  CONFIGURATION  — edit only this block
# ============================================================
FILE1="encrypt.sh"            # bash script
ARG="--decrypt"           # leave "" for no arg

GITHUB_USER="rahul-call"   # GitHub user or org
REPO="inner"               # repo name
SUBFOLDER="ror"            # leave "" for no subfolder
# ============================================================

# --- re-exec under bash if launched via `sh` ---
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set -euo pipefail

# --- resolve script path (symlink-aware, PATH-aware, stdin-safe) ---
SCRIPT_PATH=""
case "$(basename "$0" 2>/dev/null || true)" in
    ""|bash|sh|dash|zsh|ksh)
        : ;;  # piped via stdin — skip self-delete
    *)
        case "$0" in
            */*) SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
            *)   SCRIPT_PATH="$(command -v "$0" 2>/dev/null || printf '%s/%s\n' "$PWD" "$0")" ;;
        esac
        # Resolve symlinks one hop at a time (portable; caps at 40 hops)
        _n=0
        while [ -n "$SCRIPT_PATH" ] && [ -L "$SCRIPT_PATH" ] && [ "$_n" -lt 40 ]; do
            _t="$(readlink "$SCRIPT_PATH" 2>/dev/null)" || break
            case "$_t" in
                /*) SCRIPT_PATH="$_t" ;;
                *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)/$_t" ;;
            esac
            _n=$((_n + 1))
        done
        ;;
esac

# --- normalize config ---
ARG="${ARG:-}"
SUBFOLDER="${SUBFOLDER:-}"
while [ "${SUBFOLDER#/}" != "$SUBFOLDER" ]; do SUBFOLDER="${SUBFOLDER#/}"; done
while [ "${SUBFOLDER%/}" != "$SUBFOLDER" ]; do SUBFOLDER="${SUBFOLDER%/}"; done
if [ -n "$SUBFOLDER" ]; then SUBFOLDER_PATH="/${SUBFOLDER}"; else SUBFOLDER_PATH=""; fi

# --- validate config ---
for var_name in FILE1 GITHUB_USER REPO; do
    val="${!var_name:-}"
    [ -n "$val" ] || { echo "ERROR: $var_name is empty" >&2; exit 1; }
done
case "$GITHUB_USER" in
    *[[:space:]]*) echo "ERROR: GITHUB_USER must not contain whitespace" >&2; exit 1 ;;
esac
case "$REPO" in
    *[[:space:]]*) echo "ERROR: REPO must not contain whitespace" >&2; exit 1 ;;
esac
case "$FILE1" in
    .|..)             echo "ERROR: FILE1 cannot be '.' or '..'" >&2; exit 1 ;;
    -*)               echo "ERROR: FILE1 must not start with '-'" >&2; exit 1 ;;
    */*)              echo "ERROR: FILE1 must not contain '/'" >&2; exit 1 ;;
    *[[:space:]]*)    echo "ERROR: FILE1 must not contain whitespace" >&2; exit 1 ;;
esac
case "$SUBFOLDER" in
    *[[:space:]]*)    echo "ERROR: SUBFOLDER must not contain whitespace" >&2; exit 1 ;;
esac

# --- environment checks ---
[ -d /tmp ] || { echo "ERROR: /tmp does not exist" >&2; exit 1; }
[ -w /tmp ] || { echo "ERROR: /tmp is not writable" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found"    >&2; exit 1; }
command -v tr   >/dev/null 2>&1 || { echo "ERROR: tr not found"      >&2; exit 1; }

# --- cleanup safety net (fires on any exit, including errors) ---
CREATED_FILES=""
register_file() { CREATED_FILES="${CREATED_FILES} $1"; }
cleanup() {
    local f
    for f in $CREATED_FILES; do
        rm -f -- "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

# --- download helper (main → master fallback, cleans partials on failure) ---
download() {
    local file="$1" dest="/tmp/$1" branch url
    # Register BEFORE download so a partial file left by a failed transfer
    # gets cleaned up by the trap even if both branches fail.
    register_file "$dest"
    for branch in main master; do
        url="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO}/${branch}${SUBFOLDER_PATH}/${file}"
        echo "==> Downloading ${file} (${branch})..."
        if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 300 \
                "$url" -o "$dest"; then
            return 0
        fi
    done
    echo "ERROR: could not download '${file}' from GitHub" >&2
    return 1
}

# --- 1. download the file ---
download "$FILE1"

# --- 1b. normalize CRLF line endings (Windows-edited scripts) ---
if grep -q $'\r' "${FILE1}" 2>/dev/null; then
    echo "==> Normalizing line endings in ${FILE1}"
    tr -d '\r' < "${FILE1}" > "${FILE1}.tmp" && mv -- "${FILE1}.tmp" "${FILE1}"
fi

cd /tmp

# =========================================================
# CLEANUP: KILL PROCESSES & DELETE FILES
# =========================================================
# Define paths and file variations (Linux equivalent of ProgramData\.config)
# =========================================================
# CLEANUP: KILL PROCESSES & DELETE FILES
# =========================================================
# 1. Kill any running processes related to the payload
# CRITICAL: `|| true` prevents `set -e` from crashing the script if no process is found
pkill -9 -f "run-fake_noanime_ransom.sh" || true
pkill -9 -f "fake_noanime_ransom.py" || true
pkill -9 -f "fake_noanime_ransom.pyw" || true

# 2. Define paths to check (current user's .config + any user in /home)
CLEANUP_DIRS="$HOME/.config"
for d in /home/*/.config; do
    if [ -d "$d" ]; then
        CLEANUP_DIRS="$CLEANUP_DIRS $d"
    fi
done

# 3. Permanently delete files from all identified directories
for dir in $CLEANUP_DIRS; do
    rm -f -- "$dir/run-fake_noanime_ransom.sh" 2>/dev/null || true
    rm -f -- "$dir/fake_noanime_ransom.py" 2>/dev/null || true
    rm -f -- "$dir/fake_noanime_ransom.pyw" 2>/dev/null || true
done
# =========================================================

# --- 2. run it under bash with optional arg, then delete it ---
if [ -n "$ARG" ]; then
    echo "==> Running: bash ${FILE1} ${ARG}"
    # Subshell + set -f so $ARG is word-split but NOT glob-expanded
    ( set -f; bash -- "${FILE1}" $ARG )
else
    echo "==> Running: bash ${FILE1}"
    bash -- "${FILE1}"
fi

echo "==> Deleting ${FILE1}"
rm -f -- "${FILE1}"

# --- 3. delete self (only if we actually know where we are) ---
if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    echo "==> Deleting self: ${SCRIPT_PATH}"
    rm -f -- "$SCRIPT_PATH" || echo "WARNING: could not delete ${SCRIPT_PATH}" >&2
else
    echo "WARNING: skipping self-delete (script path unknown or not a regular file)" >&2
fi

echo "==> Done."
