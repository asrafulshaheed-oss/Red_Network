#!/usr/bin/env bash
#==============================================================================
# delete.sh - Secure permanent delete for Linux (any distro) and macOS
#
# Usage:
#   ./delete.sh <file-or-folder> [<file-or-folder> ...]
#   sudo ./delete.sh ...     (protected files + extra drive-level hardening)
#
# Core wipe (always runs):
#   - Strips extended attributes, clears immutable/append-only flags
#   - Overwrites file contents 3x (zeros, 0xFF, random) in streaming fashion,
#     so file size never matters for memory use
#   - Truncates, renames to random names 3x, then unlinks (no trash, no backup)
#   - Recurses into folders of any depth; symlinks are unlinked, never followed
#   - Never writes to device nodes; refuses system dirs, $HOME and mount points
#   - Verifies each item is actually gone afterward
#
# Optional drive-level hardening (asks first):
#   - Linux: fstrim (root)            - SSD TRIM so the drive can erase cells
#   - Free-space wipe (fills the disk with random data, then frees it)
#   - macOS: purge local Time Machine snapshots (root, typed YES required)
#
# Written to run on macOS's stock bash 3.2 as well as modern bash.
#==============================================================================

export LC_ALL=C
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

OS=$(uname -s)
BLOCK=1048576

#--------------------------------------------------------------- helpers -----
usage() {
  cat <<USAGE
Usage: $0 <file-or-folder> [<file-or-folder> ...]

Securely overwrites and permanently deletes files and folders (recursively).
You must type DELETE twice to confirm. Run with sudo for protected files and
for the optional drive-level hardening steps.
USAGE
}

warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

FAILED=0; LIMITED=0; OK_FILES=0; OK_DIRS=0; OK_LINKS=0; PENDING=0
FAIL_LIST=()
fail() {
  FAILED=$((FAILED + 1))
  FAIL_LIST[${#FAIL_LIST[@]}]="$1 :: $2"
  echo "  ERROR: $1 :: $2"
}

human() {
  awk -v b="$1" 'BEGIN { split("B KB MB GB TB PB EB", u, " "); i = 1;
    while (b >= 1024 && i < 7) { b /= 1024; i++ } printf "%.2f %s", b, u[i] }'
}

# Prompt; answer lands in REPLY. Reads from the real terminal when there is one
# (so piped input can't auto-confirm), otherwise falls back to stdin.
ask() {
  printf '%s' "$1"
  REPLY=""
  if ( : < /dev/tty ) 2>/dev/null; then
    IFS= read -r REPLY < /dev/tty
  else
    IFS= read -r REPLY
  fi
}

abspath() {
  local p=$1 d b
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P )
  else
    d=${p%/*}; b=${p##*/}
    [ -n "$d" ] || d=/
    d=$( cd "$d" 2>/dev/null && pwd -P ) || return 1
    if [ "$d" = "/" ]; then echo "/$b"; else echo "$d/$b"; fi
  fi
}

mount_of() {
  df -P "$1" 2>/dev/null | awk 'NR==2 { $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print; exit }'
}

free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 { print $4 }'; }

fs_type() {
  local mp
  if [ "$OS" = "Linux" ]; then
    stat -f -c %T "$1" 2>/dev/null | tr 'A-Z' 'a-z'
  else
    mp=$(mount_of "$1")
    mount 2>/dev/null | grep -F " on $mp (" | head -n 1 | sed -e 's/^.* (//' -e 's/[,)].*$//'
  fi
}

# prints: <size-bytes> <allocated-bytes> <hardlink-count>
file_meta() {
  local out
  if [ "$STAT" = "gnu" ]; then
    out=$(stat -c '%s %b %h' "$1" 2>/dev/null) || return 1
    set -- $out
    [ $# -eq 3 ] || return 1
    echo "$1 $(( $2 * 512 )) $3"
  else
    out=$(stat -f '%z %b %l' "$1" 2>/dev/null) || return 1
    set -- $out
    [ $# -eq 3 ] || return 1
    echo "$1 $(( $2 * 512 )) $3"
  fi
}

rand_name() {
  local n
  n=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 20)
  [ -n "$n" ] || n="x$RANDOM$RANDOM$RANDOM"
  echo "$n"
}

is_protected() {
  local t=$1 home_r
  [ "$t" = "/" ] && return 0
  case "$t" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/mnt|/media|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 0 ;;
    /System|/Library|/Applications|/Users|/Volumes|/private|/private/etc|/private/var|/private/tmp|/cores|/usr/local) return 0 ;;
    /System/*|/bin/*|/sbin/*|/boot/*|/dev/*|/proc/*|/sys/*|/usr/bin/*|/usr/sbin/*|/usr/lib/*) return 0 ;;
  esac
  home_r=$( cd "$HOME" 2>/dev/null && pwd -P )
  if [ -n "$home_r" ]; then
    [ "$t" = "$home_r" ] && return 0
    case "$home_r/" in "$t"/*) return 0 ;; esac   # target is an ancestor of $HOME
  fi
  return 1
}

#---------------------------------------------------------- wipe engine -----
gen_pattern() {   # $1 mode  $2 size
  case "$1" in
    zero)   head -c "$2" /dev/zero ;;
    ones)   head -c "$2" /dev/zero | tr '\000' '\377' ;;
    random) head -c "$2" /dev/urandom ;;
  esac
}

overwrite_pass() {   # $1 file  $2 mode  $3 size   (writes in place, no truncate)
  gen_pattern "$2" "$3" | dd of="$1" bs=$BLOCK conv="$DD_CONV" 2>/dev/null
}

after_pass() {   # without dd fsync support, flush periodically instead
  [ "$HAVE_FSYNC" -eq 1 ] && return 0
  PENDING=$((PENDING + $1))
  if [ "$PENDING" -ge 134217728 ]; then sync; PENDING=0; fi
}

strip_xattrs() {
  local f=$1 name
  if [ "$OS" = "Darwin" ]; then
    xattr -c "$f" 2>/dev/null
  else
    if command -v getfattr >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1; then
      getfattr -m - "$f" 2>/dev/null | while IFS= read -r name; do
        case "$name" in ''|'#'*) continue ;; esac
        setfattr -x "$name" "$f" 2>/dev/null
      done
    fi
  fi
}

prep_tree() {
  local t=$1
  chmod -R u+rwX "$t" 2>/dev/null
  if [ "$OS" = "Darwin" ]; then
    chflags -R nouchg,nouappnd "$t" 2>/dev/null
    if [ "$(id -u)" -eq 0 ]; then chflags -R noschg,nosappnd "$t" 2>/dev/null; fi
  else
    if command -v chattr >/dev/null 2>&1; then chattr -R -i -a "$t" 2>/dev/null; fi
  fi
  return 0
}

wipe_file() {
  local f=$1 meta size alloc links need avail pass cur dir rn i limited=0
  meta=$(file_meta "$f")
  if [ -z "$meta" ]; then fail "$f" "cannot stat (permissions?)"; return 1; fi
  read -r size alloc links <<< "$meta"

  chmod u+rw "$f" 2>/dev/null
  strip_xattrs "$f"
  if [ "$links" -gt 1 ] 2>/dev/null; then
    echo "  note: $links hard links share this data; all of them will see it destroyed: $f"
  fi

  if [ "$size" -gt 0 ]; then
    # Sparse / compressed files: overwriting may need more space than is free.
    need=$(( size - alloc ))
    if [ "$need" -gt 1048576 ]; then
      avail=$(free_kb "$f"); [ -n "$avail" ] || avail=0
      avail=$(( avail * 1024 ))
      [ "$need" -gt "$avail" ] && limited=1
    fi
    if [ "$limited" -eq 1 ]; then
      warn "sparse/compressed file is larger than the free space available to overwrite it in place; deleting WITHOUT a full overwrite: $f"
      LIMITED=$((LIMITED + 1))
    else
      for pass in zero ones random; do
        if ! overwrite_pass "$f" "$pass" "$size"; then
          fail "$f" "overwrite failed during $pass pass (file left in place)"
          return 1
        fi
        after_pass "$size"
      done
    fi
  fi

  : > "$f" 2>/dev/null          # truncate to 0 bytes

  dir=${f%/*}; [ -n "$dir" ] || dir=/
  cur=$f
  for i in 1 2 3; do
    rn="${dir%/}/$(rand_name)"
    [ -e "$rn" ] && continue
    if mv -f "$cur" "$rn" 2>/dev/null; then cur=$rn; fi
  done

  rm -f "$cur" 2>/dev/null
  if [ -e "$cur" ] || [ -L "$cur" ]; then
    [ "$cur" != "$f" ] && mv -f "$cur" "$f" 2>/dev/null
    fail "$f" "still present after delete attempt (locked, immutable, or read-only filesystem?)"
    return 1
  fi
  OK_FILES=$((OK_FILES + 1))
  if [ "$limited" -eq 1 ]; then
    echo "  deleted, but NOT fully overwritten (see warning above): $f"
  else
    echo "  shredded: $f"
  fi
}

remove_dir() {
  local d=$1 par cur rn i
  chmod u+rwx "$d" 2>/dev/null
  par=${d%/*}; [ -n "$par" ] || par=/
  cur=$d
  for i in 1 2 3; do
    rn="${par%/}/$(rand_name)"
    [ -e "$rn" ] && continue
    if mv -f "$cur" "$rn" 2>/dev/null; then cur=$rn; fi
  done
  if rmdir "$cur" 2>/dev/null; then
    OK_DIRS=$((OK_DIRS + 1))
    echo "  removed folder: $d"
  else
    [ "$cur" != "$d" ] && mv -f "$cur" "$d" 2>/dev/null
    fail "$d" "folder not removed (not empty, in use, or another filesystem is mounted inside)"
  fi
}

process_entry() {
  local e=$1
  if [ -L "$e" ]; then
    rm -f "$e" 2>/dev/null
    if [ -L "$e" ]; then fail "$e" "cannot remove symlink"
    else OK_LINKS=$((OK_LINKS + 1)); echo "  unlinked symlink (target untouched): $e"; fi
  elif [ -d "$e" ]; then
    remove_dir "$e"
  elif [ -f "$e" ]; then
    wipe_file "$e"
  elif [ -e "$e" ]; then
    # fifo / socket / device node: remove the node only, never write to it
    rm -f "$e" 2>/dev/null
    if [ -e "$e" ]; then fail "$e" "cannot remove special file"
    else echo "  removed special file (node only): $e"; fi
  fi
}

ENTRIES=()
collect() {
  local x
  ENTRIES=()
  while IFS= read -r -d '' x; do
    ENTRIES[${#ENTRIES[@]}]=$x
  done < <(find "$1" $XDEV -depth -print0 2>/dev/null)
}

count_items() {
  find "$1" $XDEV -print0 2>/dev/null | tr -cd '\000' | wc -c | tr -d ' '
}

#-------------------------------------------------- drive-level hardening ---
FILL_DIR=""; DD_PID=""
cleanup() {
  if [ -n "$DD_PID" ]; then kill "$DD_PID" 2>/dev/null; wait "$DD_PID" 2>/dev/null; DD_PID=""; fi
  if [ -n "$FILL_DIR" ]; then rm -rf "$FILL_DIR" 2>/dev/null; fi
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM HUP

wipe_free_space() {   # $1 = directory on the filesystem to fill
  local d=$1
  FILL_DIR=$(mktemp -d "$d/.freewipe.XXXXXX" 2>/dev/null)
  if [ -z "$FILL_DIR" ]; then warn "cannot create a work folder in $d; skipping"; return 1; fi
  echo "  Filling free space with random data (ends with 'No space left on device', which is expected)."
  [ "$OS" = "Darwin" ] && echo "  Tip: press Ctrl-T for progress."
  dd if=/dev/urandom of="$FILL_DIR/fill.bin" bs=$BLOCK 2>/dev/null &
  DD_PID=$!
  wait "$DD_PID" 2>/dev/null
  DD_PID=""
  sync
  rm -rf "$FILL_DIR"
  FILL_DIR=""
  sync
  echo "  done."
}

purge_tm_snapshots() {
  local dates d
  command -v tmutil >/dev/null 2>&1 || { echo "  tmutil not found."; return; }
  dates=$(tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$')
  if [ -z "$dates" ]; then echo "  no local snapshots found."; return; fi
  for d in $dates; do
    echo "  deleting local snapshot $d"
    tmutil deletelocalsnapshots "$d" >/dev/null 2>&1
  done
}

harden() {
  local i fs
  echo
  echo "---------------- Optional drive-level hardening ----------------"

  if [ "$OS" = "Linux" ]; then
    if [ "$(id -u)" -eq 0 ] && command -v fstrim >/dev/null 2>&1; then
      for ((i = 0; i < ${#MP_LIST[@]}; i++)); do
        echo "Running fstrim on ${MP_LIST[$i]} ..."
        fstrim -v "${MP_LIST[$i]}" 2>&1 | sed 's/^/  /'
      done
    else
      echo "Skipped SSD TRIM (needs root and fstrim). Re-run with sudo to include it."
    fi
  else
    echo "macOS: TRIM for the internal SSD is automatic; there is no user-level command."
  fi

  echo
  ask "Also overwrite ALL free space on the affected drive(s)? Slow, and the disk will be 100% full for a while. Type YES or press Enter to skip: "
  if [ "$(echo "$REPLY" | tr 'a-z' 'A-Z')" = "YES" ]; then
    for ((i = 0; i < ${#MP_LIST[@]}; i++)); do
      fs=${MP_FS[$i]}
      case "$fs" in tmpfs|ramfs|devtmpfs) echo "Skipping ${MP_LIST[$i]} ($fs lives in RAM)."; continue ;; esac
      echo "Free-space wipe on ${MP_LIST[$i]} ..."
      wipe_free_space "${MP_DIR[$i]}"
    done
  else
    echo "Skipped free-space wipe."
  fi

  echo
  if [ "$OS" = "Darwin" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      echo "Advanced: delete local Time Machine snapshots on the startup volume."
      echo "WARNING: this removes ALL local snapshots (restore points) of every file there,"
      echo "not just what you deleted. Backups on external Time Machine disks are NOT touched."
      ask "Type YES (exactly) to proceed, or press Enter to skip: "
      if [ "$REPLY" = "YES" ]; then purge_tm_snapshots; else echo "Skipped snapshot purge."; fi
    else
      echo "Skipped local Time Machine snapshot purge (needs sudo)."
    fi
  else
    echo "Snapshots (snapper, Timeshift, btrfs, ZFS, LVM) and backups can still hold copies."
    echo "They are too filesystem-specific to delete automatically; check and purge them yourself."
  fi
}

#------------------------------------------------------------------ main -----
case "${1:-}" in -h|--help|"") usage; [ -n "${1:-}" ] && exit 0; exit 1 ;; esac

case "$OS" in
  Linux|Darwin) ;;
  *) warn "untested OS '$OS'; continuing with BSD-style tools" ;;
esac

for tool in dd head tr find mv rm rmdir df awk sync stat mktemp chmod grep sed wc; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

if stat -c %s / >/dev/null 2>&1; then STAT=gnu; else STAT=bsd; fi
if find / -maxdepth 0 -xdev >/dev/null 2>&1; then XDEV="-xdev"; else XDEV="-x"; fi

HAVE_FSYNC=0; DD_CONV="notrunc"
_probe=$(mktemp "${TMPDIR:-/tmp}/dsprobe.XXXXXX" 2>/dev/null)
if [ -n "$_probe" ]; then
  if dd if=/dev/zero of="$_probe" bs=1 count=1 conv=notrunc,fsync >/dev/null 2>&1; then
    HAVE_FSYNC=1; DD_CONV="notrunc,fsync"
  fi
  rm -f "$_probe"
fi

IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

# ---- resolve + validate every target before touching anything ----
TARGETS=(); MISSING=0
MP_LIST=(); MP_DIR=(); MP_FS=()

register_mount() {   # $1 = existing directory on the filesystem of interest
  local mp i
  mp=$(mount_of "$1")
  [ -n "$mp" ] || return 0
  for ((i = 0; i < ${#MP_LIST[@]}; i++)); do
    [ "${MP_LIST[$i]}" = "$mp" ] && return 0
  done
  MP_LIST[${#MP_LIST[@]}]=$mp
  MP_DIR[${#MP_DIR[@]}]=$1
  MP_FS[${#MP_FS[@]}]=$(fs_type "$1")
}

for arg in "$@"; do
  [ -n "$arg" ] || continue
  if [ ! -e "$arg" ] && [ ! -L "$arg" ]; then
    warn "not found, skipping: $arg"; MISSING=$((MISSING + 1)); continue
  fi
  t=$(abspath "$arg") || { warn "cannot resolve path, skipping: $arg"; continue; }
  if [ ! -L "$t" ] && { [ -b "$t" ] || [ -c "$t" ]; }; then
    die "refusing to touch a device node: $t"
  fi
  if is_protected "$t"; then
    die "BLOCKED: refusing system directory, \$HOME, or an ancestor of \$HOME: $t"
  fi
  if [ -d "$t" ] && [ ! -L "$t" ] && [ "$(mount_of "$t")" = "$t" ]; then
    die "BLOCKED: refusing to wipe an entire mounted filesystem: $t"
  fi
  TARGETS[${#TARGETS[@]}]=$t
  par=${t%/*}; [ -n "$par" ] || par=/
  register_mount "$par"
done

[ ${#TARGETS[@]} -gt 0 ] || { echo "Nothing valid to delete. Exiting."; exit 1; }

# ---- show what will be destroyed ----
echo "=========================================================="
echo " SECURE PERMANENT DELETE"
echo " Files are overwritten multiple times, then deleted."
echo " This is NOT the Trash. No backup is kept."
if [ "$IS_ROOT" -eq 1 ]; then
  echo " Running as root: yes (drive-level hardening available)"
else
  echo " Running as root: no (protected files / some extra steps unavailable)"
fi
echo "=========================================================="
echo

for t in "${TARGETS[@]}"; do
  if [ -L "$t" ]; then
    echo "  [SYMLINK] $t  (only the link is removed; its target is untouched)"
  elif [ -d "$t" ]; then
    echo "  [FOLDER]  $t  ($(count_items "$t") items including the folder itself)"
  elif [ -f "$t" ]; then
    meta=$(file_meta "$t")
    if [ -n "$meta" ]; then read -r fsz _ _ <<< "$meta"; echo "  [FILE]    $t  ($(human "$fsz"))"
    else echo "  [FILE]    $t"; fi
  else
    echo "  [OTHER]   $t  (special file; node removed only)"
  fi
done
[ "$MISSING" -gt 0 ] && { echo; echo "$MISSING path(s) were not found and were skipped above."; }

for ((i = 0; i < ${#MP_LIST[@]}; i++)); do
  case "${MP_FS[$i]}" in
    btrfs|zfs|apfs|f2fs|nfs*|cifs|smb*|overlay*|fuse*|ceph*)
      echo
      echo "NOTE: ${MP_LIST[$i]} is '${MP_FS[$i]}' (copy-on-write / log-structured / network / layered)."
      echo "      Overwriting in place may NOT destroy the old blocks (snapshots, clones, server copies)."
      ;;
  esac
done

echo
ask "Type DELETE to confirm: "
if [ "$REPLY" != "DELETE" ]; then echo "Confirmation text did not match. Aborted - nothing was touched."; exit 1; fi
ask "Type DELETE again to confirm: "
if [ "$REPLY" != "DELETE" ]; then echo "Confirmation text did not match. Aborted - nothing was touched."; exit 1; fi

echo
echo "Confirmed. Shredding... this can take a while for large files."
echo

# ---- core wipe ----
for t in "${TARGETS[@]}"; do
  if [ ! -e "$t" ] && [ ! -L "$t" ]; then
    echo "Already gone (covered by an earlier target?): $t"; continue
  fi
  echo "Processing: $t"
  [ -L "$t" ] || prep_tree "$t"
  collect "$t"
  for ((n = 0; n < ${#ENTRIES[@]}; n++)); do
    process_entry "${ENTRIES[$n]}"
  done
  ENTRIES=()
done

sync
echo
echo "Core wipe finished: $OK_FILES file(s), $OK_DIRS folder(s), $OK_LINKS symlink(s) removed; $FAILED error(s)."
if [ "$LIMITED" -gt 0 ]; then
  echo "WARNING: $LIMITED sparse/compressed file(s) were deleted without a full overwrite."
fi
if [ "$FAILED" -gt 0 ]; then
  echo "Items that could NOT be removed:"
  for ((n = 0; n < ${#FAIL_LIST[@]}; n++)); do echo "  - ${FAIL_LIST[$n]}"; done
  echo "(Try again with sudo, close programs using them, or check for read-only mounts / SIP.)"
fi

if [ $((OK_FILES + OK_DIRS + OK_LINKS)) -gt 0 ]; then harden; fi

echo
echo "All done."
[ "$FAILED" -eq 0 ] || exit 2
exit 0
