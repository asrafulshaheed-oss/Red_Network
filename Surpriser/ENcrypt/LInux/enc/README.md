# encrypt — in-place file & folder encryption (Windows · Linux · macOS)

> **Hand-off document for an AI coding agent.** Read it completely, then go to **[9. START HERE](#9-start-here)**.
> Everything stated as "tested" below was actually executed; everything not executed is labelled **UNVERIFIED**.

---

## 1. The job in one paragraph

Build and maintain a **personal, interactive command-line tool that encrypts — and later decrypts — a file or an entire folder tree in place**, protected by a password the person chooses. It ships as **two scripts**:

| Script | Platform | Language |
|---|---|---|
| `encrypt.vbs` | Windows 11 | VBScript launcher + embedded PowerShell engine |
| `encrypt.sh` | Linux (any distro) and latest macOS | bash + the system `openssl` command |

Encryption must be strong, work for **any file size** (KB to > 1 PB — streaming only, never load a file into memory), recurse through **any number of nested folders**, leave **no backup copy**, and be impossible to reverse without the password. The tool protects **the user's own data**: it is interactive and consent-based (like 7-Zip / gpg / AxCrypt), never a background or silent process.

### Project history (so you know what is already settled)
1. User asked for a VBS script for Windows → `encrypt.vbs` delivered. **The user ran it and reported it works perfectly.**
2. User asked for the equivalent for Linux (any distro) + latest macOS in bash → `encrypt.sh` delivered (this document's main subject).
3. User asked for this README so the project can be handed to another AI agent.

---

## 2. Requirements (acceptance criteria — do not drop any)

These are the user's own requirements, stated for Windows and applied identically to the bash version (`encrypt.sh` replaces `encrypt.vbs`).

| # | Requirement |
|---|---|
| R1 | One script per platform family; Windows = latest Windows (11); Unix = **any Linux distro** and **latest macOS**, in **bash**. |
| R2 | Encrypt: `encrypt.vbs [file/folder]` / `./encrypt.sh [file/folder]` run from a terminal. |
| R3 | It must **ask the user to type `ENCRYPT`** to confirm. |
| R4 | Then ask for a **password** (used later for decryption) and ask to **re-enter it** for confirmation. |
| R5 | Only if both passwords match does it encrypt. |
| R6 | Folders may contain many files and **folders inside folders** (any depth). |
| R7 | **Size does not matter**: smaller than 1 MB up to larger than 1 PB. |
| R8 | Encryption must be **very strong**; impossible to decrypt without the correct password. |
| R9 | Decrypt: `encrypt.vbs --decrypt [file/folder]` / `./encrypt.sh --decrypt [file/folder]`, then ask for the password; decrypt only if it is correct. |
| R10 | **Do not delete** the user's files/folders — encrypt the ones named. (Interpretation: contents are transformed in place; nothing is removed from the tree; names stay.) |
| R11 | **Do not make backup copies** of the files or folders. |

Requirements the author added (not asked by the user, but sensible; reversible if the user objects): minimum password length 8, refusal to touch system locations, a self-test before touching data, skipping of symlinks/hard links.

---

## 3. Status at a glance

| Deliverable | Platform | Status |
|---|---|---|
| `encrypt.vbs` | Windows 11 | **Working** — the user ran it end to end and confirmed. The author never executed it (no Windows available) and there is **no automated test suite** for it. |
| `encrypt.sh` | **Linux** | **Tested** in a sandbox (Linux x86_64, bash 5.2.21, OpenSSL 3.0.13, GNU coreutils; as root and as uid 65534). See §6.9. **Not tested** on other distros / openssl versions (Alpine/BusyBox, RHEL FIPS mode, OpenSSL 1.1.1, LibreSSL). |
| `encrypt.sh` | **macOS** | **UNVERIFIED — never executed on a Mac.** Statically reviewed for bash 3.2 and BSD tools; the BSD `stat` branch was simulated with a shim; startup known-answer tests will refuse to run on a system whose openssl/printf misbehave. **This is the first thing to verify (§9).** |

`encrypt.sh`: 564 lines, 25,617 bytes, version string `1.0`, sha256 starts `4915973b9e14d26a`.

---

## 4. Files

| File | Purpose |
|---|---|
| `encrypt.vbs` | Windows deliverable (launcher + embedded PowerShell engine, all in one ASCII/CRLF file). |
| `encrypt.sh` | Linux/macOS deliverable (single bash file, no other files needed). |
| `README.md` | This document. Appendices A–D contain portable **test tooling** to copy out (`drive.py`, `mktree.sh`, `snap.sh`, `core_test.sh`). |

**The two formats are NOT interchangeable.** A file encrypted by `encrypt.vbs` cannot be decrypted by `encrypt.sh` and vice-versa (different magic, header, salt size, key schedule).

---

## 5. The two implementations side by side

| | `encrypt.vbs` (Windows) | `encrypt.sh` (Linux/macOS) |
|---|---|---|
| Runtime | VBScript → Windows PowerShell 5.1 + .NET Framework ≥ 4.7.2 | bash ≥ 3.2 (macOS stock) + `openssl` CLI (OpenSSL 1.1.1+/3.x or LibreSSL 3.1+) |
| Where prompts appear | A **new PowerShell window** (masked `Read-Host -AsSecureString`) | The **same terminal** (`read -s` from `/dev/tty`) |
| KDF | PBKDF2-HMAC-SHA256, 600,000 iterations, 16-byte salt per run | PBKDF2-HMAC-SHA256, 600,000 iterations, **8-byte** salt per run (openssl `-S` limit) |
| Cipher | AES-256-CBC + PKCS7 (.NET) | AES-256-CBC + PKCS7 (`openssl enc`) |
| Integrity | HMAC-SHA256, encrypt-then-MAC, raw 32-byte tag | HMAC-SHA256, encrypt-then-MAC, **64 hex chars** tag, HMAC hand-built from `printf` + `openssl dgst` |
| Per-file keys | `HMAC(master,"enc"‖nonce)`, `HMAC(master,"mac"‖nonce)`, random IV | `openssl enc -pbkdf2 -iter 1000 -salt` with `encSecret` as pass → unique key+IV; one run-level MAC key |
| Magic / header | `VBSENC01`, 76-byte binary header | `SHENC001`, 65-byte ASCII header |
| Minimum encrypted size | 124 bytes | 161 bytes |
| In-place method | temp file + `File.Replace(tmp, orig, $null)` | temp file + `mv -f` (after `touch -r`, `chown`, `chmod`) |
| Skips | reparse points (symlinks/junctions/OneDrive placeholders) | symlinks, **hard-linked files**, itself, `.shenc-tmp.*` |
| Self-test before use | yes (11 sizes, 64-byte buffer) | yes (4 known-answer tests + 10 sizes + wrong-password + tamper) |
| Exit codes | 0–5 | 0–6 (+130 interrupted) |
| Min password | 8 chars | 8 chars |

---

## 6. `encrypt.sh` (Linux & macOS)

### 6.1 Usage
```
./encrypt.sh <file-or-folder>              # encrypt: type ENCRYPT, then password twice
./encrypt.sh --decrypt <file-or-folder>    # decrypt: password once   (-d also accepted)
./encrypt.sh --self-test                   # checks the toolchain; touches no user files
./encrypt.sh --help | --version
./encrypt.sh -- -weird-name                # "--" for a name that starts with a dash
```
Names with spaces must be quoted. Exactly one target per run. Needs an interactive terminal (it prompts on `/dev/tty`). `chmod +x encrypt.sh` first, or run `bash encrypt.sh …`.

### 6.2 Flow
```
parse args → check required tools → find a working openssl (known-answer tests)
  → (--self-test? run it and exit)
  → need /dev/tty → target must exist; symlink target refused; resolve physical path
  → protected-location guard → scan with `find -print0` into a work file (symlinks listed, not followed)
  → show Target / Files count
  → ENCRYPT: "Type ENCRYPT" → password → re-enter → ≥8 chars & equal      DECRYPT: password
  → self-test on throw-away files in $TMPDIR
  → ENCRYPT only: random 8-byte run salt, derive keys once (PBKDF2 600k)
  → for each file: encrypt_file / decrypt_file   → one status line per file
  → summary (OK / skipped / failed, lists of failures, unreadable folders, hard links) → exit code
```

### 6.3 Cryptographic design

1. `K1` = the first 32 bytes of **PBKDF2-HMAC-SHA256(password, salt8, 600000)**. Obtained from `openssl enc -aes-256-cbc -pbkdf2 -iter N -md sha256 -S <salt> -P -pass env:VAR` (the printed `key=` is PBKDF2 block T1, i.e. standard PBKDF2 with dkLen = 32 — verified against Python `hashlib.pbkdf2_hmac`).
2. Key separation with HMAC-SHA256 keyed by `K1`:
   `encSecret = HMAC(K1,"shenc-enc-v1")`, `macKey = HMAC(K1,"shenc-mac-v1")`, `check = HMAC(K1,"shenc-check-v1")[0..16 bytes]` (32 hex chars, stored in every header → wrong password is detected from the header alone, without reading the file body).
3. **Per file:** `openssl enc -aes-256-cbc -pbkdf2 -iter 1000 -md sha256 -salt -pass env:SHENC_FK` with the 64-hex-char `encSecret` as the "password". openssl writes `Salted__` + a fresh random 8-byte salt, so **every file gets a unique key and IV**. (1000 iterations because the input is already a 256-bit random secret — more would add no security; 1000 is also the FIPS-provider minimum.)
4. **Integrity:** `tag = HMAC-SHA256(macKey, header ‖ openssl-output)`, appended as 64 hex chars. Decrypt verifies it **before writing any plaintext** (two-pass), so a wrong/tampered file never produces output.
5. **HMAC is hand-built** as `H((K⊕opad) ‖ H((K⊕ipad) ‖ msg))`: the two 64-byte pad blocks are emitted by `printf '\xHH…'` and hashed with `openssl dgst -sha256 -binary`. **Reason: `openssl dgst -hmac KEY` and `-macopt hexkey:KEY` put the key on the command line, visible to every local user via `ps`.** Verified byte-for-byte against Python `hmac` for a short message, an empty message, a 5 MB binary message, and a key whose pads contain NUL bytes.
6. **Secrets never appear in argv.** The password reaches openssl only as an environment variable of that single child process (`SHENC_PW=… openssl … -pass env:SHENC_PW`); derived secrets travel via env vars/pipes/shell builtins. (A running process's environment is readable by the same user and root — the same trust boundary as the shell itself.)
7. **Why this construction** (do not "simplify" without reading this): `openssl enc` has no AEAD mode → CBC + HMAC (encrypt-then-MAC). `openssl kdf` exists only in OpenSSL 3 (not macOS LibreSSL) → PBKDF2 via `enc -P`. `-K/-iv` flags put keys in argv → avoided. `gpg` is not installed on macOS and needs agent/pinentry. Python has no AES in its standard library and is not guaranteed on either OS. Only `openssl` is on every Linux and every Mac.
8. Password handling: bytes as typed (no Unicode normalisation), `LC_ALL=C` forced for the whole script. Cleared from shell variables at the end (best effort; bash cannot guarantee zeroing memory).

### 6.4 On-disk format (file keeps its name; no extension is added)

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `SHENC001` |
| 8 | 8 | PBKDF2 iterations, lowercase hex (`000927c0` = 600000) |
| 16 | 16 | PBKDF2 salt, hex (8 bytes) |
| 32 | 32 | password check value, hex (16 bytes) |
| 64 | 1 | newline (header = 65 bytes) |
| 65 | 8 | `Salted__` |
| 73 | 8 | per-file salt (binary) |
| 81 | N | AES-256-CBC ciphertext, N multiple of 16, N ≥ 16 |
| 81+N | 64 | HMAC-SHA256 (hex) over bytes `[0, 81+N)` |

`encrypted_size = 65 + 16 + (floor(plain/16)+1)*16 + 64`. An empty file becomes 161 bytes. The script (and the tests) verify this formula exactly.

### 6.5 In-place safety — how "no backup, no data loss" is achieved

Per file, in order: readable? → one `stat` call for `nlink/mode/uid:gid` → hard-linked (nlink > 1)? skip → already has magic? skip → `mktemp "<dir>/.shenc-tmp.XXXXXXXX"` (same folder ⇒ same filesystem, created mode 600) → **single pass** `{ header; openssl enc < file; } | tee tmp | hmac` → append tag → `touch -r original tmp` (mtime) → `chown uid:gid` (root only) → `chmod mode` (a failure is tolerated only if the temp file already has that mode, e.g. FAT/exFAT mounts) → **`mv -f tmp original`** (atomic rename).

* On any failure: temp file removed, **original untouched**, file listed under "NOT processed", exit code 4.
* `trap` on INT/TERM/HUP/EXIT removes the current temp file and the work folder; exit 130. **`kill -9` or power loss cannot be trapped** and may leave a stray `.shenc-tmp.*` beside the file being processed. **When decrypting, that stray file holds (partial) PLAINTEXT (mode 600)** — delete it: `find <folder> -name '.shenc-tmp.*'`. The original is intact in both cases.
* Free space ≥ size of the **largest single file** is needed temporarily.
* **Preserved:** content semantics, mtime, mode (incl. setuid bits), owner/group (when run as root). **Lost** (new inode): birth time, extended attributes, ACLs, macOS resource forks / Finder tags / quarantine flag, hard-link relationships.

### 6.6 Safety rails (keep all of them — there is no backup)

* Typed confirmation `ENCRYPT` (case-sensitive); password twice; minimum 8 characters.
* Refuses to run without a terminal (`/dev/tty`).
* **Protected-location guard** (`is_protected`, 41 unit cases for macOS + Linux paths). Refused *exactly*: `/ /bin /boot /cores /dev /etc /home /lib /lib32 /lib64 /libx32 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var /Users /Volumes /System /Library /Applications /private /private/tmp /private/var /private/etc`, `$HOME`, `$HOME/Library`. Refused *including everything inside*: `/bin /boot /dev /etc /lib* /proc /run /sbin /sys /usr /System /Library /Applications /private/etc /private/var/db`. Subfolders such as `$HOME/Documents`, `/opt/data`, `/mnt/disk/x`, `/tmp/x` are allowed.
* A target that is itself a symlink is refused (give the real path). Symlinks inside the tree are listed and **not** followed or processed.
* Hard-linked files are skipped and listed as "NOT converted" (renaming over one name would leave plaintext under the other).
* Skips itself (`-ef` same-inode test, works through symlinks) and any `.shenc-tmp.*`.
* **Self-test before touching data** (`--self-test` runs it alone): 4 known-answer tests (PBKDF2, HMAC incl. a NUL-forcing key, AES round trip, `rand`), then real encrypt/decrypt cycles on throw-away files of sizes 0, 1, 15, 16, 17, 100, 1000, 65535, 65536, 100001 (size formula, "already encrypted" guard, wrong-password rejection leaving the file unchanged, exact round trip) plus tamper detection.
* Wrong password: files skipped quickly (header check); **after 5 consecutive rejections with zero successes the run stops** (exit 5). Mixed-password trees work (files of another password are skipped).
* Honest summary: OK / skipped / failed counts; every failed file with a reason; unreadable folders; non-zero exit if anything failed.

### 6.7 CLI, exit codes, per-file statuses

| Exit | Meaning |
|---|---|
| 0 | success |
| 1 | cancelled, bad input, mismatching/short password, usage error |
| 2 | target not found / protected location / target is a symlink |
| 3 | self-test failed (nothing changed) |
| 4 | some files failed (all others processed; failed ones untouched) |
| 5 | wrong password / run aborted |
| 6 | missing or unusable toolchain (no suitable openssl, missing tool) |
| 130 | interrupted (Ctrl+C / TERM / HUP) |

Per-file line: `OK` · `skipped (already encrypted | not an encrypted file | has several hard links | wrong password…)` · `FAILED (integrity check failed | <reason>)`.

### 6.8 Portability decisions (macOS stock bash 3.2 and BSD tools vs GNU)

* **bash 3.2-safe only:** no associative arrays (parallel indexed arrays are used for the key cache), no `mapfile/readarray`, no `${var,,}`, no `|&`, no `declare -n`, no `set -u` (empty-array bug), no negative substring offsets. Uses `printf -v`, `+=`, `read -d '' -u 4`, `[ a -ef b ]`, `$'…'` (all in 3.2). A scan for bash-4+ constructs and GNU-only flags (`readlink -f`, `sed -i`, `date -d`, `find -printf`, `grep -P`, `sort -z`, `touch -d`, `cp --`, …) found none.
* **GNU vs BSD:** `stat` flavour auto-detected (`stat -c '%h %a %u:%g'` vs `stat -f '%l %Lp %u:%g'`); `mktemp` templates end in `XXXXXXXX`; `touch -r`; `head -c`; `tail -c +N`; `tr -d '\000'`; `find -type f -print0`; `wc -c` output trimmed by arithmetic.
* **openssl discovery order:** `openssl` on PATH, `/opt/homebrew/opt/openssl@3/bin/openssl`, `/usr/local/opt/openssl@3/bin/openssl`, `/opt/homebrew/bin/openssl`, `/usr/local/bin/openssl`, `/usr/bin/openssl`. The first one passing all known-answer tests wins. macOS's `/usr/bin/openssl` is LibreSSL (3.3.6 on recent releases, **UNVERIFIED for the newest macOS**); if it lacks `enc -pbkdf2 -iter -S -P`, the script falls back to Homebrew's openssl or tells the user to `brew install openssl@3`.

### 6.9 What was actually tested (Linux sandbox)

Environment: Linux x86_64 kernel 6.18, **1 CPU core**, bash 5.2.21, OpenSSL 3.0.13, GNU coreutils; root and uid 65534. All driven through a real pseudo-terminal (see Appendix A).

| Test | Result |
|---|---|
| `--self-test` | passes in ≈1.5 s |
| Portable core test (Appendix D) | **21/21 in 10 of 11 runs** of the final script; the one exception failed 2 assertions (see the intermittent-blip note below) |
| GNU regression suite (26 assertions; same scenarios plus mode/mtime details) | **26/26** on 4 consecutive full runs, and again on 1 run after the last patch (the `chmod` tolerance). One earlier run had 1 failing assertion — see the blip note |
| Nasty tree (22 files): spaces, **newline in name**, quotes/`$`/backtick, unicode, leading dash, hidden files, 6-deep nesting, empty file, exact-4 MiB and 4 MiB+1 files, read-only, executable, 0600, symlinks, hard-link pair | 20 encrypted, 2 hard links skipped & reported, symlinks untouched; after decrypt **every file's SHA-256, mode and mtime equals the original** |
| Format checks | magic present; size formula exact; no plaintext in ciphertext; ciphertext uses all 256 byte values; no `.shenc-tmp.*` left |
| Wrong password | exit 5 after 5 rejections; tree byte-identical |
| Tampered file / truncated file | `FAILED (integrity check failed)`, file **byte-identical afterwards**; other files decrypt |
| **2 GiB random file** | ≈10 s encrypt / ≈10 s decrypt (≈200 MB/s), **peak RSS 8 MiB**, size exact, SHA-256 identical |
| Ctrl+C in the middle of a 1.5 GB file | exit 130, current file original, no temp/work leftovers; later decrypt restores everything exactly |
| Two different passwords in one tree | each decrypts only its own files |
| Six hostile passwords (quotes, `$HOME`, backticks, leading `-`, leading/trailing spaces, unicode+emoji, `\n %s %d`, shell metacharacters) | all round-trip |
| Unprivileged user (uid 65534) | unwritable folder → `FAILED (no write permission)`; unreadable file → `FAILED (not readable)`; nothing changed; owner/mode preserved; no stray bash error output |
| Failing-`chmod` shim (fixed-mask filesystem simulation) | tolerated when the mode already matches; refused (file untouched) when it cannot be matched |
| 1,500 and 3,000 small files | ≈29–35 ms per file (≈ 50 min per 100,000 files on this slow 1-core VM) |
| Protected paths | refused for every existing path tested; `is_protected` unit-tested with 41 macOS+Linux cases |
| Tool inside the target folder | skipped, unchanged |
| BSD `stat` branch | exercised with a shim emulating BSD `stat` (format parsing only) |
| Sabotaged `printf` that mangles NUL bytes | script **refuses to start** (exit 6) thanks to the NUL-forcing known-answer test |
| Echo of typed password | 0 leaks in 60 runs; 14 further encrypt+decrypt stress cycles: 0 mismatches |

**Intermittent blips (unexplained — be aware):** early in testing one assertion (single-file round trip, in an older harness) and, in one run, two assertions of the portable core test failed; neither reproduced in > 100 later runs of those scenarios (including the stress loops above). No defect was found in the script, the failures coincided with a 1-core VM under load, and the data-safety checks (self-test, MAC, atomic replace) do not depend on timing. If you ever see an intermittent failure, run with `SHENC_DEBUG=1` (the core test then prints the last driver output) and investigate rather than dismiss.

### 6.10 What is NOT verified (macOS and others)

* Anything on a real Mac: bash 3.2.57 behaviour, `/usr/bin/openssl` (LibreSSL) support for `enc -pbkdf2 -iter -md -S -P -pass env:`, `dgst -sha256 -binary`, `rand -hex`; BSD `head -c`, `tail -c +N`, `tr`, `mktemp`, `touch -r`, `stat -f`, `cksum`, `dd`, `find -print0`.
* `printf '\x00'` in bash 3.2 (the NUL-forcing known-answer test makes a failure *loud* at startup, but it has never run there).
* `read -s -p … </dev/tty` in Terminal.app / iTerm2, Ctrl+C echo restoration.
* macOS privacy (TCC) prompts, SIP, immutable flags (`chflags uchg`), iCloud "dataless" files, APFS specifics, extended attributes.
* Linux: Alpine/BusyBox, RHEL/Fedora in FIPS mode, OpenSSL 1.1.1, vfat/exfat/NTFS/NFS/btrfs/ZFS behaviour, SELinux/AppArmor contexts, `chattr +i` files.

---

## 7. `encrypt.vbs` (Windows)

### 7.1 Usage
```
cscript //nologo encrypt.vbs "C:\Data\Secret"             → new PowerShell window: type ENCRYPT, password ×2
cscript //nologo encrypt.vbs --decrypt "C:\Data\Secret"   → new window: password
```
`encrypt.vbs "<path>"` also works (default host `wscript`). Quote names with spaces; one target per run.

### 7.2 Architecture
```
encrypt.vbs (launcher, top ≈100 lines)
  1 parse args (--decrypt/-d, one path), strip stray trailing \ or ", make absolute, check exists
  2 read ITS OWN file; every line starting with  '|  is PowerShell  (VBScript treats them as comments)
  3 write the engine to %TEMP%\vbsenc_<random>.ps1
  4 powershell.exe -NoProfile -ExecutionPolicy Bypass -File <tmp> -Mode Encrypt|Decrypt -Target "<abs>" -Skip "<this vbs>"
    via WshShell.Run(window style 1, wait) → a NEW console window; all interaction happens there
  5 delete temp .ps1, exit with the engine's exit code
engine (PowerShell, embedded): path guard → scan → [ENCRYPT] → masked password ×2 → self-test → per-file → summary → "Press Enter to close"
```
Why VBS is only a launcher: no crypto, no masked input. Why a new window: `wscript` has no console; `WshScriptExec` pipes break masked `Read-Host`. **Editing rules:** keep every engine line prefixed `'|`; keep the file **ASCII-only** and **CRLF**; engine must be > 1000 chars (launcher sanity check). To work on the engine as a normal script (PowerShell):
```powershell
Get-Content .\encrypt.vbs | Where-Object { $_.StartsWith("'|") } | ForEach-Object { $_.Substring(2) } | Set-Content .\engine.ps1 -Encoding ASCII
```
Rebuild: keep the VBS above the `'|` block, append `engine.ps1` with `'|` prefixed to every line, CRLF, ASCII.

### 7.3 Crypto and format
AES-256-CBC (PKCS7) + HMAC-SHA256 encrypt-then-MAC; PBKDF2-HMAC-SHA256 600,000 iterations, one 16-byte salt per run (master key cached); per-file keys `HMAC(master,"enc"‖nonce)` / `HMAC(master,"mac"‖nonce)`; 4 MiB streaming buffer; decrypt is two-pass (verify MAC, then decrypt).

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `VBSENC01` |
| 8 | 4 | iterations (int32 LE) |
| 12 | 16 | PBKDF2 salt |
| 28 | 16 | password check = `HMAC(master,"pwcheck")[0..15]` |
| 44 | 16 | per-file nonce |
| 60 | 16 | AES IV |
| 76 | N | ciphertext (multiple of 16) |
| 76+N | 32 | HMAC-SHA256 of bytes `[0, 76+N)` |

In place: temp file in the same folder → flush → copy LastWriteTime → `File.Replace(tmp, orig, $null)` (no backup); ReadOnly attribute cleared for the swap and restored. Safety rails mirror the Unix ones: typed `ENCRYPT`; protected-location guard (drive roots, `%windir%`, `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%` and anything inside them, exact `%USERPROFILE%` and `C:\Users`); self-test before touching data; skips reparse points, itself and its temp `.ps1`; idempotent encrypt; wrong-password fast fail and stop after 5; honest summary; exit codes 0 ok · 1 cancelled/bad input · 2 not found/protected · 3 self-test failed · 4 some failed · 5 aborted.

### 7.4 Windows-specific limitations
Prompts open in a **new window**; paths > 260 characters fail (listed, unchanged); OneDrive placeholders/symlinks/junctions skipped; needs .NET ≥ 4.7.2; **antivirus/SmartScreen may flag** a `.vbs` that drops a `.ps1` and runs `-ExecutionPolicy Bypass` (false positive); **VBScript is being phased out** — a Windows feature-on-demand, still enabled by default on Windows 11 24H2/25H2, planned to become *disabled by default around 2027* (re-enable: Settings → System → Optional features → VBSCRIPT) with later removal (checked Nov 2026). A PowerShell port with the same format (improvement I5) is the long-term answer.

### 7.5 Windows test plan (no automated suite exists; the user's manual run succeeded)
Create `C:\vbstest` (small files, empty file, 4 MiB and 4 MiB+1 files, ~1 GB file via `fsutil file createnew`, nesting ≥ 5, read-only file, unicode/space names). Record `Get-FileHash` before. Then: T1 launch & scan count · T2 lowercase `encrypt` → cancelled · T3 passwords differ → refused · T4 < 8 chars → refused · T5 full encrypt, masked input · T6 file starts with `VBSENC01`, names unchanged, no `*.tmp` · T7 re-encrypt → all skipped · T8 wrong password → skipped, stops after 5, nothing changed · T9 correct password → hashes equal `before` · T10 flip a byte → `FAILED (integrity)`, file unchanged · T11 single file · T12 `C:\`, `C:\Windows`, `C:\Users`, profile root refused · T13 `encrypt.vbs` inside target is skipped · T14 ≥ 1 GB file, flat memory · T15 > 260-char path → FAILED, unchanged · T16 `wscript` and `cscript` both work · T17 kill the window mid-run → no half files · T18 mixed passwords.

---

## 8. Known limitations (be honest about these in any user-facing text)

**Both platforms**
1. **Lost password = lost data.** No recovery, no backup — by the user's own requirement.
2. **File/folder names, sizes, timestamps and the tree structure stay visible.** Only contents are encrypted.
3. **Plaintext remnants on disk** after the swap (freed blocks are not wiped; worse on SSD/CoW/journaling filesystems). Mitigate with full-disk encryption (BitLocker / FileVault / LUKS) and TRIM; Windows: `cipher /w:<folder>`. `shred` is unreliable on modern filesystems.
4. Temporary free space ≥ the largest single file is required.
5. Symlinks/junctions are not followed; hard-linked files are skipped on Unix; skipped items stay in their original state and are listed.
6. A hard kill can leave a stray temp file beside the file being processed (plaintext when decrypting) — originals stay intact.
7. Throughput ≈ 200 MB/s on the 1-core test VM (single stream); small files cost ≈ 30 ms each (process spawning on Unix).

**Unix specific:** metadata that lives outside the file contents (xattrs, ACLs, resource forks, Finder tags, quarantine flag, birth time) is lost; the password lives in shell variables until exit; the derived secret is in a child process's environment while openssl runs; no secret ever touches argv or disk (verified for argv by design review, not by `ps` sampling).

---

## 9. START HERE

### Step 0 — Orient (5 min)
Read §1–§3 and the part of §6/§7 for your platform. `encrypt.sh` is one readable bash file (~560 lines): helpers → crypto primitives (`pad_fmt`, `hmac_stdin`, `kat_all`, `find_openssl`, `ctx_use`) → `encrypt_file` / `decrypt_file` → `self_test` → `is_protected` → `main`.

### Step 1 — Decide your task
| Task | When |
|---|---|
| **A. Verify `encrypt.sh` on a real Mac** (recommended first — it is the only unverified deliverable) | Always first |
| B. Verify on other Linux distros / openssl versions | after A |
| C. Regression-test `encrypt.vbs` on Windows (no suite exists) | if Windows work is requested |
| D. Improvements (§9 Step 6) | only after A passes, and ask the user first |

### Step 2 — First run on macOS (Task A)
```bash
cd <folder containing encrypt.sh>
chmod +x encrypt.sh
xattr -d com.apple.quarantine encrypt.sh 2>/dev/null   # if it was downloaded
/bin/bash --version | head -1                          # expect 3.2.57
/usr/bin/openssl version                               # LibreSSL x.y.z
./encrypt.sh --self-test
```
Expected: `Self-test passed. This system can run encrypt.sh.` (exit 0). Also run it with `/bin/bash ./encrypt.sh --self-test`, and again with Homebrew bash if installed, and with/without Homebrew openssl first in `PATH`.

| Symptom | Likely cause | Action |
|---|---|---|
| `No usable crypto toolchain found` (exit 6) | LibreSSL lacks `enc -pbkdf2/-P/-S/-iter`, **or** bash's `printf` mishandles NUL bytes | run the manual known-answer commands below; `brew install openssl@3` (auto-detected at `/opt/homebrew/opt/openssl@3` or `/usr/local/opt/openssl@3`) |
| `Self-test FAILED: <step>` | a BSD tool behaves differently (`head -c`, `tail -c +N`, `tr`, `mktemp`, `stat -f`, `touch -r`) | the message names the failing size/step; reproduce that step by hand |
| `bad interpreter` / `Permission denied` | missing `+x`, quarantine flag, or CRLF line endings | `chmod +x`, `xattr -d com.apple.quarantine`, `sed -i '' $'s/\r$//' encrypt.sh` |
| `This tool needs an interactive terminal` | no `/dev/tty` | run from Terminal.app / iTerm2 |
| `Operation not permitted` on `~/Documents`, `~/Desktop` | macOS privacy (TCC) | grant the terminal app Full Disk Access |

Manual known-answer commands (each must give the stated result):
```bash
# PBKDF2-HMAC-SHA256 — key must be F8B177BDEC64144719F02B69EE888B2660D125F514100F8861D09A32ED96F3F0
SHENC_T=password openssl enc -aes-256-cbc -pbkdf2 -iter 1000 -md sha256 -S 0001020304050607 -P -pass env:SHENC_T
# printf must emit a real NUL byte — expect exactly "00"
printf '\x00' | od -An -tx1 | tr -d ' \n'; echo
# AES round trip with the options the script uses — expect: round trip
printf 'round trip' | SHENC_T=x openssl enc -aes-256-cbc -pbkdf2 -iter 1000 -md sha256 -salt -pass env:SHENC_T \
  | SHENC_T=x openssl enc -d -aes-256-cbc -pbkdf2 -iter 1000 -md sha256 -pass env:SHENC_T; echo
```

### Step 3 — Run the automated core test (works on macOS and Linux)
Save Appendices A–D next to `encrypt.sh` as `drive.py`, `mktree.sh`, `snap.sh`, `core_test.sh`; `chmod +x *.sh drive.py`; needs `python3` ≥ 3.9 (on macOS: Xcode Command Line Tools).
```bash
ENC=./encrypt.sh ./core_test.sh          # expect: RESULT: 21 passed, 0 failed
SHENC_DEBUG=1 ENC=./encrypt.sh ./core_test.sh   # prints the last driver output next to any FAIL
```
It builds a nasty tree in `$TMPDIR`, runs the real script through a pseudo-terminal, and checks cancel paths, format, size formula, no plaintext, metadata, symlinks, re-encrypt guard, wrong password, exact round trip, tamper detection, protected paths. **Run it several times** (see the intermittent-blip note in §6.9).

### Step 4 — Extended and macOS-only manual tests
All "extended" items passed on Linux (§6.9); re-run them on macOS.

| # | Test | Expected |
|---|---|---|
| X1 | 1–2 GiB random file (`head -c 2147483648 /dev/urandom`) | size formula exact, SHA-256 identical after round trip, process memory stays small |
| X2 | Ctrl+C in the middle of a big file | exit 130, original intact, no `.shenc-tmp.*`, terminal echo still on |
| X3 | Two passwords in one tree | each decrypts only its own files |
| X4 | Passwords with quotes, `$`, backticks, leading `-`, spaces, unicode, `%s`, `\n` | round-trip |
| X5 | Unprivileged-user cases: unwritable folder, unreadable file | `FAILED`, nothing changed |
| X6 | 1,000+ small files | all OK, record ms/file |
| M1 | `chflags uchg file` then encrypt | `FAILED`, file unchanged |
| M2 | File with Finder tag / quarantine xattr / resource fork | note what is lost (documented limitation; see I7) |
| M3 | Folder under `~/Library/Mobile Documents` (iCloud, "dataless" files) | observe; likely should be excluded — report before changing behaviour |
| M4 | NFC vs NFD unicode file names | round-trip exact |
| M5 | External exFAT/FAT drive | works (the failing-`chmod` tolerance) or fails safe |
| M6 | Terminal.app and iTerm2: masked prompts, Ctrl+C restores echo | OK |
| M7 | Protected paths on a Mac: `/System`, `/Library`, `/Applications`, `/Users`, `$HOME`, `~/Library` | `Refusing: protected system location` |

### Step 5 — Fix in this priority order
1. Anything that could **lose or half-convert data** (tamper, truncated, interrupt, wrong password, permissions).
2. Startup/toolchain failures on macOS (Step 2 table).
3. BSD-vs-GNU tool differences revealed by the self-test or core test.
4. UX/message problems. 5. Everything else.

After **every** code change re-run `--self-test` and the core test; never edit the crypto path without re-running the known-answer tests.

### Step 6 — Improvements (ask the user before starting any)
* **I1** Keep the whole Windows dialogue in the **same console** (user's original mental model) — probably via a PowerShell port.
* **I2** Optional **file-name encryption** (random names + encrypted name table).
* **I3** Optional secure-wipe of plaintext remnants / auto `cipher /w`.
* **I4** **One format on every OS** (user could then decrypt anywhere). Needs a common KDF/cipher implementation (e.g. PowerShell 7 or a tiny static binary) and a 16-byte salt on Unix.
* **I5** `encrypt.ps1` PowerShell port with the same format, because VBScript is being disabled by default around 2027.
* **I6** `--dry-run`, progress percentage for huge files, `--verify` (decrypt-and-compare after encrypt), resume after interruption, optional parallelism (keep unique temp names).
* **I7** Preserve macOS metadata (xattrs, resource forks, Finder tags) — e.g. via `xattr`/`ditto` handling.
* **I8** `\\?\` long-path support on Windows.
* **I9** Faster small-file path on Unix (batch several files per openssl invocation is not possible; consider fewer process spawns per file).

---

## 10. Guardrails for the agent

This is a legitimate personal-security tool. Keep it that way:

* **Never** make it run silently/automatically, take the password from the command line, an environment variable or a file, hide its terminal, persist across reboots, spread, use the network, or touch files the user did not explicitly name. The typed `ENCRYPT` + password twice are core features, not obstacles.
* **Never** weaken the crypto: no fixed salts/IVs, no skipping the KDF, no home-made ciphers, no dropping the HMAC or the verify-before-decrypt order, no lowering PBKDF2 below 600,000 iterations, no keys on a command line, no hidden recovery key or backdoor — unless the user explicitly asks for a recovery feature, and then discuss the trade-off first.
* **Never** test on real user data. Never claim something works without having run it on the platform in question (the bash script is untested on macOS; say so until it has been).
* Keep the **self-test**, the **protected-location guard**, the **temp-file-then-atomic-replace** pattern and **HMAC-before-decrypt** — they exist because there is no backup.
* Keep `encrypt.vbs` **ASCII + CRLF** with the `'|` convention; keep `encrypt.sh` **bash-3.2-safe** and free of GNU-only flags.
* State limitations (§8) honestly in any user-facing text.

---

## 11. Quick reference

| Thing | `encrypt.sh` | `encrypt.vbs` |
|---|---|---|
| Magic | `SHENC001` | `VBSENC01` |
| Header / trailer | 65 B ASCII / 64 B hex tag | 76 B binary / 32 B raw tag |
| PBKDF2 | SHA-256, 600,000 it, 8-byte salt | SHA-256, 600,000 it, 16-byte salt |
| Per-file KDF iterations | 1000 | — (HMAC derivation) |
| Cipher / MAC | AES-256-CBC / HMAC-SHA256 | AES-256-CBC / HMAC-SHA256 |
| Confirmation phrase | `ENCRYPT` (case-sensitive) | `ENCRYPT` (case-sensitive) |
| Min password | 8 | 8 |
| Temp files | `<dir>/.shenc-tmp.XXXXXXXX`, work dir `$TMPDIR/shenc.XXXXXXXX` | `<dir>/<name>.<guid>.tmp`, `%TEMP%\vbsenc_*.ps1` |
| Exit codes | 0 ok · 1 cancel/input · 2 path · 3 self-test · 4 failed · 5 wrong pw · 6 toolchain · 130 interrupt | 0 ok · 1 cancel/input · 2 path · 3 self-test · 4 failed · 5 aborted |
| Runtime needs | bash ≥ 3.2, openssl, find/head/tail/tee/wc/tr/touch/mktemp/stat/chmod/mv/cmp/dd/cksum/id/cp/rm | Windows 10/11, PowerShell 5.1, .NET ≥ 4.7.2, VBScript enabled |

---

## Appendix A — `drive.py` (pty driver)

`encrypt.sh` reads passwords from `/dev/tty`, so it cannot be tested with plain pipes. This driver runs it inside a pseudo-terminal and types the answers. (Linux and macOS, Python ≥ 3.9.)

```python
#!/usr/bin/env python3
"""pty driver: runs a command inside a pseudo-terminal and types answers at its prompts.
encrypt.sh reads passwords from /dev/tty, so it cannot be tested with plain pipes.

  DRIVE_ANSWERS='["ENCRYPT","pw","pw"]' python3 drive.py ./encrypt.sh /some/folder
Prints the (ANSI-stripped) output, then a last line:  [driver] exit=<code> unanswered=[...]
Library use:  code, output, unanswered = run(argv, answers, kill_after=None, kill_sig=signal.SIGINT)
Needs Python 3.9+.
"""
import os, pty, sys, json, select, time, signal, re

PROMPT = re.compile(r'(Type ENCRYPT to continue: |Enter password: |Re-enter password: )$')
ANSI = re.compile(r'\x1b\[[0-9;]*m')

def run(argv, answers, timeout=900, kill_after=None, kill_sig=signal.SIGINT):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm'
        os.execvp(argv[0], argv)
    buf, ans, start, killed = b'', list(answers), time.time(), False
    while True:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:          # child closed the pty
                break
            if not data:
                break
            buf += data
            if ans and PROMPT.search(buf[-200:].decode('utf8', 'replace')):
                os.write(fd, (ans.pop(0) + '\n').encode())
        if kill_after is not None and not killed and time.time() - start > kill_after:
            os.kill(pid, kill_sig); killed = True
        if time.time() - start > timeout:
            os.kill(pid, signal.SIGKILL); break
    try:
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status)
    except ChildProcessError:
        code = None
    text = ANSI.sub('', buf.decode('utf8', 'replace')).replace('\r\n', '\n')
    return code, text, ans

if __name__ == '__main__':
    code, out, left = run(sys.argv[1:], json.loads(os.environ.get('DRIVE_ANSWERS', '[]')))
    print(out)
    print(f'[driver] exit={code} unanswered={left}')
```

## Appendix B — `mktree.sh` (nasty test tree, portable GNU/BSD)

```bash
#!/usr/bin/env bash
# mktree.sh DIR  - build a nasty test tree (odd names, nesting, big files, links). Portable GNU/BSD.
set -e
R=$1; [ -n "$R" ] || { echo "usage: mktree.sh DIR" >&2; exit 1; }
rm -rf "$R"; mkdir -p "$R"; cd "$R"
echo "hello" > small.txt;  : > empty.bin;  printf 'x' > one_byte.bin
head -c 4194304 /dev/urandom > exact_4MiB.bin
head -c 4194305 /dev/urandom > plus1.bin
head -c 1000003 /dev/urandom > random1M.bin
echo "spaces"  > "file with spaces.txt"
echo "unicode" > "unicode-é-日本語-🔒.txt"
echo "dash"    > -dashfile.txt
echo "hidden"  > .hidden
printf 'nl' > $'name\nwith newline.txt'
echo "quote" > "it's \"quoted\" \$HOME \`x\`.txt"
mkdir -p "folder with space" a/b/c/d/e/f empty_dir
echo deep > a/b/c/d/e/f/deep.txt; echo mid > a/b/mid.txt; echo top > a/top.txt
echo "in spaced folder" > "folder with space/x.txt"
echo ro > readonly.txt;  chmod 444 readonly.txt
printf '#!/bin/sh\necho hi\n' > prog.sh;  chmod 755 prog.sh
echo "private" > private.txt;  chmod 600 private.txt
echo target > link_target.txt; ln -s link_target.txt symlink_to_file; ln -s a symlink_to_dir
echo hard > hard1.txt; ln hard1.txt hard2.txt
touch -t 202001020304.05 small.txt prog.sh readonly.txt
touch -t 201905060708.09 a/b/mid.txt
```

## Appendix C — `snap.sh` (tree fingerprint: sha256 + mode + mtime + path, portable)

```bash
#!/usr/bin/env bash
# snap.sh DIR - sorted fingerprint of a tree: sha256 + mode + mtime + path for files, links, dirs. Portable GNU/BSD.
cd "$1" || exit 1
if stat -c %a / >/dev/null 2>&1; then meta() { stat -c '%a %Y' "$1"; }; else meta() { stat -f '%Lp %m' "$1"; }; fi
if command -v sha256sum >/dev/null 2>&1; then h() { sha256sum < "$1" | cut -d' ' -f1; }; else h() { shasum -a 256 < "$1" | cut -d' ' -f1; }; fi
{
  find . -type f -print0 | while IFS= read -r -d '' f; do printf 'F %s %s %s\n' "$(h "$f")" "$(meta "$f")" "$(printf '%s' "$f" | tr '\n' '?')"; done
  find . -type l -print0 | while IFS= read -r -d '' f; do printf 'L %s -> %s\n' "$(printf '%s' "$f" | tr '\n' '?')" "$(readlink "$f")"; done
  find . -type d -print0 | while IFS= read -r -d '' f; do printf 'D %s\n' "$(printf '%s' "$f" | tr '\n' '?')"; done
} | sort
```

## Appendix D — `core_test.sh` (end-to-end check, 21 assertions, portable)

```bash
#!/usr/bin/env bash
# core_test.sh - end-to-end check of encrypt.sh through a pty. Portable macOS/Linux. Run from this folder:
#   ENC=/path/to/encrypt.sh ./core_test.sh        (needs python3 >= 3.9; touches only $TREE)
ENC=${ENC:-./encrypt.sh}; DRV=${DRV:-./drive.py}; MK=${MK:-./mktree.sh}; SNAP=${SNAP:-./snap.sh}
TREE=${TREE:-${TMPDIR:-/tmp}/shenc_core_tree}; PW='correct horse battery staple'
case $ENC in /*) ;; *) ENC=$PWD/$ENC ;; esac
PASS=0; FAIL=0
chk()  { if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  PASS  $1"; else FAIL=$((FAIL+1)); echo "  FAIL  $1"; if [ -n "$SHENC_DEBUG" ]; then echo "  ---- last driver output:"; tail -n 14 /tmp/shenc_last.txt | sed 's/^/  | /'; fi; fi; }
run()  { local a=$1; shift; DRIVE_ANSWERS="$a" python3 "$DRV" "$ENC" "$@" 2>&1 | tee /tmp/shenc_last.txt; }
code() { grep -o 'driver\] exit=[0-9]*' | grep -o '[0-9]*$'; }
has()  { printf '%s' "$1" | grep -q -- "$2" && echo 1; }
eq()   { [ "$1" = "$2" ] && echo 1; }

echo "== toolchain =="
"$ENC" --self-test >/tmp/shenc_st.txt 2>&1; chk "--self-test passes ($(grep -m1 openssl /tmp/shenc_st.txt | cut -c1-60))" $([ $? = 0 ] && echo 1)

"$MK" "$TREE" >/dev/null; "$SNAP" "$TREE" > /tmp/shenc_before.txt
echo "== cancel / validation (must change nothing) =="
o=$(run '["encrypt"]' "$TREE");                          chk "lowercase 'encrypt' cancels, exit 1" "$(eq "$(echo "$o"|code)" 1)"
o=$(run "[\"ENCRYPT\",\"$PW\",\"nope nope nope\"]" "$TREE"); chk "password mismatch refused, exit 1"   "$(eq "$(echo "$o"|code)" 1)"
o=$(run '["ENCRYPT","short","short"]' "$TREE");          chk "password < 8 refused, exit 1"           "$(eq "$(echo "$o"|code)" 1)"
chk "tree unchanged after cancelled runs" "$("$SNAP" "$TREE" | diff -q - /tmp/shenc_before.txt >/dev/null && echo 1)"
chk "typed password is not echoed"        "$(printf '%s' "$(run "[\"ENCRYPT\",\"$PW\",\"x\"]" "$TREE")" | grep -q 'correct horse' || echo 1)"

echo "== encrypt =="
o=$(run "[\"ENCRYPT\",\"$PW\",\"$PW\"]" "$TREE")
chk "exit 0; 20 OK, 2 hard links skipped, 0 failed" "$([ "$(echo "$o"|code)" = 0 ] && has "$o" 'OK: 20   skipped: 2   failed: 0')"
n=0; while IFS= read -r -d '' f; do [ "$(head -c 8 "$f")" = SHENC001 ] && n=$((n+1)); done < <(find "$TREE" -type f -print0)
chk "20 of 22 files carry the SHENC001 magic (got $n)" "$(eq $n 20)"
chk "no leftover .shenc-tmp.* files"                  "$(eq "$(find "$TREE" -name '.shenc-tmp.*' | wc -l | tr -d ' ')" 0)"
chk "no plaintext left in encrypted files"            "$(grep -rl -a -e hello -e deep -e private "$TREE" 2>/dev/null | grep -q . || echo 1)"
sz=$(wc -c < "$TREE/exact_4MiB.bin" | tr -d ' ')
chk "encrypted size == 65+16+4194304+16+64 (got $sz)" "$(eq "$sz" $((65+16+4194304+16+64)))"
"$SNAP" "$TREE" > /tmp/shenc_enc.txt
chk "symlinks untouched"                              "$(grep -q 'L ./symlink_to_file -> link_target.txt' /tmp/shenc_enc.txt && has "$(cat /tmp/shenc_enc.txt)" 'L ./symlink_to_dir -> a')"
nosha() { awk '{if($1=="F"){$2=""}; print}' "$1" | sort; }   # drop the hash column, re-sort (order depends on the hash)
chk "mode+mtime of every path unchanged (sha ignored)" "$(diff -q <(nosha /tmp/shenc_before.txt) <(nosha /tmp/shenc_enc.txt) >/dev/null && echo 1)"
o=$(run '["ENCRYPT","another long password","another long password"]' "$TREE")
chk "second encrypt skips everything, files identical" "$("$SNAP" "$TREE" | diff -q - /tmp/shenc_enc.txt >/dev/null && has "$o" 'OK: 0 ')"

echo "== decrypt =="
o=$(run '["definitely the wrong one"]' --decrypt "$TREE")
chk "wrong password: exit 5, nothing changed"         "$([ "$(echo "$o"|code)" = 5 ] && "$SNAP" "$TREE" | diff -q - /tmp/shenc_enc.txt >/dev/null && echo 1)"
o=$(run "[\"$PW\"]" --decrypt "$TREE")
chk "correct password: exit 0, 20 OK"                 "$([ "$(echo "$o"|code)" = 0 ] && has "$o" 'OK: 20   skipped: 2   failed: 0')"
chk "EVERY file sha256+mode+mtime == original"        "$("$SNAP" "$TREE" | diff -q - /tmp/shenc_before.txt >/dev/null && echo 1)"

echo "== integrity =="
rm -f "$TREE/hard2.txt"; run "[\"ENCRYPT\",\"$PW\",\"$PW\"]" "$TREE" >/dev/null
printf '\377\377' | dd of="$TREE/a/b/mid.txt" bs=1 seek=100 conv=notrunc 2>/dev/null; cp "$TREE/a/b/mid.txt" /tmp/shenc_mid.bin
o=$(run "[\"$PW\"]" --decrypt "$TREE")
chk "tampered file FAILED (exit 4), the other 20 decrypt" "$([ "$(echo "$o"|code)" = 4 ] && has "$o" 'OK: 20   skipped: 0   failed: 1')"
chk "tampered file left byte-identical"                "$(cmp -s "$TREE/a/b/mid.txt" /tmp/shenc_mid.bin && echo 1)"

echo "== targets =="
for p in / /etc /usr/bin /tmp "$HOME"; do o=$(run '[]' "$p"); [ -n "$(has "$o" Refusing)" ] || { echo "  (not refused: $p)"; bad=1; }; done
chk "protected locations refused" "$([ -z "$bad" ] && echo 1)"
o=$(run '[]' /nonexistent/x); chk "missing path -> exit 2" "$(eq "$(echo "$o"|code)" 2)"

rm -rf "$TREE"
echo; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
```
