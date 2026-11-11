#!/usr/bin/env python3
"""
wipe-linux.py — best-effort logical sanitizer for Linux home directories.

WARNING: This is NOT a guaranteed forensic eraser.
- On Btrfs/ZFS (CoW), shred cannot overwrite original blocks.
- On SSDs, fstrim is not a secure erase; blkdiscard --secure is required
  on the raw block device, which this script does not attempt by default.
- On LUKS/systemd-homed, only key destruction guarantees erasure.

Run as root. Requires: find, shred, fstrim, btrfs (optional), cryptsetup (optional).
"""

import os
import sys
import shutil
import subprocess
import platform
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONFIRM_PHRASE = "DELETE EVERYTHING"
STATUS_LOG = f"/tmp/.wipe-status-{os.getpid()}.log"
SHRED_PASSES = 1          # 1 random pass + final zero pass; sufficient for HDD
ALLOW_NON_ROOT = False    # must be root for fstrim/btrfs/shred on protected files

# System paths that must never be wiped
SYSTEM_MOUNT_PREFIXES = (
    "/proc", "/sys", "/dev", "/run", "/snap", "/boot", "/usr", "/var",
    "/etc", "/bin", "/sbin", "/lib", "/lib64", "/opt", "/srv",
)

# Filesystem types we can attempt to wipe
WIPEABLE_FSTYPES = {
    "ext4", "ext3", "ext2", "xfs", "btrfs", "zfs", "f2fs", "vfat", "exfat", "ntfs",
}

# Network / virtual filesystems to skip
SKIP_FSTYPES = {
    "nfs", "nfs4", "cifs", "smbfs", "sshfs", "fuse.sshfs", "9p", "virtiofs",
    "overlay", "tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2",
    "debugfs", "tracefs", "securityfs", "pstore", "bpf", "autofs", "mqueue",
    "hugetlbfs", "configfs", "fusectl", "binfmt_misc",
}


def log(msg: str):
    """Append to status log; never raises."""
    try:
        with open(STATUS_LOG, "a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except Exception:
        pass


def die(msg: str, code: int = 1):
    print(f"\033[91m[FATAL]\033[0m {msg}", file=sys.stderr)
    log(f"[FATAL] {msg}")
    sys.exit(code)


# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
def require_root():
    if os.geteuid() != 0:
        die("This script must run as root (use sudo). fstrim, btrfs, and shred "
            "on protected files require root privileges.")


def check_binaries():
    required = ["find", "shred", "sync", "fstrim"]
    optional = ["btrfs", "cryptsetup", "blkdiscard", "lsblk"]
    missing = [b for b in required if shutil.which(b) is None]
    if missing:
        die(f"Missing required binaries: {', '.join(missing)}. "
            f"Install them with your package manager (coreutils, findutils, util-linux).")
    for b in optional:
        if shutil.which(b) is None:
            log(f"[INFO] Optional binary not found: {b} — some features will be skipped.")


def detect_distro() -> str:
    """Best-effort distro detection without external dependencies."""
    try:
        # /etc/os-release is the standard on all modern distros
        data = {}
        with open("/etc/os-release", encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    data[k] = v.strip('"')
        name = data.get("PRETTY_NAME") or data.get("NAME") or "Unknown Linux"
        return name
    except Exception:
        return platform.platform()


def resolve_target_home() -> Path:
    """
    Resolve the real user's home even when run under sudo.
    Refuses to silently target /root when SUDO_USER is set.
    """
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and sudo_user != "root":
        import pwd
        try:
            real_home = Path(pwd.getpwnam(sudo_user).pw_dir).resolve()
        except KeyError:
            die(f"SUDO_USER '{sudo_user}' has no passwd entry.")
    else:
        real_home = Path.home().resolve()

    if str(real_home) == "/root" and sudo_user in (None, "root"):
        # Explicit confirmation required to wipe /root
        print("\033[91mWARNING:\033[0m Target home resolved to /root. "
              "Type 'YES WIPE ROOT' to confirm, or press Enter to abort:")
        if input().strip() != "YES WIPE ROOT":
            die("Aborted: refusing to wipe /root without explicit confirmation.")

    if not real_home.exists():
        die(f"Target home does not exist: {real_home}")

    # Safety: refuse / or /home itself
    if str(real_home) in ("/", "/home"):
        die(f"Refusing to wipe root or /home itself: {real_home}")

    return real_home


# ---------------------------------------------------------------------------
# Encryption detection (LUKS / systemd-homed / fscrypt)
# ---------------------------------------------------------------------------
def detect_encryption(home: Path) -> list[str]:
    warnings = []

    # LUKS: check /dev/mapper and cryptsetup
    if shutil.which("cryptsetup"):
        try:
            out = subprocess.run(
                ["cryptsetup", "status"],
                capture_output=True, text=True, timeout=10
            )
            # cryptsetup status without an argument lists nothing; inspect /dev/mapper
        except Exception:
            pass

    try:
        if any(Path("/dev/mapper").glob("luks-*")) or any(Path("/dev/mapper").glob("cryptroot*")):
            warnings.append(
                "LUKS device detected under /dev/mapper. Overwriting the mounted "
                "filesystem does NOT destroy the LUKS key. To guarantee erasure, "
                "destroy the key with 'cryptsetup luksErase <device>' after unmounting."
            )
    except Exception:
        pass

    # systemd-homed: ~/.home file or homectl
    if shutil.which("homectl"):
        try:
            out = subprocess.run(["homectl", "list"], capture_output=True, text=True, timeout=10)
            if out.returncode == 0 and out.stdout.strip():
                warnings.append(
                    "systemd-homed user detected. Home is LUKS-encrypted inside a "
                    "loopback file. Overwriting the mounted home does not erase the "
                    "underlying ciphertext; destroy the LUKS key instead."
                )
        except Exception:
            pass

    # fscrypt: check for fscryptctl and encrypted directory policy
    if shutil.which("fscryptctl"):
        try:
            out = subprocess.run(
                ["fscryptctl", "get_policy", str(home)],
                capture_output=True, text=True, timeout=10
            )
            if out.returncode == 0 and out.stdout.strip():
                warnings.append(
                    "fscrypt policy detected on the home directory. Only key "
                    "destruction guarantees erasure of ciphertext."
                )
        except Exception:
            pass

    return warnings


# ---------------------------------------------------------------------------
# Filesystem / mount detection
# ---------------------------------------------------------------------------
def get_mounts() -> list[dict]:
    """Parse /proc/mounts into a list of dicts."""
    mounts = []
    try:
        with open("/proc/mounts", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 4:
                    continue
                dev, mnt, fstype, opts = parts[0], parts[1], parts[2], parts[3]
                mounts.append({
                    "device": dev,
                    "mountpoint": mnt,
                    "fstype": fstype,
                    "options": opts,
                })
    except Exception as e:
        log(f"[WARN] Could not parse /proc/mounts: {e}")
    return mounts


def find_fstype(path: Path) -> str:
    """Return the filesystem type of the mount containing path."""
    path = path.resolve()
    best = ""
    best_len = -1
    for m in get_mounts():
        mp = m["mountpoint"]
        if str(path) == mp or str(path).startswith(mp.rstrip("/") + "/"):
            if len(mp) > best_len:
                best_len = len(mp)
                best = m["fstype"]
    return best


def find_parent_device(path: Path) -> str | None:
    """Find the parent block device for a mountpoint using lsblk."""
    if not shutil.which("lsblk"):
        return None
    try:
        out = subprocess.run(
            ["lsblk", "-no", "PKNAME,MOUNTPOINT"],
            capture_output=True, text=True, timeout=10
        )
        mp = str(path.resolve())
        for line in out.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == mp:
                return parts[0]
    except Exception:
        pass
    return None


def is_ssd(device: str | None) -> bool:
    """Best-effort SSD detection via /sys/block/<dev>/queue/rotational."""
    if not device:
        return False
    # device may be like "sda3" or "nvme0n1p1"; strip partition suffix
    base = device
    for prefix in ("nvme", "mmcblk"):
        if base.startswith(prefix):
            base = base.split("p")[0] if "p" in base else base
            break
    else:
        # SATA/SCSI: strip trailing digits
        import re
        base = re.sub(r"\d+$", "", base)

    rot_path = Path(f"/sys/block/{base}/queue/rotational")
    try:
        return rot_path.read_text().strip() == "0"
    except Exception:
        return False


def collect_targets(home: Path) -> list[dict]:
    """
    Collect wipe targets:
      - The home directory itself (must be on its own filesystem or subvolume).
      - Other writable, fixed/removable mounts under /media, /mnt, /run/media
        that are not system mounts and not network/virtual filesystems.
    """
    targets = []
    home_fstype = find_fstype(home)
    targets.append({"path": home, "fstype": home_fstype, "label": "HOME"})

    for m in get_mounts():
        mp = m["mountpoint"]
        fstype = m["fstype"]

        if fstype in SKIP_FSTYPES:
            continue
        if fstype not in WIPEABLE_FSTYPES:
            continue
        if any(mp == p or mp.startswith(p.rstrip("/") + "/") for p in SYSTEM_MOUNT_PREFIXES):
            continue
        if mp == "/":
            continue  # never wipe the running root filesystem by default
        if str(home) == mp or str(home).startswith(mp.rstrip("/") + "/"):
            continue  # already covered by HOME target

        # Only consider common removable mount roots
        if not any(mp.startswith(root) for root in ("/media/", "/mnt/", "/run/media/")):
            continue

        # Check writability
        if not os.access(mp, os.W_OK):
            log(f"[SKIP] {mp}: not writable")
            continue

        targets.append({"path": Path(mp), "fstype": fstype, "label": "OTHER"})

    return targets


# ---------------------------------------------------------------------------
# Btrfs handling
# ---------------------------------------------------------------------------
def handle_btrfs(home: Path, log_failures: list[str]):
    """
    On Btrfs, shred is ineffective. The correct approach is subvolume deletion.
    We attempt to delete the home subvolume if it is a distinct subvolume.
    """
    if not shutil.which("btrfs"):
        log_failures.append("btrfs binary not found; cannot delete subvolumes.")
        return

    try:
        out = subprocess.run(
            ["btrfs", "subvolume", "show", str(home)],
            capture_output=True, text=True, timeout=10
        )
        if out.returncode != 0:
            log_failures.append(
                f"{home} is not a Btrfs subvolume (or btrfs command failed). "
                "shred will not overwrite original CoW blocks."
            )
            return

        # Snapshot may be read-only; clear the ro property first
        subprocess.run(
            ["btrfs", "property", "set", str(home), "ro", "false"],
            capture_output=True, timeout=10
        )

        # Delete the subvolume (this frees blocks for future GC, not a secure erase)
        del_out = subprocess.run(
            ["btrfs", "subvolume", "delete", str(home)],
            capture_output=True, text=True, timeout=60
        )
        if del_out.returncode == 0:
            log_failures.append(
                f"Deleted Btrfs subvolume {home}. NOTE: blocks are freed for GC, "
                "not securely erased. LUKS key destruction is required for guarantees."
            )
        else:
            log_failures.append(f"btrfs subvolume delete failed: {del_out.stderr.strip()}")
    except Exception as e:
        log_failures.append(f"Btrfs handling failed: {e}")


# ---------------------------------------------------------------------------
# Core wipe pipeline
# ---------------------------------------------------------------------------
def wipe_target(target: dict, log_failures: list[str]):
    path = target["path"]
    fstype = target["fstype"]

    log(f"[WIPE] {target['label']} {path} ({fstype})")

    if fstype == "btrfs":
        handle_btrfs(path, log_failures)
        # Still run shred as best-effort hygiene, but it cannot overwrite CoW blocks
        log_failures.append(
            f"{path}: Btrfs CoW means shred overwrites NEW blocks, not the original "
            "data blocks. Only LUKS key destruction guarantees erasure."
        )

    # --- 1. Shred regular files only (skip symlinks) ---
    # -xdev: do not cross filesystem boundaries (prevents wiping mounted sub-mounts)
    # -type f: regular files only (skips symlinks, device nodes, sockets)
    # --: end of options, prevents a filename starting with '-' from being an option
    shred_cmd = [
        "find", str(path), "-xdev", "-type", "f", "-exec",
        "shred", "-uz", "-n", str(SHRED_PASSES), "--", "{}", "+"
    ]
    try:
        proc = subprocess.run(shred_cmd, capture_output=True, text=True, timeout=3600)
        if proc.returncode != 0:
            log_failures.append(f"shred on {path} returned {proc.returncode}: {proc.stderr.strip()[:500]}")
    except subprocess.TimeoutExpired:
        log_failures.append(f"shred on {path} timed out after 1 hour.")
    except Exception as e:
        log_failures.append(f"shred on {path} failed: {e}")

    # --- 2. Remove remaining directories and non-regular entries (not symlink targets) ---
    # -xdev keeps us on the same filesystem; -mindepth 1 avoids deleting the root itself
    # We use -delete which does not follow symlinks (find uses lstat during traversal).
    delete_cmd = ["find", str(path), "-xdev", "-mindepth", "1", "-delete"]
    try:
        proc = subprocess.run(delete_cmd, capture_output=True, text=True, timeout=1800)
        if proc.returncode != 0:
            log_failures.append(f"find -delete on {path} returned {proc.returncode}: {proc.stderr.strip()[:500]}")
    except subprocess.TimeoutExpired:
        log_failures.append(f"find -delete on {path} timed out after 30 minutes.")
    except Exception as e:
        log_failures.append(f"find -delete on {path} failed: {e}")

    # --- 3. Flush buffers ---
    try:
        subprocess.run(["sync"], timeout=120, capture_output=True)
    except Exception as e:
        log_failures.append(f"sync failed: {e}")

    # --- 4. TRIM / secure discard ---
    # fstrim on the mountpoint is a hygiene step, NOT a secure erase.
    if shutil.which("fstrim"):
        try:
            proc = subprocess.run(
                ["fstrim", "-v", str(path)],
                capture_output=True, text=True, timeout=600
            )
            if proc.returncode != 0:
                log_failures.append(f"fstrim on {path} returned {proc.returncode}: {proc.stderr.strip()[:300]}")
        except Exception as e:
            log_failures.append(f"fstrim on {path} failed: {e}")

    # --- 5. SSD secure discard (blkdiscard --secure) — only if safe ---
    # blkdiscard on the raw parent device destroys the filesystem.
    # We DO NOT do this automatically on mounted filesystems.
    # We only report that it is available and required for SSD guarantees.
    parent_dev = find_parent_device(path)
    if parent_dev and is_ssd(parent_dev):
        log_failures.append(
            f"{path} is on SSD ({parent_dev}). fstrim is not a secure erase. "
            f"For guaranteed NAND erasure, unmount the filesystem and run: "
            f"blkdiscard --secure /dev/{parent_dev}   (destroys the filesystem) "
            f"or nvme sanitize /dev/nvmeX --sanact=2."
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    print("\033[91m!!! WARNING !!!\033[0m")
    print("This will PERMANENTLY destroy data in your home directory and")
    print("best-effort wipe other writable fixed/removable mounts under /media, /mnt.")
    print("\033[91mTHIS IS IRREVERSIBLE.\033[0m")
    print(f"Distro: {detect_distro()}")
    print(f"Status log: {STATUS_LOG}")
    print()
    print("Limitations you MUST understand:")
    print("  • On Btrfs/ZFS, shred cannot overwrite original CoW blocks.")
    print("  • On SSDs, fstrim is NOT a secure erase; only blkdiscard --secure /")
    print("    nvme sanitize guarantees NAND erasure (requires unmounting).")
    print("  • On LUKS/systemd-homed, only key destruction guarantees erasure.")
    print()

    if os.geteuid() != 0:
        die("Must run as root. Use: sudo python3 wipe-linux.py")

    check_binaries()

    print(f"Type exactly: {CONFIRM_PHRASE}")
    print("and press Enter to proceed:")
    if input().strip() != CONFIRM_PHRASE:
        print("Aborted. Nothing was touched.")
        return 0

    home = resolve_target_home()
    print(f"\nTarget home: {home}")

    # Encryption warnings
    enc_warnings = detect_encryption(home)
    for w in enc_warnings:
        print(f"\033[93m[ENCRYPTION]\033[0m {w}")
        log(f"[ENCRYPTION] {w}")

    targets = collect_targets(home)
    print(f"\nTargets ({len(targets)}):")
    for t in targets:
        print(f"  • [{t['label']}] {t['path']} ({t['fstype']})")

    print("\nProceeding in 5 seconds. Press Ctrl+C to abort.")
    try:
        import time
        time.sleep(5)
    except KeyboardInterrupt:
        print("\nAborted.")
        return 0

    log_failures: list[str] = []
    for t in targets:
        wipe_target(t, log_failures)

    # Write failure report
    if log_failures:
        log("\n=== FAILURES / WARNINGS ===")
        for f in log_failures:
            log(f)

    # Optional self-deletion (honest: best-effort, may fail)
    try:
        os.remove(__file__)
        log("[SELF] Removed script file (best-effort; page cache may retain copies).")
    except Exception as e:
        log(f"[SELF] Could not remove script: {e}")

    print(f"\nDone. Check {STATUS_LOG} for details.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
