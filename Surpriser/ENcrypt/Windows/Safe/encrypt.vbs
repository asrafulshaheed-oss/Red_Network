Option Explicit
'======================================================================
' encrypt.vbs - in-place file / folder encryption for Windows
'
'   Encrypt :  encrypt.vbs "<file or folder>"
'   Decrypt :  encrypt.vbs --decrypt "<file or folder>"
'
' HOW IT WORKS
'   VBScript has no cryptography and no hidden password input, so this
'   file is a launcher. The real engine (AES-256-CBC + HMAC-SHA256,
'   PBKDF2-SHA256 key derivation, built-in .NET crypto) is PowerShell
'   code stored at the bottom of THIS file in lines that start with
'   the two characters  '|   (VBScript treats them as comments).
'   At run time the launcher:
'     1. checks the arguments and that the target exists
'     2. copies those '| lines into a temporary .ps1 in %TEMP%
'     3. runs it in its own PowerShell window (all prompts happen there)
'     4. deletes the temporary .ps1
'   No network access, no persistence, nothing is installed.
'
' EDITING THE ENGINE
'   Keep every engine line prefixed with '| and keep the whole file
'   ASCII-only (no accented letters, no curly quotes).
'======================================================================

Dim fso, sh, i, a, mode, target, ts, line, code, tmpPs, o, cmd, rc, runErr, runMsg

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

mode = "Encrypt"
target = ""

For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If LCase(a) = "--decrypt" Or LCase(a) = "-d" Then
        mode = "Decrypt"
    ElseIf LCase(a) = "--help" Or LCase(a) = "-h" Or a = "/?" Then
        WScript.Echo Usage()
        WScript.Quit 0
    ElseIf Left(a, 2) = "--" Then
        Die "Unknown option: " & a & vbCrLf & vbCrLf & Usage()
    ElseIf target = "" Then
        target = a
    Else
        Die "Too many arguments." & vbCrLf & "Put names that contain spaces in double quotes." & vbCrLf & vbCrLf & Usage()
    End If
Next

If target = "" Then Die Usage()

' clean the path (a quoted path ending in a backslash can arrive with a stray quote)
target = Trim(target)
Do While Len(target) > 3 And (Right(target, 1) = "\" Or Right(target, 1) = """")
    target = Left(target, Len(target) - 1)
Loop
target = fso.GetAbsolutePathName(target)

If Not (fso.FileExists(target) Or fso.FolderExists(target)) Then
    Die "Not found: " & target
End If

' pull the PowerShell engine out of this very file
code = ""
Set ts = fso.OpenTextFile(WScript.ScriptFullName, 1, False)
Do While Not ts.AtEndOfStream
    line = ts.ReadLine
    If Left(line, 2) = "'|" Then code = code & Mid(line, 3) & vbCrLf
Loop
ts.Close
If Len(code) < 1000 Then Die "Engine code not found inside " & WScript.ScriptFullName & vbCrLf & "The file was probably edited or saved incorrectly."

tmpPs = fso.BuildPath(sh.ExpandEnvironmentStrings("%TEMP%"), "vbsenc_" & fso.GetTempName() & ".ps1")
On Error Resume Next
Set o = fso.CreateTextFile(tmpPs, True, False)
If Err.Number = 0 Then
    o.Write code
    o.Close
End If
runErr = Err.Number
runMsg = Err.Description
On Error GoTo 0
If runErr <> 0 Then Die "Cannot write the temporary engine file:" & vbCrLf & tmpPs & vbCrLf & runMsg

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Q(tmpPs) & " -Mode " & mode & " -Target " & Q(target) & " -Skip " & Q(WScript.ScriptFullName)

If InStr(LCase(WScript.FullName), "cscript") > 0 Then
    WScript.Echo "Opening the " & LCase(mode) & " window. Continue there..."
End If

On Error Resume Next
rc = sh.Run(cmd, 1, True)
runErr = Err.Number
runMsg = Err.Description
Err.Clear
fso.DeleteFile tmpPs, True
On Error GoTo 0
If runErr <> 0 Then Die "Could not start PowerShell:" & vbCrLf & runMsg

WScript.Quit rc

Function Q(s)
    Dim n
    n = 0
    Do While n < Len(s)
        If Mid(s, Len(s) - n, 1) <> "\" Then Exit Do
        n = n + 1
    Loop
    Q = """" & s & String(n, "\") & """"
End Function

Function Usage()
    Usage = "Usage:" & vbCrLf & _
            "  encrypt.vbs ""<file or folder>""              encrypt" & vbCrLf & _
            "  encrypt.vbs --decrypt ""<file or folder>""    decrypt"
End Function

Sub Die(msg)
    WScript.Echo msg
    WScript.Quit 1
End Sub

'----------------------------------------------------------------------
' EMBEDDED POWERSHELL ENGINE - every line below starts with  '|
'----------------------------------------------------------------------
'|# ===================== embedded engine (Windows PowerShell 5.1) =====================
'|# This text lives inside encrypt.vbs (every line prefixed with  '|  ).
'|# encrypt.vbs extracts it to a temp .ps1, runs it in its own console window, deletes it.
'|# ASCII ONLY - do not put non-ASCII characters in this file.
'|param(
'|    [Parameter(Mandatory = $true)][ValidateSet('Encrypt', 'Decrypt')][string]$Mode,
'|    [Parameter(Mandatory = $true)][string]$Target,
'|    [string]$Skip = ''
'|)
'|$ErrorActionPreference = 'Stop'
'|try { $Host.UI.RawUI.WindowTitle = 'encrypt.vbs - ' + $Mode } catch { }
'|
'|# ---------------- constants ----------------
'|# File layout (in-place, same file name):
'|#   [0..7]   magic 'VBSENC01'
'|#   [8..11]  PBKDF2 iterations (int32 little endian)
'|#   [12..27] PBKDF2 salt (16 random bytes, one per run)
'|#   [28..43] password check value (first 16 bytes of HMAC-SHA256(master,'pwcheck'))
'|#   [44..59] per-file nonce (16 random bytes)
'|#   [60..75] AES-CBC IV (16 random bytes)
'|#   [76..N-33] AES-256-CBC ciphertext (PKCS7)
'|#   [N-32..N-1] HMAC-SHA256 over everything before it (encrypt-then-MAC)
'|$script:MagicText  = 'VBSENC01'
'|$script:Iterations = 600000
'|$script:HeaderLen  = 76
'|$script:BufSize    = 4194304        # 4 MiB, must be a multiple of 16
'|$script:Utf8       = New-Object System.Text.UTF8Encoding($false)
'|$script:Rng        = [System.Security.Cryptography.RandomNumberGenerator]::Create()
'|$script:Masters    = @{}
'|$script:Buf        = $null
'|$script:OBuf       = $null
'|
'|# ---------------- small helpers ----------------
'|function New-RandomBytes([int]$n) {
'|    $b = [byte[]]::new($n)
'|    if ($n -gt 0) { $script:Rng.GetBytes($b) }
'|    return ,$b
'|}
'|
'|function Slice([byte[]]$a, [int]$off, [int]$n) {
'|    $r = [byte[]]::new($n)
'|    [System.Array]::Copy($a, $off, $r, 0, $n)
'|    return ,$r
'|}
'|
'|function Test-Equal([byte[]]$a, [byte[]]$b) {
'|    if ($a.Length -ne $b.Length) { return $false }
'|    $d = 0
'|    for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ($a[$i] -bxor $b[$i]) }
'|    return ($d -eq 0)
'|}
'|
'|function Close-Obj($o) {
'|    if ($null -ne $o) { try { ([System.IDisposable]$o).Dispose() } catch { } }
'|}
'|
'|function Read-Full($s, [byte[]]$buf, [int]$count) {
'|    $total = 0
'|    while ($total -lt $count) {
'|        $n = $s.Read($buf, $total, $count - $total)
'|        if ($n -le 0) { break }
'|        $total += $n
'|    }
'|    return $total
'|}
'|
'|function Initialize-Buffers {
'|    if ($null -eq $script:Buf -or $script:Buf.Length -ne $script:BufSize) {
'|        $script:Buf  = [byte[]]::new($script:BufSize)
'|        $script:OBuf = [byte[]]::new($script:BufSize + 32)
'|    }
'|}
'|
'|# ---------------- key handling ----------------
'|function Get-MasterKey([byte[]]$pw, [byte[]]$salt, [int]$iter) {
'|    $id = [Convert]::ToBase64String($salt) + ':' + $iter + ':' + [Convert]::ToBase64String($pw)
'|    if (-not $script:Masters.ContainsKey($id)) {
'|        $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($pw, $salt, $iter, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
'|        try { $script:Masters[$id] = $kdf.GetBytes(32) } finally { $kdf.Dispose() }
'|    }
'|    return ,$script:Masters[$id]
'|}
'|
'|function Get-Check([byte[]]$master) {
'|    $h = [System.Security.Cryptography.HMACSHA256]::new($master)
'|    try { $full = $h.ComputeHash($script:Utf8.GetBytes('pwcheck')) } finally { $h.Dispose() }
'|    $r = Slice $full 0 16
'|    return ,$r
'|}
'|
'|function Get-FileKeys([byte[]]$master, [byte[]]$nonce) {
'|    $h = [System.Security.Cryptography.HMACSHA256]::new($master)
'|    try {
'|        $e = $h.ComputeHash([byte[]]($script:Utf8.GetBytes('enc') + $nonce))
'|        $m = $h.ComputeHash([byte[]]($script:Utf8.GetBytes('mac') + $nonce))
'|    } finally { $h.Dispose() }
'|    return @{ Enc = $e; Mac = $m }
'|}
'|
'|function New-AesObj([byte[]]$key, [byte[]]$iv) {
'|    $a = [System.Security.Cryptography.Aes]::Create()
'|    $a.Mode = [System.Security.Cryptography.CipherMode]::CBC
'|    $a.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
'|    $a.KeySize = 256
'|    $a.Key = $key
'|    $a.IV = $iv
'|    return $a
'|}
'|
'|# ---------------- encrypt one file (in place) ----------------
'|# returns: 'ok' | 'already'   (throws on I/O errors; original file is untouched on any failure)
'|function Protect-File([string]$path, [byte[]]$pw, [byte[]]$salt) {
'|    $in = $null; $out = $null; $aes = $null; $enc = $null; $hmac = $null
'|    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
'|    $done = $false
'|    Initialize-Buffers
'|    $buf = $script:Buf; $obuf = $script:OBuf; $bs = $script:BufSize
'|    try {
'|        $in = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
'|        $probe = [byte[]]::new(8)
'|        $got = Read-Full $in $probe 8
'|        if ($got -eq 8 -and [System.Text.Encoding]::ASCII.GetString($probe) -ceq $script:MagicText) { return 'already' }
'|        $in.Position = 0
'|
'|        $master = Get-MasterKey $pw $salt $script:Iterations
'|        $check  = Get-Check $master
'|        $nonce  = New-RandomBytes 16
'|        $iv     = New-RandomBytes 16
'|        $keys   = Get-FileKeys $master $nonce
'|        $stamp  = [System.IO.File]::GetLastWriteTimeUtc($path)
'|
'|        $out  = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
'|        $aes  = New-AesObj $keys.Enc $iv
'|        $enc  = $aes.CreateEncryptor()
'|        $hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys.Mac)
'|
'|        $header = [byte[]]($script:Utf8.GetBytes($script:MagicText) + [System.BitConverter]::GetBytes([int]$script:Iterations) + $salt + $check + $nonce + $iv)
'|        $out.Write($header, 0, $header.Length)
'|        [void]$hmac.TransformBlock($header, 0, $header.Length, $null, 0)
'|
'|        while ($true) {
'|            $n = Read-Full $in $buf $bs
'|            if ($n -eq $bs) {
'|                $w = $enc.TransformBlock($buf, 0, $n, $obuf, 0)
'|                $out.Write($obuf, 0, $w)
'|                [void]$hmac.TransformBlock($obuf, 0, $w, $null, 0)
'|            } else {
'|                $fin = $enc.TransformFinalBlock($buf, 0, $n)
'|                $out.Write($fin, 0, $fin.Length)
'|                [void]$hmac.TransformBlock($fin, 0, $fin.Length, $null, 0)
'|                break
'|            }
'|        }
'|        [void]$hmac.TransformFinalBlock([byte[]]::new(0), 0, 0)
'|        $tag = $hmac.Hash
'|        $out.Write($tag, 0, $tag.Length)
'|        $out.Flush($true)
'|        $out.Dispose(); $out = $null
'|        $in.Dispose();  $in  = $null
'|        [System.IO.File]::SetLastWriteTimeUtc($tmp, $stamp)
'|
'|        $attr = [System.IO.File]::GetAttributes($path)
'|        $ro = (([int]$attr -band 1) -ne 0)
'|        if ($ro) { [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]([int]$attr -band (-bnot 1))) }
'|        try { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
'|        catch { if ($ro) { [System.IO.File]::SetAttributes($path, $attr) }; throw }
'|        if ($ro) { [System.IO.File]::SetAttributes($path, $attr) }
'|        $done = $true
'|        return 'ok'
'|    } finally {
'|        Close-Obj $in; Close-Obj $out; Close-Obj $enc; Close-Obj $aes; Close-Obj $hmac
'|        if (-not $done -and [System.IO.File]::Exists($tmp)) { try { [System.IO.File]::Delete($tmp) } catch { } }
'|    }
'|}
'|
'|# ---------------- decrypt one file (in place) ----------------
'|# returns: 'ok' | 'notenc' | 'badpw' | 'corrupt'  (throws on I/O errors; file untouched on any failure)
'|function Unprotect-File([string]$path, [byte[]]$pw) {
'|    $in = $null; $out = $null; $aes = $null; $dec = $null; $hmac = $null
'|    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
'|    $done = $false
'|    Initialize-Buffers
'|    $buf = $script:Buf; $obuf = $script:OBuf; $bs = $script:BufSize
'|    try {
'|        $in  = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
'|        $len = $in.Length
'|        if ($len -lt ($script:HeaderLen + 16 + 32)) { return 'notenc' }
'|        $header = [byte[]]::new($script:HeaderLen)
'|        [void](Read-Full $in $header $script:HeaderLen)
'|        if ([System.Text.Encoding]::ASCII.GetString($header, 0, 8) -cne $script:MagicText) { return 'notenc' }
'|
'|        $iter = [System.BitConverter]::ToInt32($header, 8)
'|        if ($iter -lt 100000 -or $iter -gt 10000000) { return 'corrupt' }
'|        $salt   = Slice $header 12 16
'|        $master = Get-MasterKey $pw $salt $iter
'|        $check  = Get-Check $master
'|        $stored = Slice $header 28 16
'|        if (-not (Test-Equal $check $stored)) { return 'badpw' }
'|
'|        $nonce = Slice $header 44 16
'|        $iv    = Slice $header 60 16
'|        $keys  = Get-FileKeys $master $nonce
'|        $cipherLen = $len - $script:HeaderLen - 32
'|        if (($cipherLen % 16) -ne 0 -or $cipherLen -lt 16) { return 'corrupt' }
'|
'|        # ---- pass 1: verify HMAC over header + ciphertext BEFORE writing anything ----
'|        $hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]]$keys.Mac)
'|        $in.Position = 0
'|        $remaining = $len - 32
'|        while ($remaining -gt 0) {
'|            $want = [int][Math]::Min([long]$bs, $remaining)
'|            $n = Read-Full $in $buf $want
'|            if ($n -le 0) { return 'corrupt' }
'|            [void]$hmac.TransformBlock($buf, 0, $n, $null, 0)
'|            $remaining -= $n
'|        }
'|        [void]$hmac.TransformFinalBlock([byte[]]::new(0), 0, 0)
'|        $calc = $hmac.Hash
'|        $tag = [byte[]]::new(32)
'|        [void](Read-Full $in $tag 32)
'|        if (-not (Test-Equal $calc $tag)) { return 'corrupt' }
'|
'|        # ---- pass 2: decrypt to temp file ----
'|        $stamp = [System.IO.File]::GetLastWriteTimeUtc($path)
'|        $out = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
'|        $aes = New-AesObj $keys.Enc $iv
'|        $dec = $aes.CreateDecryptor()
'|        $in.Position = $script:HeaderLen
'|        $remaining = $cipherLen
'|        while ($remaining -gt $bs) {
'|            $n = Read-Full $in $buf $bs
'|            if ($n -ne $bs) { return 'corrupt' }
'|            $w = $dec.TransformBlock($buf, 0, $n, $obuf, 0)
'|            if ($w -gt 0) { $out.Write($obuf, 0, $w) }
'|            $remaining -= $n
'|        }
'|        $n = Read-Full $in $buf ([int]$remaining)
'|        if ($n -ne $remaining) { return 'corrupt' }
'|        $fin = $dec.TransformFinalBlock($buf, 0, $n)
'|        if ($fin.Length -gt 0) { $out.Write($fin, 0, $fin.Length) }
'|        $out.Flush($true)
'|        $out.Dispose(); $out = $null
'|        $in.Dispose();  $in  = $null
'|        [System.IO.File]::SetLastWriteTimeUtc($tmp, $stamp)
'|
'|        $attr = [System.IO.File]::GetAttributes($path)
'|        $ro = (([int]$attr -band 1) -ne 0)
'|        if ($ro) { [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]([int]$attr -band (-bnot 1))) }
'|        try { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
'|        catch { if ($ro) { [System.IO.File]::SetAttributes($path, $attr) }; throw }
'|        if ($ro) { [System.IO.File]::SetAttributes($path, $attr) }
'|        $done = $true
'|        return 'ok'
'|    } finally {
'|        Close-Obj $in; Close-Obj $out; Close-Obj $dec; Close-Obj $aes; Close-Obj $hmac
'|        if (-not $done -and [System.IO.File]::Exists($tmp)) { try { [System.IO.File]::Delete($tmp) } catch { } }
'|    }
'|}
'|
'|# ---------------- self-test (runs on throw-away files in %TEMP% before touching user data) ----------------
'|function Test-Engine {
'|    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('vbsenc_selftest_' + [guid]::NewGuid().ToString('N'))
'|    $saved = $script:BufSize
'|    $good = $true
'|    try {
'|        [void][System.IO.Directory]::CreateDirectory($dir)
'|        $script:BufSize = 64        # tiny buffer so chunk-boundary logic is exercised
'|        $pwA  = $script:Utf8.GetBytes('self-test password')
'|        $pwB  = $script:Utf8.GetBytes('another password')
'|        $salt = New-RandomBytes 16
'|        foreach ($size in 0, 1, 15, 16, 17, 63, 64, 65, 128, 129, 1000) {
'|            $f = Join-Path $dir ('t' + $size + '.bin')
'|            $data = New-RandomBytes $size
'|            [System.IO.File]::WriteAllBytes($f, $data)
'|            $r = @(Protect-File $f $pwA $salt)[-1]
'|            if ($r -ne 'ok') { $good = $false; break }
'|            $r = @(Protect-File $f $pwA $salt)[-1]
'|            if ($r -ne 'already') { $good = $false; break }
'|            $r = @(Unprotect-File $f $pwB)[-1]
'|            if ($r -ne 'badpw') { $good = $false; break }
'|            $r = @(Unprotect-File $f $pwA)[-1]
'|            if ($r -ne 'ok') { $good = $false; break }
'|            $back = [System.IO.File]::ReadAllBytes($f)
'|            if ([Convert]::ToBase64String($back) -cne [Convert]::ToBase64String($data)) { $good = $false; break }
'|        }
'|    } catch {
'|        Write-Host ('  self-test error: ' + $_.Exception.Message) -ForegroundColor Red
'|        $good = $false
'|    } finally {
'|        $script:BufSize = $saved
'|        $script:Masters.Clear()
'|        try { [System.IO.Directory]::Delete($dir, $true) } catch { }
'|    }
'|    return $good
'|}
'|
'|# ---------------- misc ----------------
'|function Read-Pw([string]$prompt) {
'|    $ss = Read-Host -Prompt $prompt -AsSecureString
'|    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
'|    try { $s = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
'|    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
'|    return $s.Normalize([System.Text.NormalizationForm]::FormKC)
'|}
'|
'|function Test-Protected([string]$p) {
'|    $p = $p.TrimEnd('\')
'|    $root = [System.IO.Path]::GetPathRoot($p)
'|    if ($null -ne $root -and $p -ieq $root.TrimEnd('\')) { return $true }
'|    $exact  = @($env:USERPROFILE, ($env:SystemDrive + '\Users'))
'|    $inside = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA)
'|    if ($env:USERPROFILE) { $inside += ($env:USERPROFILE.TrimEnd('\') + '\AppData') }
'|    foreach ($b in $exact) {
'|        if ($b -and $p -ieq $b.TrimEnd('\')) { return $true }
'|    }
'|    foreach ($b in $inside) {
'|        if ($b) {
'|            $b = $b.TrimEnd('\')
'|            if ($p -ieq $b -or $p.StartsWith($b + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
'|        }
'|    }
'|    return $false
'|}
'|
'|function Get-Files([string]$root, $list) {
'|    $stack = [System.Collections.Generic.Stack[string]]::new()
'|    $stack.Push($root)
'|    while ($stack.Count -gt 0) {
'|        $d = $stack.Pop()
'|        try {
'|            foreach ($f in [System.IO.Directory]::GetFiles($d)) {
'|                if (([int][System.IO.File]::GetAttributes($f) -band 1024) -ne 0) {
'|                    Write-Host ('  [SKIP] link or cloud placeholder: ' + $f) -ForegroundColor Yellow
'|                } else { $list.Add($f) }
'|            }
'|            foreach ($s in [System.IO.Directory]::GetDirectories($d)) {
'|                if (([int][System.IO.File]::GetAttributes($s) -band 1024) -ne 0) {
'|                    Write-Host ('  [SKIP] folder link or junction: ' + $s) -ForegroundColor Yellow
'|                } else { $stack.Push($s) }
'|            }
'|        } catch {
'|            Write-Host ('  [SKIP] cannot read folder: ' + $d + '  (' + $_.Exception.Message + ')') -ForegroundColor Yellow
'|        }
'|    }
'|}
'|
'|# ---------------- main flow ----------------
'|function Main {
'|    $full   = [System.IO.Path]::GetFullPath($Target)
'|    $isDir  = [System.IO.Directory]::Exists($full)
'|    $isFile = [System.IO.File]::Exists($full)
'|    if (-not ($isDir -or $isFile)) { Write-Host ('Not found: ' + $full) -ForegroundColor Red; return 2 }
'|    if (Test-Protected $full) { Write-Host ('Refusing: protected system location: ' + $full) -ForegroundColor Red; return 2 }
'|
'|    $files = [System.Collections.Generic.List[string]]::new()
'|    Write-Host 'Scanning...'
'|    if ($isFile) { $files.Add($full) } else { Get-Files $full $files }
'|
'|    Write-Host ''
'|    Write-Host ('Target : ' + $full)
'|    Write-Host ('Files  : ' + $files.Count)
'|    if ($files.Count -eq 0) { Write-Host 'Nothing to do.'; return 0 }
'|
'|    $salt = $null
'|    if ($Mode -eq 'Encrypt') {
'|        Write-Host 'Action : ENCRYPT in place (AES-256 + HMAC-SHA256). No backup copy is made.'
'|        Write-Host 'WARNING: if you lose the password, the data can NOT be recovered.' -ForegroundColor Yellow
'|        Write-Host ''
'|        $ans = Read-Host 'Type ENCRYPT to continue'
'|        if ($ans.Trim() -cne 'ENCRYPT') { Write-Host 'Cancelled. Nothing was changed.'; return 1 }
'|        $p1 = Read-Pw 'Enter password'
'|        if ($p1.Length -lt 8) { Write-Host 'Password must be at least 8 characters (a long passphrase is best). Nothing was changed.' -ForegroundColor Red; return 1 }
'|        if ($p1.Length -lt 12) { Write-Host 'Tip: a longer passphrase (12+ characters, e.g. several random words) is much safer.' -ForegroundColor Yellow }
'|        $p2 = Read-Pw 'Re-enter password'
'|        if (-not [string]::Equals($p1, $p2, [System.StringComparison]::Ordinal)) { Write-Host 'Passwords do not match. Nothing was changed.' -ForegroundColor Red; return 1 }
'|        $salt = New-RandomBytes 16
'|    } else {
'|        Write-Host 'Action : DECRYPT in place'
'|        Write-Host ''
'|        $p1 = Read-Pw 'Enter password'
'|    }
'|    $pw = $script:Utf8.GetBytes($p1)
'|
'|    Write-Host ''
'|    Write-Host 'Running self-test of the crypto engine on temporary data...'
'|    if (-not [bool](@(Test-Engine)[-1])) { Write-Host 'Self-test FAILED. Nothing was changed.' -ForegroundColor Red; return 3 }
'|    Write-Host 'Self-test passed. Starting.'
'|    Write-Host ''
'|
'|    $ok = 0; $skipped = 0; $badpw = 0; $stray = 0; $aborted = $false
'|    $failed = [System.Collections.Generic.List[string]]::new()
'|    $i = 0
'|    $total = $files.Count
'|    foreach ($f in $files) {
'|        $i++
'|        if ($f -ieq $Skip -or $f -ieq $PSCommandPath) { continue }
'|        if ($f -match '\.[0-9a-f]{32}\.tmp$') {
'|            $stray++
'|            Write-Host ('[' + $i + '/' + $total + '] skipped  (leftover temp file of an interrupted run) ' + $f) -ForegroundColor Yellow
'|            continue
'|        }
'|        $r = 'error'
'|        try {
'|            if ($Mode -eq 'Encrypt') { $r = @(Protect-File $f $pw $salt)[-1] }
'|            else { $r = @(Unprotect-File $f $pw)[-1] }
'|        } catch {
'|            $failed.Add($f + '   <-- ' + $_.Exception.Message)
'|            Write-Host ('[' + $i + '/' + $total + '] FAILED   ' + $f) -ForegroundColor Red
'|            continue
'|        }
'|        $pfx = '[' + $i + '/' + $total + '] '
'|        if ($r -eq 'ok') {
'|            $ok++
'|            Write-Host ($pfx + 'OK       ' + $f) -ForegroundColor Green
'|        } elseif ($r -eq 'already') {
'|            $skipped++
'|            Write-Host ($pfx + 'skipped  (already encrypted) ' + $f) -ForegroundColor Yellow
'|        } elseif ($r -eq 'notenc') {
'|            $skipped++
'|            Write-Host ($pfx + 'skipped  (not an encrypted file) ' + $f) -ForegroundColor Yellow
'|        } elseif ($r -eq 'badpw') {
'|            $skipped++; $badpw++
'|            Write-Host ($pfx + 'skipped  (wrong password for this file) ' + $f) -ForegroundColor Yellow
'|            if ($ok -eq 0 -and $badpw -ge 5) {
'|                Write-Host ''
'|                Write-Host 'Wrong password (5 files in a row rejected it). Stopping. Nothing was changed.' -ForegroundColor Red
'|                $aborted = $true
'|                break
'|            }
'|        } else {
'|            $failed.Add($f + '   <-- damaged or modified (integrity check failed)')
'|            Write-Host ($pfx + 'FAILED   (integrity check failed) ' + $f) -ForegroundColor Red
'|        }
'|    }
'|
'|    [System.Array]::Clear($pw, 0, $pw.Length)
'|    Write-Host ''
'|    Write-Host '------------------------------------------------------------'
'|    Write-Host ('Finished.  OK: ' + $ok + '   skipped: ' + $skipped + '   failed: ' + $failed.Count)
'|    if ($stray -gt 0) { Write-Host ('Note: ' + $stray + ' leftover *.tmp file(s) from an interrupted run were left alone; you can delete them by hand.') -ForegroundColor Yellow }
'|    if ($failed.Count -gt 0) {
'|        Write-Host 'These files were NOT processed and were left exactly as they were:' -ForegroundColor Red
'|        foreach ($x in $failed) { Write-Host ('  ' + $x) -ForegroundColor Red }
'|        return 4
'|    }
'|    if ($aborted) { return 5 }
'|    return 0
'|}
'|
'|$exitCode = 1
'|try { $exitCode = [int](@(Main)[-1]) }
'|catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red }
'|Write-Host ''
'|[void](Read-Host 'Press Enter to close this window')
'|exit $exitCode
