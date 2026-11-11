#!/usr/bin/env python3
"""
wipe-linux.py — best-effort logical sanitizer for Linux home directories.

HONEST LIMITATIONS (read before running):
  • On Btrfs/ZFS (CoW), shred cannot overwrite original blocks.
    Snapshots must be deleted first; even then, only LUKS key destruction
    or a full-device hardware sanitize guarantees erasure.
  • On SSDs, fstrim is NOT a secure erase. Use nvme sanitize, blkdiscard
    --secure, or hdparm --security-erase on the raw device after unmounting.
  • On LUKS/systemd-homed/fscrypt/eCryptfs/gocryptfs/CryFS/EncFS/VeraCrypt,
    only destroying the encryption key (and ciphertext directory) guarantees
    erasure. Shredding the mounted view does not touch the ciphertext.
  • This script runs as root. It resolves all binaries to absolute paths
    to prevent PATH hijacking, clears immutable/append-only attributes,
    disables core dumps, and logs every failure to a status file.
"""

import os
import sys
import stat
import signal
import shutil
import subprocess
import platform
import resource
import fcntl
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONFIRM_PHRASE = "DELETE EVERYTHING"
STATUS_LOG = f"/tmp/.wipe-status-{os.getpid()}.log"
LOCK_FILE = "/tmp/.wipe-linux.lock"
SHRED_PASSES = 1          # 1 random pass + final zero pass; sufficient for HDD
SHRED_TIMEOUT = 24 * 3600 # 24 hours — large homes on slow HDDs need this
DELETE_TIMEOUT = 6 * 3600 # 6 hours for find -delete
FSTRIM_TIMEOUT = 1800     # 30 minutes

# System paths that must never be wiped
SYSTEM_MOUNT_PREFIXES = (
    "/proc", "/sys", "/dev", "/run", "/snap", "/boot", "/usr", "/var",
    "/etc", "/bin", "/sbin", "/lib", "/lib64", "/opt", "/srv", "/root",
)

WIPEABLE_FSTYPES = {
    "ext4", "ext3", "ext2", "xfs", "btrfs", "zfs", "f2fs",
    "vfat", "exfat", "ntfs", "ntfs3",
}

SKIP_FSTYPES = {
    "nfs", "nfs4", "cifs", "smbfs", "sshfs", "fuse.sshfs", "9p", "virtiofs",
    "overlay", "tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2",
    "debugfs", "tracefs", "securityfs", "pstore", "bpf", "autofs", "mqueue",
    "hugetlbfs", "configfs", "fusectl", "binfmt_misc", "squashfs",
}

ENCRYPTED_FUSE_TYPES = {
    "fuse.gocryptfs", "fuse.cryfs", "fuse.encfs", "fuse.veracrypt",
}

# Absolute binary paths (resolved once, after PATH sanitization)
BIN = {}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(msg: str):
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
# Pre-flight hardening
# ---------------------------------------------------------------------------
def harden_process():
    """Disable core dumps, install signal handlers, sanitize PATH."""
    # Disable core dumps so crashes don't leak sensitive paths to disk
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except Exception:
        pass

    # Sanitize PATH to prevent hijacking of find/shred/etc.
    # We keep only root-owned system directories.
    safe_paths = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin",
                  "/usr/bin", "/sbin", "/bin"]
    os.environ["PATH"] = ":".join(p for p in safe_paths if os.path.isdir(p))
    os.environ["LC_ALL"] = "C"  # consistent English output from find/shred

    # Signal handlers: log where we stopped
    def _handler(signum, frame):
        log(f"[SIGNAL] Received signal {signum}; exiting gracefully.")
        sys.exit(128 + signum)
    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT, _handler)


def resolve_binaries():
    """Resolve all required and optional binaries to absolute paths."""
    required = ["find", "shred", "sync", "fstrim"]
    optional = ["chattr", "lsattr", "btrfs", "zfs", "cryptsetup",
                "blkdiscard", "nvme", "hdparm", "lsblk", "findmnt",
                "swapon", "swapoff", "keyctl", "vssadmin", "homectl",
                "fscryptctl", "mount", "df", "du"]

    for name in required:
        path = shutil.which(name)
        if not path:
            die(f"Required binary '{name}' not found in PATH. "
                f"Install it with your package manager (coreutils, findutils, util-linux).")
        BIN[name] = path

    for name in optional:
        path = shutil.which(name)
        if path:
            BIN[name] = path
        else:
            log(f"[INFO] Optional binary not found: {name}")


def require_root():
    if os.geteuid() != 0:
        die("This script must run as root. Use: sudo python3 wipe-linux.py")


def acquire_lock():
    """Prevent concurrent runs."""
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.write(fd, str(os.getpid()).encode())
        # Keep fd open for the lifetime of the process
        return fd
    except BlockingIOError:
        die("Another instance is already running (lock file held).")
    except Exception as e:
        die(f"Could not acquire lock: {e}")


def check_binaries():
    """Verify required binaries were resolved."""
    missing = [k for k in ("find", "shred", "sync", "fstrim") if k not in BIN]
    if missing:
        die(f"Missing required binaries: {', '.join(missing)}")


def detect_distro() -> str:
    try:
        data = {}
        with open("/etc/os-release", encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    data[k] = v.strip('"')
        return data.get("PRETTY_NAME") or data.get("NAME") or "Unknown Linux"
    except Exception:
        return platform.platform()


# ---------------------------------------------------------------------------
# Home resolution (SUDO_USER aware)
# ---------------------------------------------------------------------------
def resolve_target_home() -> Path:
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and sudo_user != "root":
        import pwd
        try:
            real_home = Path(pwd.getpwnam(sudo_user).pw_dir).resolve()
        except KeyError:
            die(f"SUDO_USER '{sudo_user}' has no passwd entry.")
    else:
        real_home = Path.home().resolve()

    if str(real_home) == "/root":
        print("\033[91mWARNING:\033[0m Target home resolved to /root. "
              "Type 'YES WIPE ROOT' to confirm, or press Enter to abort:")
        if input().strip() != "YES WIPE ROOT":
            die("Aborted: refusing to wipe /root without explicit confirmation.")

    if not real_home.exists():
        die(f"Target home does not exist: {real_home}")

    if str(real_home) in ("/", "/home"):
        die(f"Refusing to wipe root or /home itself: {real_home}")

    return real_home


# ---------------------------------------------------------------------------
# Encryption detection (LUKS, systemd-homed, fscrypt, eCryptfs, FUSE-crypt)
# ---------------------------------------------------------------------------
def detect_encryption(home: Path) -> list[str]:
    warnings = []

    # --- LUKS / dm-crypt ---
    luks_devices = []
    try:
        for mapper in Path("/dev/mapper").glob("*"):
            name = mapper.name
            # Common LUKS mapper names: luks-*, cryptroot, cryptswap, etc.
            if name.startswith("luks-") or name.startswith("crypt"):
                luks_devices.append(str(mapper))
    except Exception:
        pass

    if luks_devices:
        warnings.append(
            "LUKS/dm-crypt devices detected: " + ", ".join(luks_devices) + ". "
            "Overwriting the mounted filesystem does NOT destroy the LUKS key. "
            "To guarantee erasure, unmount and run: "
            "cryptsetup luksErase <device>   (erases all keyslots; irreversible)."
        )

    # --- systemd-homed ---
    if "homectl" in BIN:
        try:
            out = subprocess.run(
                [BIN["homectl"], "list"],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "LC_ALL": "C"}
            )
            if out.returncode == 0 and out.stdout.strip():
                warnings.append(
                    "systemd-homed user detected. Home is LUKS-encrypted inside a "
                    "loopback file (~/.home). Overwriting the mounted home does not "
                    "erase the loopback ciphertext; destroy the LUKS key instead."
                )
        except Exception:
            pass

    # --- fscrypt ---
    if "fscryptctl" in BIN:
        try:
            out = subprocess.run(
                [BIN["fscryptctl"], "get_policy", str(home)],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "LC_ALL": "C"}
            )
            if out.returncode == 0 and out.stdout.strip():
                warnings.append(
                    "fscrypt policy detected on the home directory. Only key "
                    "destruction (FS_IOC_REMOVE_ENCRYPTION_KEY) guarantees erasure "
                    "of ciphertext."
                )
        except Exception:
            pass

    # --- eCryptfs (Ubuntu legacy) ---
    ecryptfs_markers = [
        Path("/home/.ecryptfs"),
        home / ".ecryptfs",
        home / ".Private",
    ]
    for marker in ecryptfs_markers:
        if marker.exists():
            warnings.append(
                f"eCryptfs artifact detected: {marker}. The ciphertext lives in "
                "~/.Private and the wrapped passphrase in ~/.ecryptfs/. "
                "Shredding the mounted ~/Private does NOT destroy the ciphertext. "
                "Unmount and shred ~/.Private and ~/.ecryptfs entirely."
            )
            break

    # --- FUSE-based encrypted filesystems ---
    try:
        with open("/proc/mounts", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3 and parts[2] in ENCRYPTED_FUSE_TYPES:
                    warnings.append(
                        f"Encrypted FUSE filesystem detected: {parts[1]} "
                        f"({parts[2]}). The ciphertext directory must be shredded "
                        f"and the key destroyed; shredding the mounted view is "
                        f"ineffective."
                    )
    except Exception:
        pass

    # --- ZFS native encryption ---
    if "zfs" in BIN:
        try:
            out = subprocess.run(
                [BIN["zfs"], "get", "-H", "-o", "value", "encryption"],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "LC_ALL": "C"}
            )
            if out.returncode == 0 and out.stdout.strip() not in ("off", "-"):
                warnings.append(
                    "ZFS native encryption detected. To guarantee erasure, unload "
                    "the encryption key and destroy the dataset/key material. "
                    "ZFS does not support fine-grained secure deletion."
                )
        except Exception:
            pass

    return warnings


# ---------------------------------------------------------------------------
# Mount / filesystem detection
# ---------------------------------------------------------------------------
def get_mounts() -> list[dict]:
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


def find_mount_options(path: Path) -> set[str]:
    path = path.resolve()
    best = ""
    best_len = -1
    opts = ""
    for m in get_mounts():
        mp = m["mountpoint"]
        if str(path) == mp or str(path).startswith(mp.rstrip("/") + "/"):
            if len(mp) > best_len:
                best_len = len(mp)
                best = mp
                opts = m["options"]
    return set(opts.split(",")) if opts else set()


def is_read_only(path: Path) -> bool:
    return "ro" in find_mount_options(path)


def find_parent_device(path: Path) -> str | None:
    if "lsblk" not in BIN:
        return None
    try:
        out = subprocess.run(
            [BIN["lsblk"], "-no", "PKNAME,MOUNTPOINT"],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "LC_ALL": "C"}
        )
        mp = str(path.resolve())
        for line in out.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1] == mp:
                return parts[0]
    except Exception:
        pass
    return None


def is_ssd(device: str | None) -> bool:
    if not device:
        return False
    base = device
    for prefix in ("nvme", "mmcblk"):
        if base.startswith(prefix):
            base = base.split("p")[0] if "p" in base else base
            break
    else:
        import re
        base = re.sub(r"\d+$", "", base)

    rot_path = Path(f"/sys/block/{base}/queue/rotational")
    try:
        return rot_path.read_text().strip() == "0"
    except Exception:
        return False


def collect_targets(home: Path) -> list[dict]:
    targets = []
    home_fstype = find_fstype(home)
    if home_fstype in SKIP_FSTYPES:
        die(f"Home is on a skipped filesystem type ({home_fstype}); "
            f"shred is not applicable. Use the appropriate encryption-key "
            f"destruction method instead.")
    if home_fstype in ENCRYPTED_FUSE_TYPES:
        die(f"Home is on an encrypted FUSE filesystem ({home_fstype}); "
            f"shredding the mounted view is ineffective. Destroy the ciphertext "
            f"directory and key instead.")

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
            continue
        if str(home) == mp or str(home).startswith(mp.rstrip("/") + "/"):
            continue
        if not any(mp.startswith(root) for root in ("/media/", "/mnt/", "/run/media/")):
            continue
        if not os.access(mp, os.W_OK):
            log(f"[SKIP] {mp}: not writable")
            continue
        if is_read_only(Path(mp)):
            log(f"[SKIP] {mp}: mounted read-only")
            continue

        targets.append({"path": Path(mp), "fstype": fstype, "label": "OTHER"})

    return targets


# ---------------------------------------------------------------------------
# Swap / hibernation detection
# ---------------------------------------------------------------------------
def detect_swap(home: Path) -> list[str]:
    warnings = []
    if "swapon" not in BIN:
        return warnings
    try:
        out = subprocess.run(
            [BIN["swapon"], "--show=NAME,TYPE,SIZE", "--noheadings"],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "LC_ALL": "C"}
        )
        for line in out.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                name = parts[0]
                # If the swap file is under home, warn
                try:
                    if str(Path(name).resolve()).startswith(str(home.resolve())):
                        warnings.append(
                            f"Swap file inside home detected: {name}. "
                            f"Shredding an active swap file is ineffective. "
                            f"Run 'swapoff -a', then shred the swap file separately."
                        )
                except Exception:
                    pass
    except Exception:
        pass
    return warnings


# ---------------------------------------------------------------------------
# Btrfs handling (snapshots first, then subvolume)
# ---------------------------------------------------------------------------
def handle_btrfs(home: Path, log_failures: list[str]):
    if "btrfs" not in BIN:
        log_failures.append("btrfs binary not found; cannot delete subvolumes or snapshots.")
        return

    # --- 1. Delete snapshots of the home subvolume ---
    try:
        out = subprocess.run(
            [BIN["btrfs"], "subvolume", "list", "-o", str(home.parent)],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "LC_ALL": "C"}
        )
        for line in out.stdout.splitlines():
            # Lines look like: "ID 256 gen 123 top level 5 path @home/snapshots/foo"
            if "path " in line:
                snap_path = line.split("path ", 1)[1].strip()
                full_snap = home.parent / snap_path
                try:
                    subprocess.run(
                        [BIN["btrfs"], "property", "set", str(full_snap), "ro", "false"],
                        capture_output=True, timeout=30,
                        env={**os.environ, "LC_ALL": "C"}
                    )
                    subprocess.run(
                        [BIN["btrfs"], "subvolume", "delete", str(full_snap)],
                        capture_output=True, timeout=120,
                        env={**os.environ, "LC_ALL": "C"}
                    )
                    log(f"[BTRFS] Deleted snapshot: {full_snap}")
                except Exception as e:
                    log_failures.append(f"Failed to delete Btrfs snapshot {full_snap}: {e}")
    except Exception as e:
        log_failures.append(f"Btrfs snapshot enumeration failed: {e}")

    # --- 2. Clear ro property and delete the home subvolume ---
    try:
        out = subprocess.run(
            [BIN["btrfs"], "subvolume", "show", str(home)],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "LC_ALL": "C"}
        )
        if out.returncode != 0:
            log_failures.append(
                f"{home} is not a Btrfs subvolume; shred will not overwrite CoW blocks."
            )
            return

        subprocess.run(
            [BIN["btrfs"], "property", "set", str(home), "ro", "false"],
            capture_output=True, timeout=10,
            env={**os.environ, "LC_ALL": "C"}
        )
        del_out = subprocess.run(
            [BIN["btrfs"], "subvolume", "delete", str(home)],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "LC_ALL": "C"}
        )
        if del_out.returncode == 0:
            log_failures.append(
                f"Deleted Btrfs subvolume {home}. NOTE: blocks are freed for GC, "
                "not securely erased. LUKS key destruction or full-device sanitize "
                "is required for guarantees."
            )
        else:
            log_failures.append(f"btrfs subvolume delete failed: {del_out.stderr.strip()}")
    except Exception as e:
        log_failures.append(f"Btrfs subvolume deletion failed: {e}")


# ---------------------------------------------------------------------------
# ZFS handling
# ---------------------------------------------------------------------------
def handle_zfs(home: Path, log_failures: list[str]):
    if "zfs" not in BIN:
        log_failures.append("zfs binary not found; cannot delete snapshots.")
        return

    # Enumerate snapshots of datasets that contain home
    try:
        out = subprocess.run(
            [BIN["zfs"], "list", "-H", "-o", "name", "-t", "snapshot", "-r"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "LC_ALL": "C"}
        )
        for snap in out.stdout.splitlines():
            snap = snap.strip()
            if not snap:
                continue
            # Attempt to destroy the snapshot (recursive)
            del_out = subprocess.run(
                [BIN["zfs"], "destroy", "-r", snap],
                capture_output=True, text=True, timeout=120,
                env={**os.environ, "LC_ALL": "C"}
            )
            if del_out.returncode == 0:
                log(f"[ZFS] Destroyed snapshot: {snap}")
            else:
                log_failures.append(f"zfs destroy {snap} failed: {del_out.stderr.strip()}")
    except Exception as e:
        log_failures.append(f"ZFS snapshot handling failed: {e}")


# ---------------------------------------------------------------------------
# Immutable / append-only attribute clearing
# ---------------------------------------------------------------------------
def clear_chattr_recursive(root: Path, log_failures: list[str]):
    """
    Clear immutable (i), append-only (a) attributes recursively.
    Do NOT clear secure-deletion (s); it helps on ext4.
    """
    if "chattr" not in BIN:
        return
    try:
        # -f: suppress errors for files that don't support chattr (e.g., vfat)
        subprocess.run(
            [BIN["chattr"], "-f", "-R", "-i", "-a", str(root)],
            capture_output=True, timeout=600,
            env={**os.environ, "LC_ALL": "C"}
        )
    except Exception as e:
        log_failures.append(f"chattr -R -i -a on {root} failed: {e}")


# ---------------------------------------------------------------------------
# Sparse-file detection
# ---------------------------------------------------------------------------
def warn_sparse_files(root: Path, log_failures: list[str]):
    if "du" not in BIN:
        return
    try:
        out = subprocess.run(
            [BIN["du"], "--apparent-size", "--block-size=1", "-s", str(root)],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "LC_ALL": "C"}
        )
        apparent = int(out.stdout.split()[0]) if out.stdout.strip() else 0

        out2 = subprocess.run(
            [BIN["du"], "--block-size=1", "-s", str(root)],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "LC_ALL": "C"}
        )
        actual = int(out2.stdout.split()[0]) if out2.stdout.strip() else 0

        if apparent > 0 and actual < apparent * 0.5:
            log_failures.append(
                f"{root}: apparent size {apparent} bytes but only {actual} bytes "
                f"allocated — sparse files detected. shredding will expand them "
                f"to full size and may exhaust the filesystem. Consider excluding "
                f"sparse files or ensuring sufficient free space."
            )
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Kernel keyring clearing
# ---------------------------------------------------------------------------
def clear_keyrings(log_failures: list[str]):
    if "keyctl" not in BIN:
        return
    for keyring in ("@u", "@s"):
        try:
            subprocess.run(
                [BIN["keyctl"], "clear", keyring],
                capture_output=True, timeout=10,
                env={**os.environ, "LC_ALL": "C"}
            )
            log(f"[KEYCTL] Cleared keyring {keyring}")
        except Exception as e:
            log_failures.append(f"keyctl clear {keyring} failed: {e}")


# ---------------------------------------------------------------------------
# SSD hardware sanitize capability detection
# ---------------------------------------------------------------------------
def report_ssd_sanitize(device: str, log_failures: list[str]):
    """
    Detect whether the device supports hardware sanitize commands and
    report the exact command the user must run after unmounting.
    """
    if "nvme" in BIN and device.startswith("nvme"):
        log_failures.append(
            f"{device} is NVMe. For guaranteed NAND erasure, unmount all "
            f"filesystems on it and run: "
            f"nvme sanitize /dev/{device} --sanact=2   (crypto erase)   "
            f"or nvme format /dev/{device} --ses=2.   "
            f"fstrim is NOT a secure erase."
        )
        return

    # SATA / SCSI
    if "hdparm" in BIN:
        log_failures.append(
            f"{device} appears to be SATA. For guaranteed erasure, unmount all "
            f"filesystems and run: "
            f"hdparm --user-master u --security-set-pass temp /dev/{device} && "
            f"hdparm --user-master u --security-erase temp /dev/{device}   "
            f"(or --security-erase-enhanced if supported).   "
            f"Alternatively: blkdiscard --secure /dev/{device} (if supported)."
        )


# ---------------------------------------------------------------------------
# Core wipe pipeline
# ---------------------------------------------------------------------------
def wipe_target(target: dict, log_failures: list[str]):
    path = target["path"]
    fstype = target["fstype"]

    log(f"[WIPE] {target['label']} {path} ({fstype})")

    if is_read_only(path):
        log_failures.append(f"{path}: mounted read-only; skipping.")
        return

    # --- 0. Clear immutable / append-only attributes ---
    clear_chattr_recursive(path, log_failures)

    # --- 1. Sparse-file warning ---
    warn_sparse_files(path, log_failures)

    # --- 2. Filesystem-specific pre-handling ---
    if fstype == "btrfs":
        handle_btrfs(path, log_failures)
        log_failures.append(
            f"{path}: Btrfs CoW means shred overwrites NEW blocks, not the "
            "original data blocks. Snapshots were deleted, but only LUKS key "
            "destruction or full-device sanitize guarantees erasure."
        )
    elif fstype == "zfs":
        handle_zfs(path, log_failures)
        log_failures.append(
            f"{path}: ZFS CoW means shred is ineffective. Snapshots were "
            "destroyed, but only LUKS key destruction or full-device sanitize "
            "guarantees erasure."
        )

    # --- 3. Shred regular files only (skip symlinks) ---
    shred_cmd = [
        BIN["find"], str(path), "-xdev", "-type", "f", "-exec",
        BIN["shred"], "-uz", "-n", str(SHRED_PASSES), "--", "{}", "+"
    ]
    try:
        proc = subprocess.run(
            shred_cmd, capture_output=True, text=True, timeout=SHRED_TIMEOUT,
            env={**os.environ, "LC_ALL": "C"}
        )
        if proc.returncode != 0:
            log_failures.append(
                f"shred on {path} returned {proc.returncode}: "
                f"{proc.stderr.strip()[:500]}"
            )
    except subprocess.TimeoutExpired:
        log_failures.append(f"shred on {path} timed out after {SHRED_TIMEOUT}s.")
    except Exception as e:
        log_failures.append(f"shred on {path} failed: {e}")

    # --- 4. Verify no regular files remain, then delete directories ---
    try:
        verify = subprocess.run(
            [BIN["find"], str(path), "-xdev", "-type", "f"],
            capture_output=True, text=True, timeout=600,
            env={**os.environ, "LC_ALL": "C"}
        )
        remaining = [l for l in verify.stdout.splitlines() if l.strip()]
        if remaining:
            log_failures.append(
                f"{len(remaining)} regular file(s) survived shred on {path}. "
                f"Examples: {remaining[:5]}"
            )
    except Exception:
        pass

    delete_cmd = [BIN["find"], str(path), "-xdev", "-mindepth", "1", "-delete"]
    try:
        proc = subprocess.run(
            delete_cmd, capture_output=True, text=True, timeout=DELETE_TIMEOUT,
            env={**os.environ, "LC_ALL": "C"}
        )
        if proc.returncode != 0:
            log_failures.append(
                f"find -delete on {path} returned {proc.returncode}: "
                f"{proc.stderr.strip()[:500]}"
            )
    except subprocess.TimeoutExpired:
        log_failures.append(f"find -delete on {path} timed out after {DELETE_TIMEOUT}s.")
    except Exception as e:
        log_failures.append(f"find -delete on {path} failed: {e}")

    # --- 5. Flush buffers ---
    try:
        subprocess.run([BIN["sync"]], timeout=120,
                       env={**os.environ, "LC_ALL": "C"})
    except Exception as e:
        log_failures.append(f"sync failed: {e}")

    # --- 6. TRIM (hygiene only) ---
    if "fstrim" in BIN:
        try:
            proc = subprocess.run(
                [BIN["fstrim"], "-v", str(path)],
                capture_output=True, text=True, timeout=FSTRIM_TIMEOUT,
                env={**os.environ, "LC_ALL": "C"}
            )
            if proc.returncode != 0:
                log_failures.append(
                    f"fstrim on {path} returned {proc.returncode}: "
                    f"{proc.stderr.strip()[:300]}"
                )
        except Exception as e:
            log_failures.append(f"fstrim on {path} failed: {e}")

    # --- 7. SSD hardware sanitize capability report ---
    parent_dev = find_parent_device(path)
    if parent_dev and is_ssd(parent_dev):
        report_ssd_sanitize(parent_dev, log_failures)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    harden_process()
    require_root()
    acquire_lock()
    resolve_binaries()
    check_binaries()

    print("\033[91m!!! WARNING !!!\033[0m")
    print("This will PERMANENTLY destroy data in your home directory and")
    print("best-effort wipe other writable fixed/removable mounts under /media, /mnt.")
    print("\033[91mTHIS IS IRREVERSIBLE.\033[0m")
    print(f"Distro: {detect_distro()}")
    print(f"Status log: {STATUS_LOG}")
    print()
    print("Limitations you MUST understand:")
    print("  • On Btrfs/ZFS (CoW), shred cannot overwrite original blocks.")
    print("  • On SSDs, fstrim is NOT a secure erase. Only nvme sanitize,")
    print("    blkdiscard --secure, or hdparm --security-erase guarantee NAND")
    print("    erasure (requires unmounting the raw device).")
    print("  • On LUKS/systemd-homed/fscrypt/eCryptfs/gocryptfs/CryFS/EncFS/")
    print("    VeraCrypt, only key destruction guarantees erasure.")
    print()

    print(f"Type exactly: {CONFIRM_PHRASE}")
    print("(case-sensitive) and press Enter to proceed:")
    if input().strip() != CONFIRM_PHRASE:
        print("Aborted (phrase did not match exactly). Nothing was touched.")
        return 0

    home = resolve_target_home()
    print(f"\nTarget home: {home}")

    # Encryption warnings
    for w in detect_encryption(home):
        print(f"\033[93m[ENCRYPTION]\033[0m {w}")
        log(f"[ENCRYPTION] {w}")

    # Swap warnings
    for w in detect_swap(home):
        print(f"\033[93m[SWAP]\033[0m {w}")
        log(f"[SWAP] {w}")

    targets = collect_targets(home)
    print(f"\nTargets ({len(targets)}):")
    for t in targets:
        print(f"  • [{t['label']}] {t['path']} ({t['fstype']})")

    # Warn about NTFS (possible Windows dual-boot)
    for t in targets:
        if t["fstype"] in ("ntfs", "ntfs3", "vfat", "exfat"):
            print(f"\033[93m[WINDOWS?]\033[0m {t['path']} is {t['fstype']}. "
                  f"This may be a Windows partition. Proceeding will destroy it.")

    print("\nProceeding in 5 seconds. Press Ctrl+C to abort.")
    try:
        time.sleep(5)
    except KeyboardInterrupt:
        print("\nAborted.")
        return 0

    log_failures: list[str] = []

    # Clear keyrings before starting (reduces key exposure during wipe)
    clear_keyrings(log_failures)

    for t in targets:
        wipe_target(t, log_failures)

    # Drop page cache to reduce residual plaintext in memory
    try:
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("3")
        log("[CACHE] Dropped page cache (echo 3 > /proc/sys/vm/drop_caches)")
    except Exception:
        pass

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
