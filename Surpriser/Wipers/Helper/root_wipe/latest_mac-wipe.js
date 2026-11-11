#!/usr/bin/env node
/**
 * wipe-mac.js — best-effort logical sanitizer for macOS Tahoe 26+ / Sequoia.
 *
 * HONEST LIMITATIONS (read before running):
 *  • On Apple Silicon and T2 Macs, the internal SSD is ALWAYS encrypted.
 *    Overwriting the mounted filesystem does NOT guarantee NAND erasure.
 *    The ONLY reliable method is key destruction via Erase All Content and
 *    Settings or Recovery Mode: diskutil eraseDisk APFS "Macintosh HD" GPT /dev/disk0
 *  • TCC blocks ~/Library/Keychains, ~/Library/Safari, ~/Library/Messages,
 *    ~/Desktop, ~/Documents EVEN FOR ROOT. Terminal MUST have Full Disk Access.
 *  • diskutil secureErase is deprecated and unsafe on SSDs; it is attempted
 *    ONLY on rotational HDDs, and failures are logged.
 *  • APFS local snapshots retain deleted files for 24+ hours; they are deleted
 *    BEFORE file deletion, and failures are logged.
 *  • This script runs as root. It disables core dumps, sanitizes PATH,
 *    logs every failure to /tmp/wipe-mac-<timestamp>.log, and refuses to run
 *    without an explicit confirmation phrase.
 */

const { spawn, execSync } = require('child_process');
const os = require('os');
const fs = require('fs');
const readline = require('readline');
const path = require('path');

const CONFIRM_PHRASE = 'DELETE EVERYTHING';
const TARGET_DIR = '/Users';
const LOG_PREFIX = '/tmp/wipe-mac-';

function fatal(msg) {
  console.error(`\x1b[91m[FATAL]\x1b[0m ${msg}`);
  process.exit(1);
}

function warn(msg) {
  console.warn(`\x1b[93m[WARN]\x1b[0m ${msg}`);
}

async function confirm() {
  console.log('\x1b[91m!!! WARNING !!!\x1b[0m');
  console.log(`This will PERMANENTLY destroy all user data in ${TARGET_DIR} and`);
  console.log('best-effort wipe other writable volumes under /Volumes.');
  console.log('\x1b[91mTHIS IS IRREVERSIBLE.\x1b[0m');
  console.log('');
  console.log('Limitations you MUST understand:');
  console.log('  • Apple Silicon/T2: disk is ALWAYS encrypted. True erasure requires');
  console.log('    key destruction via Erase All Content and Settings or Recovery');
  console.log('    Mode eraseDisk. A userspace script CANNOT do this.');
  console.log('  • TCC blocks Keychains/Safari/Messages even for root. Terminal MUST');
  console.log('    have Full Disk Access (System Settings → Privacy & Security).');
  console.log('  • APFS local snapshots are deleted first; if deletion fails, files');
  console.log('    remain recoverable from the snapshot.');
  console.log('  • diskutil secureErase is deprecated on SSDs; it is attempted ONLY');
  console.log('    on rotational HDDs.');
  console.log('  • Cloud copies (iCloud Drive, iCloud Photos) are OUTSIDE this wipe.');
  console.log('');
  console.log(`Type exactly: ${CONFIRM_PHRASE} (case-sensitive) and press Enter:`);

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise(resolve => rl.question('', resolve));
  rl.close();

  if (answer.trim() !== CONFIRM_PHRASE) {
    console.log('Aborted (phrase did not match exactly). Nothing was touched.');
    process.exit(0);
  }
}

function preflight() {
  if (os.platform() !== 'darwin') fatal('This script is macOS-only.');
  if (process.getuid() !== 0) fatal('Must run as root: sudo node wipe-mac.js');

  // Disable core dumps so a crash doesn't leak sensitive paths
  try {
    process.setrlimit?.('core', 0, 0);
  } catch (_) { /* best-effort */ }

  // Sanitize PATH to prevent hijacking of find/chflags/tmutil/diskutil
  const safePath = ['/usr/bin', '/bin', '/usr/sbin', '/sbin'].filter(p => fs.existsSync(p)).join(':');
  process.env.PATH = safePath;
  process.env.LC_ALL = 'C';

  // Warn if Terminal lacks Full Disk Access — check a TCC-protected path
  const tccTest = path.join(os.homedir(), 'Library/Keychains');
  try {
    fs.readdirSync(tccTest);
  } catch (e) {
    if (e.code === 'EPERM' || e.code === 'EACCES') {
      warn('Terminal does NOT have Full Disk Access. Keychains, Safari, Messages,');
      warn('Desktop, and Documents will SILENTLY survive the wipe.');
      warn('Grant Full Disk Access: System Settings → Privacy & Security → Full Disk Access.');
    }
  }

  // Log FileVault status (informational — key destruction is the real fix)
  try {
    const fv = execSync('fdesetup status 2>&1 || true', { encoding: 'utf8', timeout: 10000 }).trim();
    console.log(`[INFO] FileVault: ${fv}`);
  } catch (_) { /* ignore */ }

  // Log Lockdown Mode status (informational)
  try {
    const lm = execSync('defaults read /Library/Preferences/com.apple.security.lockdownmode 2>/dev/null || echo "not set"',
                        { encoding: 'utf8', timeout: 10000 }).trim();
    console.log(`[INFO] Lockdown Mode: ${lm}`);
  } catch (_) { /* ignore */ }

  // Confirm /Users is on the Data volume (not the sealed System volume)
  try {
    const apfs = execSync('diskutil apfs list 2>/dev/null | grep -A2 "Data" || true',
                          { encoding: 'utf8', timeout: 10000 }).trim();
    if (apfs.length > 0) console.log('[INFO] APFS Data volume detected.');
  } catch (_) { /* ignore */ }
}

function buildBashScript() {
  const timestamp = Math.floor(Date.now() / 1000);
  const logFile = `${LOG_PREFIX}${timestamp}.log`;

  return `#!/bin/bash
export LC_ALL=C
set -uo pipefail
LOG="${logFile}"
exec > >(tee -a "$LOG") 2>&1

echo "[START] $(date)"
if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] Not root. Exiting."
  exit 1
fi

# Log SIP status (cannot be disabled from a running system)
SIP=$(csrutil status 2>/dev/null || echo "unknown")
echo "[INFO] SIP: $SIP"

# --- 0. Clear immutable flags recursively ---
echo "[STEP] Clearing immutable flags (uchg/schg) on ${TARGET_DIR}..."
chflags -R nouchg noschg "${TARGET_DIR}" 2>&1 || \\
  echo "[WARN] chflags failed for some paths (TCC, SIP, or restricted flags)"

# --- 1. Delete APFS local snapshots ---
echo "[STEP] Deleting local Time Machine snapshots..."
if command -v tmutil >/dev/null 2>&1; then
  tmutil thinlocalsnapshots / 999999999999999 4 2>&1 || \\
    echo "[WARN] tmutil thinlocalsnapshots failed"
  SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | \\
          grep -E '^com\\.apple\\.TimeMachine\\.' || true)
  if [[ -n "$SNAPS" ]]; then
    while IFS= read -r snap; do
      [[ -z "$snap" ]] && continue
      echo "[STEP] Deleting snapshot: $snap"
      tmutil deletelocalsnapshots "$snap" 2>&1 || \\
        echo "[WARN] Failed to delete snapshot: $snap"
    done <<< "$SNAPS"
  else
    echo "[INFO] No local snapshots found (or tmutil unavailable)."
  fi
else
  echo "[WARN] tmutil not found; local snapshots may remain."
fi

# --- 2. Delete contents of /Users ---
echo "[STEP] Deleting contents of ${TARGET_DIR}..."
find "${TARGET_DIR}" -mindepth 1 -delete 2>&1 | while IFS= read -r line; do
  echo "[FIND] $line"
done

# --- 3. Verify no regular files remain ---
REMAINING=$(find "${TARGET_DIR}" -type f 2>/dev/null | head -n 30 || true)
if [[ -n "$REMAINING" ]]; then
  echo "[WARN] Regular files still present (TCC/SIP/immutable/in-use):"
  echo "$REMAINING"
else
  echo "[OK] No regular files remain under ${TARGET_DIR}."
fi

# --- 4. Secure erase free space — ONLY on rotational HDD ---
if command -v diskutil >/dev/null 2>&1; then
  DISK_INFO=$(diskutil info / 2>/dev/null || true)
  if echo "$DISK_INFO" | grep -q "Solid State: Yes"; then
    echo "[SKIP] Internal disk is SSD; diskutil secureErase is deprecated and unsafe on APFS/SSD."
    echo "[SKIP] For guaranteed SSD erasure, use key destruction (Erase All Content and Settings / Recovery eraseDisk)."
  else
    echo "[STEP] Rotational HDD detected; attempting secureErase freespace..."
    diskutil secureErase freespace 1 / < /dev/null 2>&1 || \\
      echo "[WARN] diskutil secureErase freespace failed on /"
  fi
fi

# --- 5. Best-effort external volumes under /Volumes ---
for vol in /Volumes/*; do
  [[ -d "$vol" ]] || continue
  [[ "$vol" = "/Volumes/Macintosh HD" ]] && continue
  [[ "$vol" = "/Volumes/Macintosh HD - Data" ]] && continue
  [[ "$vol" = "/Volumes/Recovery" ]] && continue

  # Skip Time Machine volumes
  if [[ -d "$vol/Backups.backupdb" ]] || [[ -d "$vol/.TimeMachine" ]]; then
    echo "[SKIP] $vol looks like a Time Machine volume; not wiping."
    continue
  fi

  if [[ ! -w "$vol" ]]; then
    echo "[SKIP] $vol not writable"
    continue
  fi

  echo "[STEP] Wiping external volume: $vol"
  find "$vol" -mindepth 1 -delete 2>&1 | while IFS= read -r line; do
    echo "[VOL $vol] $line"
  done

  VOL_INFO=$(diskutil info "$vol" 2>/dev/null || true)
  if echo "$VOL_INFO" | grep -q "Solid State: No"; then
    diskutil secureErase freespace 1 "$vol" < /dev/null 2>&1 || \\
      echo "[WARN] secureErase freespace failed on $vol"
  fi
done

# --- 6. Purge inactive memory (requires Xcode CLT; may be absent) ---
if command -v purge >/dev/null 2>&1; then
  echo "[STEP] Purging inactive memory..."
  purge 2>&1 || echo "[WARN] purge failed"
else
  echo "[SKIP] purge not found (install Xcode Command Line Tools)."
fi

# --- 7. Final FileVault reminder ---
echo "[IMPORTANT] On Apple Silicon/T2, the ONLY guaranteed erasure is key destruction."
echo "[IMPORTANT] Use: Erase All Content and Settings (System Settings → General → Transfer or Reset)."
echo "[IMPORTANT] Or Recovery Mode: diskutil eraseDisk APFS \\"Macintosh HD\\" GPT /dev/disk0"

echo "[DONE] $(date)"
`;
}

async function main() {
  preflight();
  await confirm();

  const bashScript = buildBashScript();

  // Write the bash script to a temp file outside the wiped scope
  const scriptPath = `/tmp/.wipe-mac-${process.pid}.sh`;
  fs.writeFileSync(scriptPath, bashScript, { mode: 0o700 });

  // Spawn detached; stdin from /dev/null prevents hangs
  const child = spawn('bash', [scriptPath], {
    detached: true,
    stdio: ['ignore', 'ignore', 'ignore'], // child redirects its own output to LOG
  });
  child.unref();

  // Best-effort self-deletion (may fail on read-only filesystems)
  try {
    fs.unlinkSync(__filename);
  } catch (e) {
    // Page cache may retain a copy; this is best-effort only.
  }

  // Best-effort removal of the temp bash script
  setTimeout(() => {
    try { fs.unlinkSync(scriptPath); } catch (_) { /* ignore */ }
  }, 5000);

  console.log(`\nWipe started in background. PID: ${child.pid}`);
  console.log(`Log: ${LOG_PREFIX}*.log`);
  console.log('If the log does not appear within 30 seconds, the script may have');
  console.log('failed to start. Check Console.app for TCC/SIP denials.');
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
