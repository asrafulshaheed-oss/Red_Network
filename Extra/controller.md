# CMON — fixed build (rechecked)

This zip contains the fixed, fully retested files:

| File            | What it is                                    |
|-----------------|-----------------------------------------------|
| `controller.py` | The controller with the web GUI (v20)         |
| `client.py`     | The Python client                             |
| `client.js`     | The Node.js client                            |
| `client.cs`     | The C# client                                 |
| `package.json`  | Node dependencies for client.js               |

Run them exactly like the originals (`python controller.py <port> --gui-port <guiport>`,
`python client.py host:port`, `node client.js host:port`, `dotnet run` / your
usual C# build for client.cs). No new dependencies.

## What is fixed

### Windows
- **Browser GUI shell was blank on Windows.** Two causes, both fixed:
  - client.js: the C# ConPTY launcher passed the pseudoconsole handle by
    value instead of by reference, so `UpdateProcThreadAttribute` failed
    (error 14) and every Windows shell silently fell back to a bare pipe.
  - controller.py: ConPTY output arrives as many tiny chunks that split ANSI
    escape sequences in the middle. The per-chunk stripper turned the
    fragments into visible garbage and an unterminated title sequence
    swallowed the rest of the line. The GUI terminal now reassembles
    sequences across chunk boundaries (`_gui_term_feed`), including OSC
    sequences, and a malformed sequence can no longer wedge the stream.
- Shell start failures (PowerShell/cmd missing, access denied) now report a
  clear `[client]` notice on the shell channel instead of sitting empty.
- The ConPTY bridge reports unexpected stops instead of dying silently.

### macOS / iOS
- **Shell showed nothing / "command not found: ^M" on macOS.** The pipe-fed
  shell now receives a bare `\n` (not `\r`); through `script(1)` the PTY gets
  exactly one `\r`. Ctrl+C now raises a real SIGINT to the shell's own
  process group, so the running command is interrupted but the shell and the
  client survive.
- `script(1)` is now probed with all three dialects (BSD no-command form
  first, then the two argument forms), so macOS uses a real PTY again.
- macOS without `$SHELL` (Finder / LaunchAgent start) and iOS get an ordered
  shell fallback chain (`zsh → bash → sh`).
- No usable PTY (stock iOS, hardened sandboxes): the shell degrades to a
  line-oriented bridge instead of dying — any PTY setup failure is caught.
- Screen share: a scan that stops early (damaged/truncated JPEG) degrades to
  neutral grey instead of a solid green frame, and restart markers inside a
  scan no longer truncate the picture.
- BI_BITFIELDS (mask) BMPs from the macOS/Windows screen stream decode
  correctly instead of failing with "compressed BMP is not supported".

### C# client (client.cs)
The C# client carried the same shell bugs that client.js/client.py had, now
fixed the same way:
- **Windows: the ConPTY launcher passed the pseudoconsole handle by value**
  to `UpdateProcThreadAttribute` (the P/Invoke now takes it `ref`), so the
  real pseudoconsole never attached and every Windows shell dropped to the
  bare pipe fallback. This is the same bug fixed inside client.js's embedded
  launcher, now fixed in the standalone C# client too.
- **macOS: no `script(1)` fallback.** One argument shape per platform was
  tried, and if that dialect refused the flags the shell channel just died.
  All three dialects are now tried in order (BSD no-command form first with
  the PTY sized by a fed `stty` line), and a dialect that dies within 250 ms
  falls through to the next one, then to the line-oriented shell.
- **macOS/iOS pipe shell: raw `\r` reached the shell** ("command not found:
  ^M") and Ctrl+C did nothing. The pipe bridge now assembles lines (local
  echo, backspace editing, CRLF = one Enter), submits every line with a bare
  `\n`, and raises a real SIGINT to the shell's own process group via
  `setpgid`/`kill` on first use.
- iOS/macOS get the ordered `ShellExecutable()` fallback chain (SHELL →
  zsh → bash → sh) instead of an empty value, and a shell that cannot start
  reports a clear `[client]` notice on the shell channel.
- Screen capture/streaming needed no changes: ImageSharp decodes and
  re-encodes internally and throws cleanly on damaged input, and the stream
  loop already contains per-frame failures (verified during this recheck).

### All platforms
- Screenshare with an `fps` argument no longer crashes with
  `UnboundLocalError`.
- GUI upex: the **hidden** checkbox is enabled only when an auto launcher
  exists, correctly unchecks otherwise, adds `-h`, and sends `hidden=1`.
- Ctrl+C in the Python fallback shell works the same way (own process group),
  and CRLF input counts as one Enter.
- Shell input pasting is protected against slow links (dropped-bytes notice).
- upex compile-attempt lists use consistent indentation (mixed tabs/spaces).

## Recheck performed

All three script clients re-verified end to end after the fixes: Python
compile + Node syntax checks, shell bridge unit tests (pipe + PTY), Ctrl+C
tests (Python and JS), GUI endpoint smoke tests, the GUI upex pipeline
tests, a Windows ConPTY wire-level simulation (the exact screen a browser
shows), and full controller+client end-to-end runs (files, console, GUI
shell round-trip, upex in all modes, screenshots, screen share, fps share).
Everything passes; one additional edge bug was found during the recheck and
fixed (PTY-fallback exception handling in client.py, listed above).

client.cs was audited area by area against the bug classes found in the
other clients (no C# toolchain exists in the build sandbox, so it was
verified by structural checks plus a line-exact behavioral test of the new
pipe-bridge state machine: echo, CR/CRLF submission, backspace editing,
Ctrl+C/Ctrl+D, control-byte filtering - all pass).
