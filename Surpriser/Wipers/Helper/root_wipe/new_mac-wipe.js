#!/usr/bin/env node
/**
 * wipe-mac.js — best-effort logical sanitizer for macOS (Tahoe 26+ / Sequoia).
 *
 * HONEST LIMITATIONS:
 *  • On Apple Silicon and T2 Macs, internal APFS volumes are always encrypted.
 *    Overwriting the mounted filesystem does NOT guarantee NAND erasure.
 *    The only reliable method is FileVault key destruction via
 *    Erase All Content and Settings or Recovery Mode eraseDisk.
 *  • On SSDs, diskutil secureErase is deprecated and may fail or be ignored.
 *    It is attempted only on rotational HDDs, and failures are logged.
 *  • Even as root, macOS TCC blocks ~/Library/Keychains, ~/Library/Safari,
 *    ~/Library/Messages, etc. without Full Disk Access. Grant FDA to Terminal
 *    before running. Failures are logged, not hidden.
 *  • Time Machine local snapshots are deleted before file deletion; otherwise
 *    deleted files remain recoverable from the snapshot.
 *  • Immutable flags (uchg/schg) are cleared recursively before deletion.
 */

const { spawn } = require('child_process');
const os = require('os');
const fs = require('fs');
const readline = require('readline');

const CONFIRM_PHRASE = 'DELETE EVERYTHING';

async function main() {
    if (os.platform() !== 'darwin') {
        console.error('This script is macOS-only.');
        process.exit(1);
    }
    if (process.getuid() !== 0) {
        console.error('Must run as root: sudo node wipe-mac.js');
        process.exit(1);
    }

    console.log('\x1b[91m!!! WARNING !!!\x1b[0m');
    console.log('This will PERMANENTLY destroy all user data in /Users and');
    console.log('best-effort wipe other writable volumes under /Volumes.');
    console.log('\x1b[91mTHIS IS IRREVERSIBLE.\x1b[0m');
    console.log('');
    console.log('Limitations you MUST understand:');
    console.log('  • On Apple Silicon/T2, the disk is always encrypted. Overwriting');
    console.log('    the mounted filesystem does NOT guarantee erasure. True erasure');
    console.log('    requires FileVault key destruction via Erase All Content and');
    console.log('    Settings or Recovery Mode eraseDisk.');
    console.log('  • Even as root, TCC blocks ~/Library/Keychains, ~/Library/Safari,');
    console.log('    etc. unless Terminal has Full Disk Access.');
    console.log('  • Time Machine local snapshots are deleted first; failures are');
    console.log('    logged to /tmp/wipe-mac-*.log.');
    console.log('');
    console.log(`Type exactly: ${CONFIRM_PHRASE} (case-sensitive) and press Enter:`);

    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const answer = await new Promise(resolve => rl.question('', resolve));
    rl.close();

    if (answer.trim() !== CONFIRM_PHRASE) {
        console.log('Aborted (phrase did not match exactly). Nothing was touched.');
        process.exit(0);
    }

    // -----------------------------------------------------------------
    // Bash script — runs detached, logs to /tmp/wipe-mac-<timestamp>.log
    // -----------------------------------------------------------------
    const bashScript = `
#!/bin/bash
export LC_ALL=C
set -uo pipefail
LOG="/tmp/wipe-mac-$(date +%s).log"
exec > >(tee -a "$LOG") 2>&1
echo "[START] $(date)"
if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] Not root. Exiting."
  exit 1
fi

# --- 0. Clear immutable flags recursively ---
echo "[STEP] Clearing immutable flags (uchg/schg) on /Users..."
chflags -R nouchg noschg /Users 2>&1 || echo "[WARN] chflags failed for some paths (TCC or SIP may block)"

# --- 1. Delete local Time Machine snapshots ---
echo "[STEP] Deleting local Time Machine snapshots..."
tmutil thinlocalsnapshots / 999999999999999 4 2>&1 || echo "[WARN] tmutil thinlocalsnapshots failed"
for snap in $(tmutil listlocalsnapshots / 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-'); do
  tmutil deletelocalsnapshots "$snap" 2>&1 || true
done

# --- 2. Delete contents of /Users ---
echo "[STEP] Deleting contents of /Users..."
find /Users -mindepth 1 -delete 2>&1 | while IFS= read -r line; do
  echo "[FIND] $line"
done

# --- 3. Verify no regular files remain ---
REMAINING=$(find /Users -type f 2>/dev/null | head -n 20)
if [[ -n "$REMAINING" ]]; then
  echo "[WARN] Regular files still present (TCC/immutable/In-use):"
  echo "$REMAINING"
fi

# --- 4. Secure erase free space — ONLY on HDD ---
DISK_INFO=$(diskutil info / 2>/dev/null)
if echo "$DISK_INFO" | grep -q "Solid State: Yes"; then
  echo "[SKIP] Internal disk is SSD; diskutil secureErase freespace is ineffective/unsupported on APFS/SSD."
else
  echo "[STEP] HDD detected; attempting secureErase freespace..."
  diskutil secureErase freespace 1 / < /dev/null 2>&1 || echo "[WARN] diskutil secureErase freespace failed on /"
fi

# --- 5. Best-effort external volumes under /Volumes ---
for vol in /Volumes/*; do
  [[ -d "$vol" ]] || continue
  [[ "$vol" = "/Volumes/Macintosh HD" ]] && continue
  [[ "$vol" = "/Volumes/Macintosh HD - Data" ]] && continue
  if [[ -d "$vol/Backups.backupdb" ]] || [[ -d "$vol/.TimeMachine" ]]; then
    echo "[SKIP] $vol looks like a Time Machine volume; not wiping."
    continue
  fi
  if [[ -w "$vol" ]]; then
    echo "[STEP] Wiping external volume: $vol"
    find "$vol" -mindepth 1 -delete 2>&1 | while IFS= read -r line; do
      echo "[VOL $vol] $line"
    done
    VOL_INFO=$(diskutil info "$vol" 2>/dev/null)
    if echo "$VOL_INFO" | grep -q "Solid State: No"; then
      diskutil secureErase freespace 1 "$vol" < /dev/null 2>&1 || echo "[WARN] secureErase freespace failed on $vol"
    fi
  else
    echo "[SKIP] $vol not writable"
  fi
done

# --- 6. Purge disk caches ---
if command -v purge >/dev/null 2>&1; then
  echo "[STEP] Purging disk caches..."
  purge 2>&1 || echo "[WARN] purge failed"
fi

# --- 7. FileVault status (informational) ---
FV=$(fdesetup status 2>&1)
echo "[INFO] FileVault status: $FV"
echo "[IMPORTANT] For guaranteed secure erasure on Apple Silicon/T2, use Erase All Content and Settings (System Settings → General → Transfer or Reset) or Recovery Mode eraseDisk. A userspace script cannot destroy the Secure Enclave keys."

echo "[DONE] $(date)"
`;

    // -----------------------------------------------------------------
    // Spawn detached; stdin from /dev/null prevents hangs
    // -----------------------------------------------------------------
    const child = spawn('bash', ['-c', bashScript], {
        detached: true,
        stdio: 'ignore'   // child redirects its own output to the log file
    });
    child.unref();

    // Best-effort self-deletion
    try {
        fs.unlinkSync(__filename);
    } catch (e) {
        // Page cache may retain a copy; this is best-effort only.
    }

    console.log('\nWipe started in background.');
    console.log('Check /tmp/wipe-mac-*.log for results and failures.');
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
