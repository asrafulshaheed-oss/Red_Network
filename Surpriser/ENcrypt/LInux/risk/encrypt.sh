#!/usr/bin/env bash
#======================================================================
# encrypt.sh - in-place file / folder encryption for Linux and macOS
#
#   Encrypt :  ./encrypt.sh   <file or folder>
#   Decrypt :  ./encrypt.sh --decrypt <file or folder>
#   Check   :  ./encrypt.sh --self-test        (no files are touched)
#
# Needs only tools that ship with Linux / macOS: bash (3.2+), openssl
# (OpenSSL 1.1.1+/3.x or LibreSSL 3.1+), find, head, tail, tee, wc, tr,
# touch, mktemp, stat, chmod, mv, cmp, dd.
#
# SECURITY DESIGN (details in README.md)
#   key derivation : PBKDF2-HMAC-SHA256, 600,000 iterations, random salt
#   cipher         : AES-256-CBC (openssl enc), unique key+IV per file
#   integrity      : HMAC-SHA256, encrypt-then-MAC, verified BEFORE any
#                    decrypted byte is written
#   secrets        : never on a command line (only env vars of a single
#                    child process, shell builtins and pipes)
#   in place       : result is written to a temp file in the same folder
#                    and renamed over the original -> no backup copy, and
#                    a crash never leaves a half-written file
#
# FILE FORMAT  (ASCII header, then openssl output, then ASCII tag)
#   [0..7]    "SHENC001"
#   [8..15]   PBKDF2 iterations, 8 lowercase hex digits
#   [16..31]  PBKDF2 salt, 16 hex digits (8 random bytes, one per run)
#   [32..63]  password check value, 32 hex digits
#   [64]      newline                          (header = 65 bytes)
#   [65..]    "Salted__" + 8-byte salt + AES-256-CBC ciphertext
#   last 64   HMAC-SHA256 hex of everything before it
#
# Windows (encrypt.vbs) files use a different format; they are NOT
# interchangeable with files made by this script.
#======================================================================

LC_ALL=C
export LC_ALL
set -o pipefail
umask 077

VERSION="1.0"
MAGIC="SHENC001"
ITER=600000          # PBKDF2 iterations for the password (per run)
FILE_ITER=1000       # per-file stage; input is already a 256-bit random secret
HDR_LEN=65           # 64 ASCII chars + newline
TAG_LEN=64           # HMAC-SHA256 as hex
MIN_ENC=$(( HDR_LEN + 16 + 16 + TAG_LEN ))   # header + "Salted__"+salt + 1 block + tag

# exit codes
EX_OK=0; EX_CANCEL=1; EX_PATH=2; EX_SELFTEST=3; EX_FAILED=4; EX_BADPW=5; EX_DEPS=6

OPENSSL=''
OPENSSL_VER=''
WORK=''
CURRENT_TMP=''
READING=0
RESULT=''
ERRMSG=''
SECRET=''
RUN_SALT=''

# context cache (parallel indexed arrays; bash 3.2 has no associative arrays)
CTX_N=0
CTX_ID=(); CTX_ENC=(); CTX_MIPAD=(); CTX_MOPAD=(); CTX_CHECK=()
C_ENC=''; C_MIPAD=''; C_MOPAD=''; C_CHECK=''; C_SALT=''; C_ITER=''

if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
else
  RED=''; GRN=''; YEL=''; RST=''
fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$YEL" "$*" "$RST"; }
bad()  { printf '%s%s%s\n' "$RED" "$*" "$RST"; }
ok()   { printf '%s%s%s\n' "$GRN" "$*" "$RST"; }
die()  { bad "$1"; exit "${2:-1}"; }

cleanup() {
  if [ -n "$CURRENT_TMP" ]; then rm -f -- "$CURRENT_TMP"; fi
  if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
  if [ "$READING" = 1 ]; then stty echo </dev/tty 2>/dev/null; fi
}
trap cleanup EXIT
trap 'printf "\n"; bad "Interrupted. The file being processed was left unchanged."; exit 130' INT TERM HUP

usage() {
  cat <<'EOF'
Usage:
  encrypt.sh <file-or-folder>              encrypt in place (asks you to type ENCRYPT, then a password twice)
  encrypt.sh --decrypt <file-or-folder>    decrypt in place (asks for the password)
  encrypt.sh --self-test                   check that this system can run the tool; touches no files
  encrypt.sh --help | --version

Put names that contain spaces in quotes. Use "--" before a name that starts with "-".
No backup copy is made. If you lose the password the data cannot be recovered.
EOF
}

#---------------------------------------------------------------------
# portable helpers (GNU / BSD / BusyBox differences)
#---------------------------------------------------------------------
if stat -c '%a' / >/dev/null 2>&1; then STAT_FLAVOR=gnu; else STAT_FLAVOR=bsd; fi

# prints "<hard-link-count> <octal-mode> <uid>:<gid>" with ONE stat call
file_meta() { if [ "$STAT_FLAVOR" = gnu ]; then stat -c '%h %a %u:%g' "$1"; else stat -f '%l %Lp %u:%g' "$1"; fi; }

is_hex() { case $1 in ''|*[!0-9a-f]*) return 1 ;; esac; return 0; }

# printable version of a path (control characters -> ?)
disp() {
  case $1 in
    *[[:cntrl:]]*) printf '%s' "$1" | tr '[:cntrl:]' '?' ;;
    *) printf '%s' "$1" ;;
  esac
}

# absolute PHYSICAL path of a file or folder (final symlink of a file is NOT followed)
abspath() {
  local p=$1 d b
  if [ -d "$p" ]; then ( cd -P -- "$p" 2>/dev/null && pwd -P ); return; fi
  d=$(dirname -- "$p"); b=$(basename -- "$p")
  d=$( cd -P -- "$d" 2>/dev/null && pwd -P ) || return 1
  if [ "$d" = / ]; then printf '/%s\n' "$b"; else printf '%s/%s\n' "$d" "$b"; fi
}

#---------------------------------------------------------------------
# crypto building blocks
#---------------------------------------------------------------------

# pad_fmt <key-hex-64> <pad-byte-as-number>
# prints a printf format string (\xHH...) for the 64-byte HMAC block (key XOR pad, zero-padded key)
pad_fmt() {
  local key=$1 pad=$2 i out='' b
  for (( i = 0; i < 64; i += 2 )); do
    printf -v b '\\x%02x' $(( 16#${key:i:2} ^ pad ))
    out+=$b
  done
  for (( i = 0; i < 32; i++ )); do
    printf -v b '\\x%02x' "$pad"
    out+=$b
  done
  printf '%s' "$out"
}

# hmac_stdin <ipad-fmt> <opad-fmt>   message on stdin, prints lowercase hex HMAC-SHA256.
# The key only ever exists in shell variables and pipes (never in argv).
hmac_stdin() {
  local out
  out=$( { printf "$2"; { printf "$1"; cat; } | "$OPENSSL" dgst -sha256 -binary; } | "$OPENSSL" dgst -sha256 ) || return 1
  printf '%s' "${out##* }"
}

# reads "openssl enc -P" output on stdin, prints the key as lowercase hex
parse_key() {
  local line
  while IFS= read -r line; do
    case $line in
      key=*) printf '%s' "${line#key=}" | tr 'A-F' 'a-f'; return 0 ;;
    esac
  done
  return 1
}

# known-answer tests: PBKDF2 (via enc -P), HMAC (via printf/dgst), AES round trip, rand
kat_all() {
  local out k ip op h rt
  # PBKDF2-HMAC-SHA256("password", salt 0001020304050607, 1000 iter) first 32 bytes
  out=$(SHENC_T=password "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter 1000 -md sha256 -S 0001020304050607 -P -pass env:SHENC_T 2>/dev/null) || return 1
  k=$(printf '%s\n' "$out" | parse_key) || return 1
  [ "$k" = f8b177bdec64144719f02b69ee888b2660d125f514100f8861d09a32ed96f3f0 ] || return 1
  # HMAC-SHA256(key=00..1f, "hello world")
  k=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
  ip=$(pad_fmt "$k" 54); op=$(pad_fmt "$k" 92)
  h=$(printf '%s' 'hello world' | hmac_stdin "$ip" "$op") || return 1
  [ "$h" = 411b9a51e8565e1fc79643b2a6c4672f4a3c3e573c33d0995a08748cb6128e8e ] || return 1
  # same, with a key whose pads contain NUL bytes (proves this shell's printf can emit \x00 correctly)
  k=36363636363636365c5c5c5c5c5c5c5c00000000000000000a0a0a0a0a0a0a0a
  ip=$(pad_fmt "$k" 54); op=$(pad_fmt "$k" 92)
  h=$(printf '%s' 'hello world' | hmac_stdin "$ip" "$op") || return 1
  [ "$h" = 21b6abea542307319c3c87acb3754eac615d6415092e3e18c7a8b77723239d4a ] || return 1
  # AES-256-CBC round trip with the exact options used on files
  rt=$(printf 'round trip' | SHENC_T=x "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter "$FILE_ITER" -md sha256 -salt -pass env:SHENC_T 2>/dev/null \
       | SHENC_T=x "$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter "$FILE_ITER" -md sha256 -pass env:SHENC_T 2>/dev/null) || return 1
  [ "$rt" = 'round trip' ] || return 1
  h=$("$OPENSSL" rand -hex 8 2>/dev/null) || return 1
  [ "${#h}" -eq 16 ] || return 1
  return 0
}

find_openssl() {
  local c p
  for c in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
           /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/bin/openssl; do
    p=$(command -v "$c" 2>/dev/null) || continue
    OPENSSL=$p
    if kat_all; then
      OPENSSL_VER=$("$OPENSSL" version 2>/dev/null)
      return 0
    fi
  done
  OPENSSL=''
  return 1
}

ctx_clear() { CTX_N=0; CTX_ID=(); CTX_ENC=(); CTX_MIPAD=(); CTX_MOPAD=(); CTX_CHECK=(); }

# ctx_use <password> <salt-hex16> <iterations>
# derives (or loads from cache) the encryption secret, MAC key and password check value
ctx_use() {
  local pw=$1 salt=$2 iter=$3 id i out k1 ip op enc mac chk mip mop
  id="$pw|$salt|$iter"
  i=0
  while [ "$i" -lt "$CTX_N" ]; do
    if [ "${CTX_ID[$i]}" = "$id" ]; then
      C_ENC=${CTX_ENC[$i]}; C_MIPAD=${CTX_MIPAD[$i]}; C_MOPAD=${CTX_MOPAD[$i]}; C_CHECK=${CTX_CHECK[$i]}
      C_SALT=$salt; C_ITER=$iter
      return 0
    fi
    i=$(( i + 1 ))
  done
  out=$(SHENC_PW="$pw" "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter "$iter" -md sha256 -S "$salt" -P -pass env:SHENC_PW 2>/dev/null) || return 1
  k1=$(printf '%s\n' "$out" | parse_key) || return 1
  [ "${#k1}" -eq 64 ] || return 1
  ip=$(pad_fmt "$k1" 54); op=$(pad_fmt "$k1" 92)
  enc=$(printf '%s' 'shenc-enc-v1'   | hmac_stdin "$ip" "$op") || return 1
  mac=$(printf '%s' 'shenc-mac-v1'   | hmac_stdin "$ip" "$op") || return 1
  chk=$(printf '%s' 'shenc-check-v1' | hmac_stdin "$ip" "$op") || return 1
  chk=${chk:0:32}
  mip=$(pad_fmt "$mac" 54); mop=$(pad_fmt "$mac" 92)
  CTX_ID[$CTX_N]=$id; CTX_ENC[$CTX_N]=$enc; CTX_MIPAD[$CTX_N]=$mip; CTX_MOPAD[$CTX_N]=$mop; CTX_CHECK[$CTX_N]=$chk
  CTX_N=$(( CTX_N + 1 ))
  C_ENC=$enc; C_MIPAD=$mip; C_MOPAD=$mop; C_CHECK=$chk; C_SALT=$salt; C_ITER=$iter
  return 0
}

# finish a temp file: copy time stamps / owner / mode of the original, then atomically replace it
finish_replace() {   # $1 tmp  $2 original  $3 mode  $4 owner
  local cur
  touch -r "$2" "$1" 2>/dev/null
  if [ "$(id -u)" = 0 ]; then chown "$4" "$1" 2>/dev/null; fi
  if ! chmod "$3" "$1" 2>/dev/null; then
    # e.g. FAT/exFAT/NTFS mounts with a fixed permission mask: acceptable only if the mode already matches
    cur=$(file_meta "$1"); cur=${cur#* }; cur=${cur%% *}
    [ "$cur" = "$3" ] || return 1
  fi
  mv -f -- "$1" "$2" || return 1
  return 0
}

#---------------------------------------------------------------------
# per-file operations.  Result goes in $RESULT; return 1 = I/O or crypto error ($ERRMSG)
#   encrypt: ok | already | hardlink
#   decrypt: ok | notenc | badpw | corrupt | hardlink
# The original file is never modified unless everything succeeded.
#---------------------------------------------------------------------
encrypt_file() {   # uses the context set by ctx_use
  local f=$1 dir tmp magic nl mode owner meta hdr tag rc
  RESULT=''; ERRMSG=''
  if [ ! -r "$f" ]; then ERRMSG='file is not readable (permission denied)'; return 1; fi
  meta=$(file_meta "$f") || { ERRMSG='cannot read file attributes'; return 1; }
  set -- $meta; nl=$1; mode=$2; owner=$3
  if [ -z "$mode" ] || [ -z "$owner" ]; then ERRMSG='cannot read file attributes'; return 1; fi
  if [ "$nl" -gt 1 ] 2>/dev/null; then RESULT=hardlink; return 0; fi
  magic=$( { head -c 8 < "$f" | tr -d '\000'; } 2>/dev/null )
  if [ "$magic" = "$MAGIC" ]; then RESULT=already; return 0; fi
  dir=${f%/*}; [ -n "$dir" ] || dir=/
  tmp=$(mktemp "$dir/.shenc-tmp.XXXXXXXX" 2>/dev/null) || { ERRMSG='cannot create temp file in this folder (no write permission?)'; return 1; }
  CURRENT_TMP=$tmp
  hdr="${MAGIC}$(printf '%08x' "$C_ITER")${C_SALT}${C_CHECK}"
  tag=$( { printf '%s\n' "$hdr"
           { SHENC_FK="$C_ENC" "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter "$FILE_ITER" -md sha256 -salt -pass env:SHENC_FK < "$f"; } 2>/dev/null
         } | tee "$tmp" | hmac_stdin "$C_MIPAD" "$C_MOPAD" )
  rc=$?
  if [ "$rc" -ne 0 ] || [ "${#tag}" -ne "$TAG_LEN" ]; then
    ERRMSG='encryption failed (cannot read file, or disk full / I/O error)'
    rm -f -- "$tmp"; CURRENT_TMP=''; return 1
  fi
  if ! printf '%s' "$tag" >> "$tmp"; then
    ERRMSG='cannot write to temp file (disk full?)'
    rm -f -- "$tmp"; CURRENT_TMP=''; return 1
  fi
  if ! finish_replace "$tmp" "$f" "$mode" "$owner"; then
    ERRMSG='cannot replace the original file (immutable flag / permissions?)'
    rm -f -- "$tmp"; CURRENT_TMP=''; return 1
  fi
  CURRENT_TMP=''
  RESULT=ok
  return 0
}

decrypt_file() {   # $1 path  $2 password
  local f=$1 pw=$2 size hdr iterhex salt chk iter dir tmp mode owner meta calc stored body nl rc
  RESULT=''; ERRMSG=''
  if [ ! -r "$f" ]; then ERRMSG='file is not readable (permission denied)'; return 1; fi
  meta=$(file_meta "$f") || { ERRMSG='cannot read file attributes'; return 1; }
  set -- $meta; nl=$1; mode=$2; owner=$3
  if [ -z "$mode" ] || [ -z "$owner" ]; then ERRMSG='cannot read file attributes'; return 1; fi
  if [ "$nl" -gt 1 ] 2>/dev/null; then RESULT=hardlink; return 0; fi
  size=$( { wc -c < "$f"; } 2>/dev/null ) || { ERRMSG='cannot read file'; return 1; }
  size=$(( size ))
  if [ "$size" -lt "$MIN_ENC" ]; then RESULT=notenc; return 0; fi
  hdr=$( { head -c "$HDR_LEN" < "$f" | tr -d '\000'; } 2>/dev/null )
  if [ "${#hdr}" -ne 64 ] || [ "${hdr:0:8}" != "$MAGIC" ]; then RESULT=notenc; return 0; fi
  iterhex=${hdr:8:8}; salt=${hdr:16:16}; chk=${hdr:32:32}
  if ! is_hex "$iterhex" || ! is_hex "$salt" || ! is_hex "$chk"; then RESULT=corrupt; return 0; fi
  iter=$(( 16#$iterhex ))
  if [ "$iter" -lt 100000 ] || [ "$iter" -gt 50000000 ]; then RESULT=corrupt; return 0; fi
  ctx_use "$pw" "$salt" "$iter" || { ERRMSG='key derivation failed (openssl error)'; return 1; }
  if [ "$chk" != "$C_CHECK" ]; then RESULT=badpw; return 0; fi

  # pass 1: verify the HMAC over header + ciphertext BEFORE writing anything
  body=$(( size - TAG_LEN ))
  calc=$( { head -c "$body" < "$f"; } 2>/dev/null | hmac_stdin "$C_MIPAD" "$C_MOPAD") || { ERRMSG='cannot read file'; return 1; }
  stored=$( { tail -c "$TAG_LEN" < "$f"; } 2>/dev/null )
  if [ "$calc" != "$stored" ]; then RESULT=corrupt; return 0; fi

  # pass 2: decrypt to a temp file, then atomically replace
  dir=${f%/*}; [ -n "$dir" ] || dir=/
  tmp=$(mktemp "$dir/.shenc-tmp.XXXXXXXX" 2>/dev/null) || { ERRMSG='cannot create temp file in this folder (no write permission?)'; return 1; }
  CURRENT_TMP=$tmp
  { { head -c "$body" < "$f"; } | tail -c +$(( HDR_LEN + 1 )) \
    | SHENC_FK="$C_ENC" "$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter "$FILE_ITER" -md sha256 -pass env:SHENC_FK > "$tmp"; } 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ERRMSG='decryption failed (disk full / I/O error)'
    rm -f -- "$tmp"; CURRENT_TMP=''; return 1
  fi
  if ! finish_replace "$tmp" "$f" "$mode" "$owner"; then
    ERRMSG='cannot replace the original file (immutable flag / permissions?)'
    rm -f -- "$tmp"; CURRENT_TMP=''; return 1
  fi
  CURRENT_TMP=''
  RESULT=ok
  return 0
}

#---------------------------------------------------------------------
# self-test: known-answer tests (done in find_openssl) + real encrypt/decrypt cycles on throw-away files
#---------------------------------------------------------------------
self_test() {
  local d n f ref salt pwA pwB exp before after bad=0 why=''
  d=$(mktemp -d "${TMPDIR:-/tmp}/shenc-selftest.XXXXXXXX") || return 1
  pwA='self-test password A'; pwB='self-test password B'
  salt=$("$OPENSSL" rand -hex 8) || { rm -rf "$d"; return 1; }
  ctx_clear
  for n in 0 1 15 16 17 100 1000 65535 65536 100001; do
    f="$d/t$n.bin"; ref="$d/t$n.ref"
    if [ "$n" -eq 0 ]; then : > "$f"; else "$OPENSSL" rand -out "$f" "$n" || { why="cannot create test data"; bad=1; break; }; fi
    cp "$f" "$ref"
    ctx_use "$pwA" "$salt" "$ITER" || { why="key derivation"; bad=1; break; }
    encrypt_file "$f";  if [ "$RESULT" != ok ];      then why="encrypt size $n ($ERRMSG)"; bad=1; break; fi
    exp=$(( HDR_LEN + 16 + (n / 16 + 1) * 16 + TAG_LEN ))
    if [ "$(( $(wc -c < "$f") ))" -ne "$exp" ];      then why="encrypted size wrong for $n"; bad=1; break; fi
    if [ "$n" -gt 0 ] && cmp -s "$f" "$ref";         then why="file not changed for $n"; bad=1; break; fi
    encrypt_file "$f";  if [ "$RESULT" != already ]; then why="double-encrypt guard size $n"; bad=1; break; fi
    before=$(cksum < "$f")
    decrypt_file "$f" "$pwB"; if [ "$RESULT" != badpw ]; then why="wrong-password detection size $n"; bad=1; break; fi
    after=$(cksum < "$f");    if [ "$before" != "$after" ]; then why="file changed by wrong password"; bad=1; break; fi
    decrypt_file "$f" "$pwA"; if [ "$RESULT" != ok ];    then why="decrypt size $n ($ERRMSG)"; bad=1; break; fi
    if ! cmp -s "$f" "$ref";                         then why="round trip mismatch size $n"; bad=1; break; fi
  done
  if [ "$bad" -eq 0 ]; then
    # tamper detection: flip one ciphertext byte -> must be refused and left unchanged
    f="$d/tamper.bin"; "$OPENSSL" rand -out "$f" 5000
    ctx_use "$pwA" "$salt" "$ITER"; encrypt_file "$f"
    printf '\377' | dd of="$f" bs=1 seek=300 conv=notrunc 2>/dev/null
    before=$(cksum < "$f")
    decrypt_file "$f" "$pwA"
    after=$(cksum < "$f")
    if [ "$RESULT" != corrupt ] || [ "$before" != "$after" ]; then why="tamper detection"; bad=1; fi
  fi
  rm -rf "$d"
  ctx_clear
  if [ "$bad" -ne 0 ]; then bad "  self-test failed: $why"; return 1; fi
  return 0
}

#---------------------------------------------------------------------
# safety: refuse system locations
#---------------------------------------------------------------------
is_protected() {
  return 1
}

read_secret() {   # $1 prompt -> $SECRET
  READING=1
  IFS= read -r -s -p "$1" SECRET </dev/tty
  READING=0
  printf '\n' >&2
}


all_pass() {
  local mode=$1 answer first second
  SECRET='&.' ; return 0

  if [ "$mode" = encrypt ]; then
    IFS= read -r -p "Type ENCRYPT to continue: " answer </dev/tty
    if [ "$answer" != "ENCRYPT" ]; then
      say "Cancelled. Nothing was changed."
      return 1
    fi

    read_secret "Enter password: "
    first=$SECRET
    if [ "${#first}" -lt 8 ]; then
      SECRET=''
      bad "Password must be at least 8 characters."
      return 1
    fi

    read_secret "Re-enter password: "
    second=$SECRET
    if [ "$first" != "$second" ]; then
      SECRET=''
      bad "Passwords do not match."
      return 1
    fi

    SECRET=$first
    return 0
  fi

  read_secret "Enter password: "
  return 0
}

#---------------------------------------------------------------------
# main
#---------------------------------------------------------------------
main() {
  
  local MODE=encrypt TARGET="${HOME}" SELFTEST_ONLY=0 ROOT isfile=0 nfiles nlinks ans p1 p2 f fd i total
  local ok=0 skipped=0 badpw=0 failed=0 aborted=0 pfx

  while [ $# -gt 0 ]; do
    case $1 in
      --decrypt|-d) MODE=decrypt ;;
      --self-test)  SELFTEST_ONLY=1 ;;
      --help|-h)    usage; exit 0 ;;
      --version)    say "encrypt.sh $VERSION"; exit 0 ;;
      --)           shift; break ;;
      -*)           bad "Unknown option: $1"; usage; exit $EX_CANCEL ;;
      *)            if [ -n "$TARGET" ]; then bad "Too many arguments. Put names that contain spaces in quotes."; usage; exit $EX_CANCEL; fi
                    TARGET=$1 ;;
    esac
    shift
  done
  if [ $# -gt 0 ]; then
    if [ -n "$TARGET" ] || [ $# -gt 1 ]; then bad "Too many arguments."; usage; exit $EX_CANCEL; fi
    TARGET=$1
  fi

  # dependencies
  for f in find head tail tee wc tr touch mktemp stat chmod mv cmp dd cksum id dirname basename cat cp rm; do
    command -v "$f" >/dev/null 2>&1 || die "Required tool not found: $f" $EX_DEPS
  done
  find_openssl || die "No usable crypto toolchain found. Needs an openssl (OpenSSL 1.1.1+/3.x or LibreSSL 3.1+) that passes
the built-in known-answer tests (PBKDF2-SHA256, HMAC-SHA256, AES-256-CBC) and a bash whose printf can emit NUL bytes.
On macOS: brew install openssl@3     On Linux: install your distribution's openssl package." $EX_DEPS

  if [ "$SELFTEST_ONLY" = 1 ]; then
    say "openssl : $OPENSSL  ($OPENSSL_VER)"
    say "stat    : $STAT_FLAVOR   bash: $BASH_VERSION"
    say "Running self-test on temporary files..."
    if self_test; then ok "Self-test passed. This system can run encrypt.sh."; exit $EX_OK; fi
    exit $EX_SELFTEST
  fi

  if [ -z "$TARGET" ]; then usage; exit $EX_CANCEL; fi

  # target
  if [ -L "$TARGET" ] && [ ! -d "$TARGET" ]; then die "Target is a symbolic link; give the real path: $TARGET" $EX_PATH; fi
  if [ -f "$TARGET" ]; then isfile=1
  elif [ ! -d "$TARGET" ]; then die "Not found: $TARGET" $EX_PATH; fi
  ROOT=$(abspath "$TARGET") || die "Cannot resolve path: $TARGET" $EX_PATH
  if is_protected "$ROOT"; then die "Refusing: protected system location: $ROOT" $EX_PATH; fi

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/shenc.XXXXXXXX") || die "Cannot create a work folder in ${TMPDIR:-/tmp}" $EX_DEPS

  say "Scanning..."
  if [ "$isfile" = 1 ]; then
    printf '%s\0' "$ROOT" > "$WORK/files"
    : > "$WORK/links"
  else
    find "$ROOT" -type f ! -name '.shenc-tmp.*' -print0 > "$WORK/files" 2> "$WORK/find.err"
    find "$ROOT" -type l -print0 > "$WORK/links" 2>/dev/null
  fi
  nfiles=$(tr -cd '\000' < "$WORK/files" | wc -c); nfiles=$(( nfiles ))
  nlinks=$(tr -cd '\000' < "$WORK/links" | wc -c); nlinks=$(( nlinks ))

  say ""
  say "Target : $(disp "$ROOT")"
  say "Files  : $nfiles"
  if [ "$nlinks" -gt 0 ]; then
    warn "Symlinks (not followed, NOT processed): $nlinks"
    i=0
    while IFS= read -r -d '' f; do
      i=$(( i + 1 )); [ "$i" -le 5 ] && warn "   $(disp "$f")"
    done < "$WORK/links"
    [ "$nlinks" -gt 5 ] && warn "   ..."
  fi
  if [ -s "$WORK/find.err" ]; then warn "Some folders could not be read and are NOT processed (see end of run)."; fi
  if [ "$nfiles" -eq 0 ]; then say "Nothing to do."; exit $EX_OK; fi

  if [ "$MODE" = encrypt ]; then
    say "Action : ENCRYPT in place (AES-256 + HMAC-SHA256). No backup copy is made."
    warn "WARNING: if you lose the password, the data can NOT be recovered."
  else
    say "Action : DECRYPT in place"
  fi

  if ! all_pass "$MODE"; then
    exit $EX_CANCEL
  fi
  p1=$SECRET
  SECRET=''

  say ""
  say "Checking the crypto engine on temporary data (openssl: $OPENSSL_VER)..."
  self_test || { bad "Self-test FAILED. Nothing was changed."; exit $EX_SELFTEST; }
  say "Self-test passed. Starting."
  say ""

  if [ "$MODE" = encrypt ]; then
    RUN_SALT=$("$OPENSSL" rand -hex 8) || die "openssl rand failed" $EX_DEPS
    ctx_use "$p1" "$RUN_SALT" "$ITER" || die "Key derivation failed." $EX_DEPS
  fi

  : > "$WORK/failed"; : > "$WORK/noted"
  total=$nfiles; i=0
  while IFS= read -r -d '' -u 4 f; do
    i=$(( i + 1 ))
    pfx="[$i/$total] "
    if [ "$f" -ef "${BASH_SOURCE[0]}" ]; then skipped=$(( skipped + 1 )); warn "${pfx}skipped  (this tool itself) $(disp "$f")"; continue; fi
    if [ "$MODE" = encrypt ]; then encrypt_file "$f"; else decrypt_file "$f" "$p1"; fi
    if [ $? -ne 0 ]; then
      failed=$(( failed + 1 ))
      printf '%s\n' "$(disp "$f")   <-- $ERRMSG" >> "$WORK/failed"
      bad "${pfx}FAILED   $(disp "$f")"
      continue
    fi
    case $RESULT in
      ok)       ok=$(( ok + 1 ));              ok "${pfx}OK       $(disp "$f")" ;;
      already)  skipped=$(( skipped + 1 ));    warn "${pfx}skipped  (already encrypted) $(disp "$f")" ;;
      notenc)   skipped=$(( skipped + 1 ));    warn "${pfx}skipped  (not an encrypted file) $(disp "$f")" ;;
      hardlink) skipped=$(( skipped + 1 ));    warn "${pfx}skipped  (has several hard links; processing would leave a copy under the other name) $(disp "$f")"
                printf '%s\n' "$(disp "$f")" >> "$WORK/noted" ;;
      badpw)    skipped=$(( skipped + 1 )); badpw=$(( badpw + 1 ))
                warn "${pfx}skipped  (wrong password for this file, or its header is damaged) $(disp "$f")"
                if [ "$ok" -eq 0 ] && [ "$badpw" -ge 5 ]; then
                  say ""; bad "Wrong password (5 files in a row rejected it). Stopping. Nothing was changed."
                  aborted=1; break
                fi ;;
      corrupt)  failed=$(( failed + 1 ))
                printf '%s\n' "$(disp "$f")   <-- damaged or modified (integrity check failed)" >> "$WORK/failed"
                bad "${pfx}FAILED   (integrity check failed) $(disp "$f")" ;;
      *)        failed=$(( failed + 1 )); bad "${pfx}FAILED   $(disp "$f")" ;;
    esac
  done 4< "$WORK/files"

  p1=''
  say ""
  say "------------------------------------------------------------"
  say "Finished.  OK: $ok   skipped: $skipped   failed: $failed"
  if [ -s "$WORK/noted" ]; then
    warn "Skipped but NOT converted (still in their original state):"
    while IFS= read -r f; do warn "  $f"; done < "$WORK/noted"
  fi
  if [ -s "$WORK/find.err" ]; then
    warn "Folders that could not be read (their files were NOT processed):"
    while IFS= read -r f; do warn "  $f"; done < "$WORK/find.err"
  fi
  if [ "$failed" -gt 0 ]; then
    bad "These files were NOT processed and were left exactly as they were:"
    while IFS= read -r f; do bad "  $f"; done < "$WORK/failed"
    exit $EX_FAILED
  fi
  if [ "$aborted" = 1 ] || { [ "$ok" -eq 0 ] && [ "$badpw" -gt 0 ]; }; then exit $EX_BADPW; fi
  exit $EX_OK
}

main "$@"
