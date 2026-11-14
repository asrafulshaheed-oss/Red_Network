# encrypt.vbs — in-place file/folder encryption for Windows

> **Hand-off document for an AI coding agent.** Read this whole file, then follow **[START HERE](#start-here)**.

---

## 1. The job in one paragraph

Build and finish a **Windows command-line tool, delivered as a single `encrypt.vbs` file**, that a person runs from `cmd` or PowerShell to **encrypt (and later decrypt) a file or an entire folder tree in place**, protected by a password the person chooses. Encryption must be strong, work for any file size (KB to petabytes — streaming only, no loading files into memory), recurse through any number of nested folders, **not leave a backup copy**, and **not be decryptable without the correct password**.

The tool is for the user's **own personal data security**. It is an interactive, consent-based utility (like 7-Zip / gpg / AxCrypt), not a background process.

---

## 2. Original requirements (the user's exact intent)

These come directly from the user and are the acceptance criteria. Do not drop any.

| # | Requirement |
|---|-------------|
| R1 | Single VBS script for the **latest Windows** (Windows 11). |
| R2 | Encrypt command: `encrypt.vbs [file/folder name]` run from cmd or PowerShell. |
| R3 | After the command it must **ask the user to type `ENCRYPT`** to confirm. |
| R4 | Then it asks for a **password** (used later for decryption), then asks to **re-enter it for confirmation**. |
| R5 | Only if both passwords match does it encrypt. |
| R6 | Folders may contain many files and **folders inside folders** (any depth). |
| R7 | **Size does not matter**: smaller than 1 MB up to larger than 1 PB. |
| R8 | Encryption must be **very strong**; impossible to decrypt without the correct password. |
| R9 | Decrypt command: `encrypt.vbs --decrypt [file/folder name]` then it asks for the password; if correct, it decrypts. |
| R10 | It **must not delete** the user's files/folders — it encrypts the ones it is told to. (Interpretation: data is transformed in place; nothing is lost, nothing is removed from the folder tree.) |
| R11 | It **must not copy/back up** the files or folders. |

---

## 3. Current status

**v2 - first real Windows run found one bug; fixed; the fix is NOT yet confirmed on Windows.**

- Run 1 (user, Windows PowerShell): launcher, window, `ENCRYPT` prompt, masked password x2 all worked. The built-in self-test then failed with
  `Exception calling "Replace" with "3" argument(s): "The path is not of a legal form."` and the tool stopped with **"Nothing was changed"** (safety design worked; the user's file was untouched).
- Cause: PowerShell converts `$null` to an **empty string** when it is passed to a .NET method parameter of type `string`, so `File.Replace(tmp, path, $null)` received `""` as the backup path. Fix: pass a real null with `[NullString]::Value` (both in `Protect-File` and `Unprotect-File`).
- Everything after that line in the engine (the actual swap, restoring attributes, the full round trip, decrypt) has therefore **still never been executed**. Expect that further first-run problems are possible; the self-test + untouched-original design means they should fail safe.
- Static checks done on the delivered file: ASCII-only, CRLF, longest line 180 (limit 1023), launcher extraction == engine source byte-for-byte, PowerShell bracket/quote balance, VBS block balance.

### v2 changes (all small, none touch the crypto or file format)
| Change | Why |
|---|---|
| `[NullString]::Value` in both `File.Replace` calls | THE BUG above |
| Leftover `*.<32 hex>.tmp` files from an interrupted run are skipped and reported | otherwise a re-run would encrypt a partial temp file as if it were user data |
| `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%\AppData` added to the protected locations | apps keep live databases there; encrypting them breaks the apps |
| `ENCRYPT` confirmation tolerates leading/trailing spaces (still case-sensitive) | typing slip should not abort |
| Hint when the password is shorter than 12 chars (minimum still 8) | encourage a passphrase |
| Decrypt rejects header iteration counts above 10,000,000 (was 50,000,000) | an unverified header must not be able to stall PBKDF2 for minutes |
| Engine window title shows the mode | clarity |
| Launcher: `--help`/`-h`/`/?`, unknown `--options` are rejected | a typo such as `--decrpyt` no longer becomes a "path" |
| Launcher: correct quoting of a path ending in `\` (e.g. `C:\`) | previously the closing quote was escaped and arguments were mangled |
| Launcher: clear errors if the temp file cannot be written or PowerShell cannot be started; temp file always deleted | no silent failures |

The on-disk format (`VBSENC01`) is unchanged, so files from v1 and v2 are interchangeable.

---

## 4. Files

| File | Purpose |
|------|---------|
| `encrypt.vbs` | The deliverable. VBScript launcher + the PowerShell engine embedded at the bottom. |
| `README.md` | This document. |

There is deliberately **no second file** in the deliverable: the user wanted one VBS script.

---

## 5. Architecture and why it looks the way it does

### Why VBS is only a launcher
VBScript has **no cryptography**, **no masked password input**, and no streaming binary I/O worth using. Strong crypto is available for free through .NET, reachable from **Windows PowerShell 5.1** (ships in every Windows 10/11). So:

```
user:  encrypt.vbs "C:\Data\Secret"
         │
         ▼
  VBScript launcher (encrypt.vbs, top part)
    1. parse args (--decrypt / -d, one target path), strip stray trailing \ or "
    2. resolve to absolute path, check it exists
    3. read ITS OWN file, collect every line starting with  '|  → that is the PowerShell engine
    4. write engine to %TEMP%\vbsenc_<random>.ps1
    5. powershell.exe -NoProfile -ExecutionPolicy Bypass -File <tmp.ps1> -Mode Encrypt|Decrypt -Target "<abs path>" -Skip "<path of encrypt.vbs>"
       (WshShell.Run, window style 1, wait = True)  → a NEW console window opens
    6. delete the temp .ps1, exit with PowerShell's exit code
         │
         ▼
  PowerShell engine (all interaction happens in its window)
    path guard → scan tree → [type ENCRYPT] → password (masked) ×2 → self-test
    → per-file encrypt/decrypt → summary → "Press Enter to close"
```

### The `'|` embedding trick
Every PowerShell line is stored in the VBS prefixed with `'|`. In VBScript `'` starts a comment, so the lines are inert; the launcher reads its own file and strips the 2-char prefix. Benefits: no VBS string-escaping of PowerShell quotes, engine stays readable.
Rules when editing: keep every engine line prefixed; keep the file **ASCII-only**; keep **CRLF**; engine must be > 1000 chars (launcher sanity check).

### Known, deliberate deviation from the user's described UX
The user pictured the whole dialogue inside the same cmd window. `WshShell.Run` opens **a new console window** for the PowerShell part, because:
- `wscript.exe` (default host for `.vbs`) has no console at all;
- `WshShell.Exec` pipes stdin/stdout, which breaks masked `Read-Host -AsSecureString`;
- VBScript cannot read a password without echoing it.

If the user objects, see improvement **I1** below.

---

## 6. Cryptographic design

| Item | Choice |
|------|--------|
| Cipher | AES-256-CBC, PKCS7 padding (`System.Security.Cryptography.Aes`) |
| Integrity | HMAC-SHA256, **encrypt-then-MAC**, over header + ciphertext. Verified **before** any decrypted byte is written. |
| KDF | PBKDF2-HMAC-SHA256, **600,000 iterations**, 16-byte random salt, 32-byte master key |
| Salt scope | One salt **per run**; the master key is cached so a folder of 100k files costs **one** PBKDF2, not 100k |
| Per-file keys | `encKey = HMAC(master, "enc" ‖ fileNonce)`, `macKey = HMAC(master, "mac" ‖ fileNonce)`, with a fresh random 16-byte `fileNonce` and random 16-byte IV per file → every file has unique keys |
| Password check | 16 bytes = `HMAC(master,"pwcheck")[0..15]` in each header → wrong password is detected from the header alone, without reading the file body |
| Password handling | `Read-Host -AsSecureString`, NFKC-normalised, UTF-8 bytes; minimum length 8 on encrypt |
| RNG | `RandomNumberGenerator` |
| Why not AES-GCM | `AesGcm` does not exist in .NET Framework (Windows PowerShell 5.1). CBC + HMAC (encrypt-then-MAC) is the standard safe alternative there. |

### On-disk file format (file keeps its original name; no extension added)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | magic `VBSENC01` (ASCII) |
| 8 | 4 | PBKDF2 iterations, int32 little-endian |
| 12 | 16 | PBKDF2 salt |
| 28 | 16 | password check value |
| 44 | 16 | per-file nonce |
| 60 | 16 | AES IV |
| 76 | N | ciphertext (multiple of 16, ≥ 16) |
| 76+N | 32 | HMAC-SHA256 of bytes `[0 .. 76+N)` |

Minimum encrypted file = 76 + 16 + 32 = **124 bytes** (an empty plaintext file still encrypts to 124 bytes).

### Streaming (the "any size" requirement)
Buffer = 4 MiB (multiple of 16). Encrypt: full chunks go through `TransformBlock`, the final (possibly empty) chunk through `TransformFinalBlock`. Memory use is constant regardless of file size. Decrypt is **two passes** (pass 1 verify HMAC, pass 2 decrypt) so a wrong/tampered file never produces output.

---

## 7. How "in place, no backup, no data loss" is achieved

For each file:
1. Write the result to a **temp file in the same directory** (`<name>.<guid>.tmp`, opened `CreateNew`, share `None`).
2. Flush to disk, copy the original `LastWriteTime` onto the temp file.
3. `[System.IO.File]::Replace(temp, original, [NullString]::Value)` — atomic swap, **no backup file**. (Must be `[NullString]::Value`, not `$null`: PowerShell turns `$null` into `""` for `string` parameters and Replace then throws "The path is not of a legal form".)
4. On any failure: temp file is deleted, **original is untouched**, file is listed as FAILED in the summary.

So a crash/power-cut/wrong-password leaves every file either fully original or fully converted, never half-written. Cost: free disk space ≥ size of the **largest single file** is needed temporarily (not the size of the whole folder).
Read-only attribute is cleared for the swap and restored afterwards.

### Safety rails (keep these — they are a deliberate part of the design)
- **Typed confirmation `ENCRYPT`** (case-sensitive) before anything happens; password entered twice; min length 8.
- **Protected-location guard** (`Test-Protected`): refuses drive roots, `%windir%`, `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%`, `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%\AppData` (and anything inside them), plus the exact folders `%USERPROFILE%` and `C:\Users`. Subfolders such as `Documents` are allowed.
- **Self-test before touching user data** (`Test-Engine`): encrypts/decrypts throw-away files in `%TEMP%` with a 64-byte buffer for sizes 0,1,15,16,17,63,64,65,128,129,1000 — exercising chunk boundaries — and also checks "already encrypted" detection and wrong-password rejection. Aborts with "Nothing was changed" if anything fails. This exists because there is **no backup**, so an engine bug would mean permanent data loss.
- **Skips reparse points** (symlinks, junctions, OneDrive/cloud placeholders) so it never follows a link out of the tree. Each is printed as `[SKIP]`.
- **Skips itself** (`encrypt.vbs`, passed as `-Skip`) and the temp `.ps1`, so a folder containing the tool does not lock the tool.
- **Leftover temp files** (`<name>.<32 hex>.tmp`) from an interrupted run are skipped, never encrypted/decrypted.
- **Idempotent encrypt**: files already starting with the magic are skipped. Decrypt skips files that are not encrypted.
- **Wrong password on a folder**: files are skipped quickly (header check); after 5 consecutive rejections with zero successes the run stops.
- **Honest summary**: counts OK / skipped / failed, lists every failed file in red, non-zero exit code if any failed.

---

## 8. Usage (for the end user)

```
cscript //nologo encrypt.vbs "C:\Users\me\Documents\Secret"
   → new window:  Type ENCRYPT to continue:  ENCRYPT
                  Enter password:       ********
                  Re-enter password:    ********

cscript //nologo encrypt.vbs --decrypt "C:\Users\me\Documents\Secret"
   → new window:  Enter password:       ********
```

`encrypt.vbs "<path>"` works too (default host `wscript`); `cscript //nologo` just keeps messages in the console. Names with spaces **must** be quoted. Exactly one target per run.

---

## 9. Known limitations (be honest about these in any user-facing text)

1. **Lost password = lost data.** No recovery, no backup, by the user's own requirement.
2. **File and folder names, sizes, timestamps and tree structure stay visible.** Only file *contents* are encrypted.
3. **Plaintext remnants on disk.** After the swap, the old clusters are freed, not wiped; forensic tools may recover old plaintext, especially on SSDs. Mitigation: `cipher /w:<folder>` (Windows built-in free-space wipe) and/or BitLocker.
4. **Needs temporary free space** equal to the largest single file.
5. **Paths > 260 characters** are not handled (no `\\?\` prefix) → such files fail and are listed as FAILED, unchanged.
6. **OneDrive / cloud placeholder files and symlinks are skipped** (reparse points) — and listed as `[SKIP]`, so they remain plaintext.
7. **Requires .NET Framework ≥ 4.7.2** (for `Rfc2898DeriveBytes` with `HashAlgorithmName`) — true on current Windows 10/11.
8. **Antivirus/SmartScreen may flag it.** A `.vbs` that drops a `.ps1` and runs `powershell -ExecutionPolicy Bypass` matches classic malware heuristics. The code is fully transparent and does nothing network-related, but expect possible false positives; the user may need an exclusion.
9. **VBScript is being phased out.** Verified Nov 2026: VBScript is a Feature-on-Demand, still **enabled by default** on Windows 11 24H2/25H2; Microsoft plans to make it **disabled by default around 2027** (users can re-enable it under *Settings → System → Optional features → VBSCRIPT*), and full removal later with no date set. See improvement **I5**.
10. **Do not test inside `%TEMP%` or `AppData`** - those are protected locations and will be refused. Use a folder such as `C:\vbstest` or one under Downloads/Documents.
11. **Hidden/locked files** that another process has open will fail with a sharing violation and are reported FAILED.

---

## START HERE

Do these in order. Do **not** skip step 1 — nothing has ever been run.

### Step 0 — Orient (5 min)
- Read this file.
- Open `encrypt.vbs`. Top ≈ 100 lines = VBS launcher. Everything after the line `' EMBEDDED POWERSHELL ENGINE` is PowerShell, each line prefixed `'|`.
- To work on the engine as a normal script, extract it (PowerShell):
  ```powershell
  Get-Content .\encrypt.vbs | Where-Object { $_.StartsWith("'|") } |
      ForEach-Object { $_.Substring(2) } | Set-Content .\engine.ps1 -Encoding ASCII
  ```
- To rebuild after editing `engine.ps1`: keep the part of `encrypt.vbs` **above** the `'|` block, then append `engine.ps1` with `'|` prefixed to each line, CRLF endings, ASCII only. (Bash equivalent: `{ cat head.vbs; sed "s/^/'|/" engine.ps1; } | sed 's/\r$//' | sed 's/$/\r/' > encrypt.vbs`.)

### Step 1 — Get a safe Windows test environment
Use a **Windows 11 VM or a disposable machine**. Never test on real data first. Create a throw-away test tree (see Step 2).

### Step 2 — Run the test plan below and record pass/fail

Create `C:\vbstest` with: a few small text files; an empty file; a file of exactly 4 MiB; a file of 4 MiB + 1 byte; a ~1 GB file (`fsutil file createnew big.bin 1073741824`); nested folders 5+ levels deep with files at each level; a read-only file; a file with spaces and unicode in its name; a folder with a name containing spaces.
Record SHA-256 of everything first: `Get-ChildItem C:\vbstest -Recurse -File | Get-FileHash > before.txt`

| # | Test | Expected |
|---|------|----------|
| T1 | `cscript //nologo encrypt.vbs C:\vbstest` | New PowerShell window opens; scan count shown; prompts `Type ENCRYPT` |
| T2 | Type `encrypt` (lowercase) | "Cancelled. Nothing was changed." |
| T3 | Passwords differ on re-entry | "Passwords do not match", nothing changed |
| T4 | Password shorter than 8 | Refused, nothing changed |
| T5 | Correct flow | Self-test passes; every file `OK`; summary failed = 0; password input is masked |
| T6 | Open an encrypted file in Notepad | Binary garbage, begins with `VBSENC01`; names/tree unchanged; no extra backup files; no leftover `*.tmp` |
| T7 | Run encrypt again on same folder | All files `skipped (already encrypted)` |
| T8 | `--decrypt` with a **wrong** password | Files skipped as wrong password; run stops after 5; **nothing changed** (hashes still equal encrypted state) |
| T9 | `--decrypt` with correct password | All `OK`; **SHA-256 of every file equals `before.txt`**; last-write times preserved; read-only attribute preserved |
| T10 | Flip one byte in the middle of an encrypted file, then decrypt | That file `FAILED (integrity check failed)`, left unchanged; others fine; exit code 4 |
| T11 | Single-file target (not a folder) | Works |
| T12 | Target `C:\`, `C:\Windows`, `C:\Users`, your profile root | Refused with "protected system location" |
| T13 | Put `encrypt.vbs` inside the target folder | Tool is skipped, not encrypted |
| T14 | Large file (1 GB+) | Completes; memory of the PowerShell process stays small (check Task Manager); hash matches after round trip |
| T15 | Path > 260 chars | FAILED, file unchanged, other files still processed |
| T16 | Run via `wscript` (double-click style) and via `cscript` | Both open the engine window and work |
| T17 | Kill the PowerShell window mid-run | No half-written files; at most stray `*.tmp` next to the file being processed; originals intact |
| T19 | A leftover `file.txt.<32 hex>.tmp` in the target | `skipped (leftover temp file ...)`, file untouched |
| T20 | Target inside `%LOCALAPPDATA%` / `AppData` | Refused as protected location |
| T21 | `encrypt.vbs --help`, `encrypt.vbs --decrpyt x` | Usage shown / `Unknown option` |
| T22 | `encrypt.vbs "C:\"` | Refused cleanly (protected), no argument mangling |
| T18 | Mixed folder (some encrypted with password A, some with B) then decrypt with A | A-files decrypt; B-files skipped as wrong password |

### Step 3 — Fix what fails, in this priority order
1. **Self-test failures / PowerShell syntax errors** (engine does not start). Extract `engine.ps1`, run `powershell -File engine.ps1 -Mode Encrypt -Target C:\vbstest` directly to see parser errors.
2. Any case where **data could be lost or a file left half-converted** (T9, T10, T17 are the critical ones).
3. UX problems with the new-window prompt flow (T1–T5, T16).
4. Everything else.

**Specific things most likely to break — check these first:**
- `[System.Security.Cryptography.Rfc2898DeriveBytes]::new($pw,$salt,$iter,[HashAlgorithmName]::SHA256)` overload resolution (byte[] password).
- `Aes` CBC `TransformBlock` / `TransformFinalBlock` behaviour for the decryptor holding back the last block (output buffer is `BufSize + 32`).
- `HMACSHA256.TransformBlock(...,$null,0)` / `.Hash` after `TransformFinalBlock`.
- ~~`[System.IO.File]::Replace($tmp,$path,$null)`~~ **was the bug found in run 1; now `[NullString]::Value` - confirm it on Windows.** Same pitfall elsewhere: never pass `$null` to a `string` parameter of a .NET method.
- Read-only handling: `[FileAttributes]([int]$attr -band (-bnot 1))`.
- `return ,$array` patterns so byte arrays are not unrolled; `@(Func)[-1]` result-capture pattern (protects against accidental pipeline output).
- `Read-Host -AsSecureString` inside the window opened by `WshShell.Run`.
- `${env:ProgramFiles(x86)}` expansion in `Test-Protected`.
- `WshShell.Run` and `%` characters in paths (it may expand environment variables).
- Windows Defender reaction to the VBS → PS pattern.

### Step 4 — Only after all tests pass: improvements (ask the user first)
- **I1** Keep the entire dialogue in the **same console** the user typed the command in (user's original mental model). Options: a pure PowerShell version (best), or investigate `Exec` + console-sharing tricks. If kept as VBS, document the new-window behaviour clearly.
- **I2** Optional **filename encryption** (rename to random names + encrypted name table). Changes the "tree stays visible" limitation but adds complexity; ask the user.
- **I3** Optional secure wipe of plaintext remnants (or auto-call `cipher /w`).
- **I4** `\\?\` long-path support; a `--dry-run` flag; progress percentage for huge files; resume after interruption; optional parallelism across files (keep unique temp names).
- **I5** Provide a **PowerShell (`encrypt.ps1`) port** of the same engine and file format, because VBScript is being disabled by default around 2027. The format in §6 is the contract — both versions must stay mutually compatible.

---

## 10. Guardrails for the agent (important)

This is a legitimate personal-security tool. Keep it that way:

- **Never** make it run silently/automatically, accept the password from the command line or environment, hide its window, persist across reboots, spread, contact the network, or target files the user did not explicitly name. Interactive consent (`ENCRYPT` + password twice) is a core feature, not an obstacle.
- **Never** weaken the crypto (no fixed IVs/salts, no password-derived-without-KDF, no home-made ciphers, no dropping the HMAC, no lowering PBKDF2 iterations below 600,000, no leaving a key/backdoor/recovery copy) unless the user explicitly asks for a *recovery* feature, and then discuss the trade-off first.
- **Never** test on real user data. Never claim something "works" without having run it on Windows.
- Keep the **self-test**, the **protected-location guard**, the **atomic temp-file-then-Replace** pattern and the **HMAC-before-decrypt** order — they exist specifically because there is no backup.
- Keep `encrypt.vbs` **ASCII-only with CRLF** line endings; keep the `'|` convention.
- Report limitations honestly (§9) in any user-facing text.

---

## 11. Quick reference

| Thing | Value |
|-------|-------|
| Magic | `VBSENC01` |
| Header length | 76 bytes (+32 byte HMAC trailer) |
| PBKDF2 | SHA-256, 600,000 iterations (decrypt accepts 100,000 .. 10,000,000 from the header), 16-byte salt, 32-byte output |
| Buffer | 4 MiB |
| Min password | 8 chars |
| Confirmation phrase | `ENCRYPT` (case-sensitive) |
| Exit codes (engine) | 0 ok · 1 cancelled/bad input · 2 not found/protected path · 3 self-test failed · 4 some files failed · 5 aborted (wrong password) |
| Launcher temp file | `%TEMP%\vbsenc_<random>.ps1` (deleted after run) |
| Engine args | `-Mode Encrypt|Decrypt  -Target <abs path>  -Skip <path of encrypt.vbs>` |
| Runtime | Windows 10/11, Windows PowerShell 5.1, .NET Framework ≥ 4.7.2, VBScript FoD enabled |
