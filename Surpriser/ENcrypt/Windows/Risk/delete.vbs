Option Explicit

'==========================================================================
' delete.vbs - Secure permanent delete for Windows (hardened version)
'
' Usage:
'   cscript //nologo delete.vbs "C:\path\to\file_or_folder" ["another path" ...]
'
' Core wipe (always runs):
'   - Removes alternate data streams, then overwrites file contents 3x
'     (zero fill, 0xFF fill, cryptographically random fill) in small
'     chunks so file size never matters for memory use
'   - Truncates, renames to random names 3x, then deletes (not Recycle Bin)
'   - Recurses into folders of any depth; symlinks/junctions are unlinked
'     without touching whatever they point to
'   - Retries locked files briefly instead of failing immediately
'   - Verifies each target is actually gone afterward
'
' Optional drive-level hardening (only if run as Administrator):
'   - SSD TRIM re-issue on affected drives (automatic, non-destructive)
'   - Free-space wipe via "cipher /w" (asks first, can take a long time)
'   - Shadow copy + USN journal purge (asks first, requires typed YES -
'     this affects System Restore / Previous Versions for the WHOLE drive)
'==========================================================================

Dim objShell, objFSO
Dim argCount, i, p, normalized, winDir
Dim validList(), validCount, missingCount
Dim fSize, confirm1, confirm2
Dim psCode, tempFolder, tempScript, ts, cmdLine, objExec
Dim isAdmin, driveDict, driveKey, dk
Dim trimCmd, freeSpaceAns, shadowAns

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

EnsureCscriptHost

argCount = WScript.Arguments.Count
If argCount = 0 Then
    WScript.StdOut.WriteLine "Usage: cscript //nologo delete.vbs ""path1"" [""path2"" ...]"
    WScript.Quit 1
End If

ReDim validList(argCount - 1)
validCount = 0
missingCount = 0

For i = 0 To argCount - 1
    p = WScript.Arguments(i)
    If objFSO.FileExists(p) Or objFSO.FolderExists(p) Then
        validList(validCount) = objFSO.GetAbsolutePathName(p)
        validCount = validCount + 1
    Else
        WScript.StdOut.WriteLine "WARNING: not found, skipping -> " & p
        missingCount = missingCount + 1
    End If
Next

If validCount = 0 Then
    WScript.StdOut.WriteLine "Nothing valid to delete. Exiting."
    WScript.Quit 1
End If

' --- Safety guard: refuse whole-drive roots or the Windows directory ---
winDir = objShell.ExpandEnvironmentStrings("%WINDIR%")
For i = 0 To validCount - 1
    normalized = validList(i)
    If Right(normalized, 1) = "\" Then normalized = Left(normalized, Len(normalized) - 1)
    If Len(normalized) = 2 And Mid(normalized, 2, 1) = ":" Then
        WScript.StdOut.WriteLine "BLOCKED: refusing to target an entire drive root: " & validList(i)
        WScript.Quit 1
    End If
    If LCase(normalized) = LCase(winDir) Then
        WScript.StdOut.WriteLine "BLOCKED: refusing to target the Windows directory: " & validList(i)
        WScript.Quit 1
    End If
Next

' --- Check elevation (needed for the optional drive-level steps) ---
isAdmin = (objShell.Run("cmd /c net session >nul 2>&1", 0, True) = 0)

' --- Collect distinct drives involved, for the later hardening steps ---
Set driveDict = CreateObject("Scripting.Dictionary")
For i = 0 To validCount - 1
    driveKey = UCase(Left(validList(i), 2))
    If Len(driveKey) = 2 And Mid(driveKey, 2, 1) = ":" Then
        If Not driveDict.Exists(driveKey) Then driveDict.Add driveKey, True
    End If
Next

WScript.StdOut.WriteLine "=========================================================="
WScript.StdOut.WriteLine " SECURE PERMANENT DELETE"
WScript.StdOut.WriteLine " Files are overwritten multiple times, then deleted."
WScript.StdOut.WriteLine " This is NOT the Recycle Bin. No backup is kept."
If isAdmin Then
    WScript.StdOut.WriteLine " Running as Administrator: yes (drive-level hardening available)"
Else
    WScript.StdOut.WriteLine " Running as Administrator: no (some protected files / extra steps unavailable)"
End If
WScript.StdOut.WriteLine "=========================================================="
WScript.StdOut.WriteLine ""

For i = 0 To validCount - 1
    If objFSO.FolderExists(validList(i)) Then
        WScript.StdOut.WriteLine "  [FOLDER] " & validList(i) & "  (and everything inside it)"
    Else
        fSize = Empty
        On Error Resume Next
        fSize = objFSO.GetFile(validList(i)).Size
        On Error Goto 0
        WScript.StdOut.WriteLine "  [FILE]   " & validList(i) & "  (" & FormatSize(fSize) & ")"
    End If
Next

If missingCount > 0 Then
    WScript.StdOut.WriteLine ""
    WScript.StdOut.WriteLine (missingCount & " path(s) were not found and were skipped above.")
End If

WScript.StdOut.WriteLine ""
WScript.StdOut.Write "Type DELETE to confirm: "
confirm1 = WScript.StdIn.ReadLine()
If confirm1 <> "DELETE" Then
    WScript.StdOut.WriteLine "Confirmation text did not match. Aborted - nothing was touched."
    WScript.Quit 1
End If

WScript.StdOut.Write "Type DELETE again to confirm: "
confirm2 = WScript.StdIn.ReadLine()
If confirm2 <> "DELETE" Then
    WScript.StdOut.WriteLine "Confirmation text did not match. Aborted - nothing was touched."
    WScript.Quit 1
End If

WScript.StdOut.WriteLine ""
WScript.StdOut.WriteLine "Confirmed. Shredding... this can take a while for large files."
WScript.StdOut.WriteLine ""

psCode = BuildPowerShellEngine()

tempFolder = objFSO.GetSpecialFolder(2) ' Temp folder
Randomize
tempScript = tempFolder & "\__secwipe_" & Year(Now) & Month(Now) & Day(Now) & Hour(Now) & Minute(Now) & Second(Now) & Int(Rnd() * 100000) & ".ps1"

Set ts = objFSO.CreateTextFile(tempScript, True, False)
ts.Write psCode
ts.Close

cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & tempScript & Chr(34) & " -Targets"
For i = 0 To validCount - 1
    cmdLine = cmdLine & " " & Chr(34) & validList(i) & Chr(34)
Next

Set objExec = objShell.Exec(cmdLine)

Do While objExec.Status = 0
    Do While Not objExec.StdOut.AtEndOfStream
        WScript.StdOut.WriteLine objExec.StdOut.ReadLine()
    Loop
    WScript.Sleep 150
Loop

Do While Not objExec.StdOut.AtEndOfStream
    WScript.StdOut.WriteLine objExec.StdOut.ReadLine()
Loop

Do While Not objExec.StdErr.AtEndOfStream
    WScript.StdOut.WriteLine "[error] " & objExec.StdErr.ReadLine()
Loop

On Error Resume Next
objFSO.DeleteFile tempScript, True
On Error Goto 0

WScript.StdOut.WriteLine ""
WScript.StdOut.WriteLine "Core wipe finished. Exit code: " & objExec.ExitCode

' --- Optional drive-level hardening ---
WScript.StdOut.WriteLine ""
If driveDict.Count > 0 Then
    If isAdmin Then
        WScript.StdOut.WriteLine "Refreshing SSD TRIM on affected drive(s)..."
        For Each dk In driveDict.Keys
            trimCmd = "powershell -NoProfile -Command ""Optimize-Volume -DriveLetter " & Left(dk, 1) & " -ReTrim"""
            objShell.Run trimCmd, 0, True
        Next
        WScript.StdOut.WriteLine "  done (only has effect on SSD/NVMe; harmless no-op on a regular HDD)."

        WScript.StdOut.WriteLine ""
        WScript.StdOut.Write "Also wipe ALL free space on affected drive(s) now? Can take a long time on large drives. Type YES or press Enter to skip: "
        freeSpaceAns = WScript.StdIn.ReadLine()
        If UCase(freeSpaceAns) = "YES" Then
            For Each dk In driveDict.Keys
                WScript.StdOut.WriteLine "Wiping free space on " & dk & "\ (a window will show cipher's progress)..."
                objShell.Run "cipher /w:" & dk & "\", 1, True
            Next
            WScript.StdOut.WriteLine "Free space wipe complete."
        Else
            WScript.StdOut.WriteLine "Skipped free space wipe."
        End If

        WScript.StdOut.WriteLine ""
        WScript.StdOut.WriteLine "Advanced: purge Volume Shadow Copies and reset the change journal?"
        WScript.StdOut.WriteLine "WARNING: this deletes ALL System Restore points and ALL ""Previous"
        WScript.StdOut.WriteLine "Versions"" history for the ENTIRE drive, not just what you deleted."
        WScript.StdOut.Write "Type YES (exactly) to proceed, or press Enter to skip: "
        shadowAns = WScript.StdIn.ReadLine()
        If shadowAns = "YES" Then
            For Each dk In driveDict.Keys
                WScript.StdOut.WriteLine "Purging shadow copies and journal on " & dk & " ..."
                objShell.Run "cmd /c vssadmin delete shadows /for=" & dk & "\ /all /quiet", 1, True
                objShell.Run "cmd /c fsutil usn deletejournal /D " & dk, 1, True
            Next
            WScript.StdOut.WriteLine "Shadow copies and change journal purged on affected drive(s)."
        Else
            WScript.StdOut.WriteLine "Skipped shadow copy / journal purge."
        End If
    Else
        WScript.StdOut.WriteLine "Not running as Administrator, so these extra steps were skipped:"
        WScript.StdOut.WriteLine "  - SSD TRIM refresh, free-space wipe, shadow copy / journal purge."
        WScript.StdOut.WriteLine "Re-run from an elevated (Administrator) command prompt for those."
    End If
End If

WScript.StdOut.WriteLine ""
WScript.StdOut.WriteLine "All done."


'==========================================================================
' Functions
'==========================================================================

Sub EnsureCscriptHost()
    Dim hostName, argsStr, j
    hostName = LCase(WScript.FullName)
    If InStr(hostName, "wscript.exe") > 0 Then
        argsStr = ""
        For j = 0 To WScript.Arguments.Count - 1
            argsStr = argsStr & " " & Chr(34) & WScript.Arguments(j) & Chr(34)
        Next
        objShell.Run "cmd.exe /k cscript.exe //nologo " & Chr(34) & WScript.ScriptFullName & Chr(34) & argsStr, 1, False
        WScript.Quit
    End If
End Sub

Function FormatSize(ByVal nBytes)
    Dim units, u, sz
    units = Array("B", "KB", "MB", "GB", "TB", "PB")
    If IsEmpty(nBytes) Then
        FormatSize = "unknown size"
        Exit Function
    End If
    sz = CDbl(nBytes)
    u = 0
    Do While sz >= 1024 And u < UBound(units)
        sz = sz / 1024
        u = u + 1
    Loop
    FormatSize = FormatNumber(sz, 2) & " " & units(u)
End Function

Function BuildPowerShellEngine()
    Dim s
    s = ""
    s = s & "param([Parameter(Mandatory=$true)][string[]]$Targets)" & vbCrLf
    s = s & "function LP($p) {" & vbCrLf
    s = s & "    if ($p.Length -lt 248 -or $p.StartsWith('\\?\')) { return $p }" & vbCrLf
    s = s & "    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }" & vbCrLf
    s = s & "    return '\\?\' + $p" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "function Clear-Attrib($path) {" & vbCrLf
    s = s & "    try { $it = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; if ($it) { $it.Attributes = 'Normal' } } catch {}" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "function Open-Excl($path) {" & vbCrLf
    s = s & "    $tries = 0" & vbCrLf
    s = s & "    while ($true) {" & vbCrLf
    s = s & "        try { return [System.IO.File]::Open((LP $path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) }" & vbCrLf
    s = s & "        catch { $tries++; if ($tries -ge 5) { throw }; Start-Sleep -Milliseconds 500 }" & vbCrLf
    s = s & "    }" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "function Remove-AllStreams($path) {" & vbCrLf
    s = s & "    try {" & vbCrLf
    s = s & "        $streams = Get-Item -LiteralPath $path -Stream * -ErrorAction SilentlyContinue | Where-Object { $_.Stream -ne ':$DATA' }" & vbCrLf
    s = s & "        foreach ($st in $streams) { try { Remove-Item -LiteralPath $path -Stream $st.Stream -Force -ErrorAction SilentlyContinue } catch {} }" & vbCrLf
    s = s & "    } catch {}" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "function Wipe-File($path) {" & vbCrLf
    s = s & "    try {" & vbCrLf
    s = s & "        Clear-Attrib $path" & vbCrLf
    s = s & "        Remove-AllStreams $path" & vbCrLf
    s = s & "        $len = (New-Object System.IO.FileInfo((LP $path))).Length" & vbCrLf
    s = s & "        if ($len -gt 0) {" & vbCrLf
    s = s & "            $bufSize = [Math]::Min(1MB, $len)" & vbCrLf
    s = s & "            $buffer = New-Object byte[] $bufSize" & vbCrLf
    s = s & "            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()" & vbCrLf
    s = s & "            $passes = 0x00, 0xFF, -1" & vbCrLf
    s = s & "            foreach ($pass in $passes) {" & vbCrLf
    s = s & "                $fs = Open-Excl $path" & vbCrLf
    s = s & "                try {" & vbCrLf
    s = s & "                    $fs.Seek(0,[System.IO.SeekOrigin]::Begin) | Out-Null" & vbCrLf
    s = s & "                    $remaining = $len" & vbCrLf
    s = s & "                    while ($remaining -gt 0) {" & vbCrLf
    s = s & "                        $chunk = [Math]::Min($bufSize, $remaining)" & vbCrLf
    s = s & "                        if ($pass -eq -1) { $rng.GetBytes($buffer) } else { for ($k=0; $k -lt $buffer.Length; $k++) { $buffer[$k] = $pass } }" & vbCrLf
    s = s & "                        $fs.Write($buffer, 0, $chunk)" & vbCrLf
    s = s & "                        $remaining -= $chunk" & vbCrLf
    s = s & "                    }" & vbCrLf
    s = s & "                    $fs.Flush($true)" & vbCrLf
    s = s & "                } finally { $fs.Close() }" & vbCrLf
    s = s & "            }" & vbCrLf
    s = s & "            $rng.Dispose()" & vbCrLf
    s = s & "        }" & vbCrLf
    s = s & "        $fs2 = Open-Excl $path" & vbCrLf
    s = s & "        $fs2.SetLength(0)" & vbCrLf
    s = s & "        $fs2.Close()" & vbCrLf
    s = s & "        $dir = Split-Path -Parent $path" & vbCrLf
    s = s & "        $cur = $path" & vbCrLf
    s = s & "        for ($r=0; $r -lt 3; $r++) {" & vbCrLf
    s = s & "            $rn = [System.Guid]::NewGuid().ToString('N')" & vbCrLf
    s = s & "            try { Rename-Item -LiteralPath $cur -NewName $rn -Force -ErrorAction Stop; $cur = Join-Path $dir $rn } catch {}" & vbCrLf
    s = s & "        }" & vbCrLf
    s = s & "        Remove-Item -LiteralPath $cur -Force -ErrorAction Stop" & vbCrLf
    s = s & "        if (Test-Path -LiteralPath $cur) { Write-Output ('  WARNING: still present after delete attempt: ' + $path) } else { Write-Output ('  shredded: ' + $path) }" & vbCrLf
    s = s & "    } catch {" & vbCrLf
    s = s & "        Write-Output ('  ERROR on ' + $path + ' :: ' + $_.Exception.Message)" & vbCrLf
    s = s & "    }" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "function Wipe-Folder($folder) {" & vbCrLf
    s = s & "    $links = Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }" & vbCrLf
    s = s & "    foreach ($lnk in $links) { try { Clear-Attrib $lnk.FullName; Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction Stop; Write-Output ('  unlinked (symlink/junction, target untouched): ' + $lnk.FullName) } catch {} }" & vbCrLf
    s = s & "    $files = Get-ChildItem -LiteralPath $folder -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }" & vbCrLf
    s = s & "    foreach ($f in $files) { Wipe-File $f.FullName }" & vbCrLf
    s = s & "    $dirs = Get-ChildItem -LiteralPath $folder -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } | Sort-Object { $_.FullName.Length } -Descending" & vbCrLf
    s = s & "    foreach ($d in $dirs) { try { Clear-Attrib $d.FullName; Remove-Item -LiteralPath $d.FullName -Force -Recurse -ErrorAction SilentlyContinue } catch {} }" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "foreach ($t in $Targets) {" & vbCrLf
    s = s & "    if (Test-Path -LiteralPath $t -PathType Leaf) {" & vbCrLf
    s = s & "        Write-Output ('Wiping file: ' + $t)" & vbCrLf
    s = s & "        Wipe-File $t" & vbCrLf
    s = s & "    } elseif (Test-Path -LiteralPath $t -PathType Container) {" & vbCrLf
    s = s & "        Write-Output ('Wiping folder: ' + $t)" & vbCrLf
    s = s & "        Wipe-Folder $t" & vbCrLf
    s = s & "        try {" & vbCrLf
    s = s & "            Clear-Attrib $t" & vbCrLf
    s = s & "            Remove-Item -LiteralPath $t -Force -Recurse -ErrorAction Stop" & vbCrLf
    s = s & "            if (Test-Path -LiteralPath $t) { Write-Output ('  WARNING: folder still present: ' + $t) } else { Write-Output ('  folder removed: ' + $t) }" & vbCrLf
    s = s & "        } catch { Write-Output ('  ERROR removing folder: ' + $t + ' :: ' + $_.Exception.Message) }" & vbCrLf
    s = s & "    } else {" & vbCrLf
    s = s & "        Write-Output ('SKIP (not found): ' + $t)" & vbCrLf
    s = s & "    }" & vbCrLf
    s = s & "}" & vbCrLf
    s = s & "Write-Output 'DONE'" & vbCrLf
    BuildPowerShellEngine = s
End Function
