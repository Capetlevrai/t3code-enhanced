Option Explicit

Dim shell, fso, env, logFile, tStart
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set env = shell.Environment("Process")
tStart = Timer

' Optional pipe name injected by install.ps1 for 0 ms detection (e.g. \\.\pipe\t3code-app-<hash>)
Const T3_PIPE_PATH = "__T3_PIPE_PATH__"

Dim appDataDir, logPath
appDataDir = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\t3code-context-menu"
If Not fso.FolderExists(appDataDir) Then
    On Error Resume Next
    fso.CreateFolder appDataDir
    On Error GoTo 0
End If
logPath = appDataDir & "\last-run.log"

Sub WriteLog(msg)
    On Error Resume Next
    Dim ts, elapsedMs
    elapsedMs = CLng((Timer - tStart) * 1000)
    If elapsedMs < 0 Then elapsedMs = 0
    Set ts = fso.OpenTextFile(logPath, 8, True)
    ts.WriteLine Now & " (+" & elapsedMs & "ms) | " & msg
    ts.Close
    On Error GoTo 0
End Sub

Function IsT3AppReady()
    If Left(T3_PIPE_PATH, 9) = "\\.\pipe\" Then
        IsT3AppReady = fso.FileExists(T3_PIPE_PATH)
    Else
        On Error Resume Next
        Dim wmi, procs
        Set wmi = GetObject("winmgmts:\\.\root\cimv2")
        Set procs = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='T3 Code (Beta).exe' OR Name='T3 Code.exe'")
        IsT3AppReady = (Err.Number = 0 And procs.Count > 0)
        On Error GoTo 0
    End If
End Function

' Reset log for this run
On Error Resume Next
If fso.FileExists(logPath) Then fso.DeleteFile logPath, True
On Error GoTo 0

If WScript.Arguments.Count = 0 Then
    WriteLog "ERROR: No folder argument provided."
    WScript.Quit 1
End If

Dim targetPath
targetPath = Trim(WScript.Arguments(0))
If Left(targetPath, 1) = """" And Right(targetPath, 1) = """" Then
    targetPath = Mid(targetPath, 2, Len(targetPath) - 2)
End If

' install.ps1 passes "%1\." so drive roots never end in \" ; resolve the "\." (and any "..")
' so T3 Code receives C:\foo, not C:\foo\. (which would register a different project path).
On Error Resume Next
targetPath = fso.GetAbsolutePathName(targetPath)
On Error GoTo 0

' Normalize trailing backslash (keep drive roots like C:\ intact)
Do While Len(targetPath) > 3 And Right(targetPath, 1) = "\"
    targetPath = Left(targetPath, Len(targetPath) - 1)
Loop

WriteLog "Target folder: " & targetPath

If Not fso.FolderExists(targetPath) Then
    WriteLog "ERROR: Folder does not exist."
    MsgBox "Le dossier est introuvable : " & targetPath, vbExclamation, "T3 Code"
    WScript.Quit 1
End If

' Locate T3 Code executable (supports Beta and stable release names)
Dim installDir, exePath, binPath
installDir = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\t3code"
If fso.FileExists(installDir & "\T3 Code (Beta).exe") Then
    exePath = installDir & "\T3 Code (Beta).exe"
ElseIf fso.FileExists(installDir & "\T3 Code.exe") Then
    exePath = installDir & "\T3 Code.exe"
Else
    WriteLog "ERROR: T3 Code executable not found in " & installDir
    MsgBox "T3 Code est introuvable dans : " & installDir, vbCritical, "T3 Code"
    WScript.Quit 1
End If

binPath = installDir & "\resources\server.asar\apps\server\dist\bin.mjs"
If Not fso.FileExists(installDir & "\resources\server.asar") Then
    WriteLog "ERROR: server.asar not found."
    MsgBox "Ressources T3 Code introuvables (server.asar).", vbCritical, "T3 Code"
    WScript.Quit 1
End If

' Escape trailing backslash for Node/Electron argv parsing (e.g. C:\ -> C:\\)
Dim safeTarget
safeTarget = targetPath
If Right(safeTarget, 1) = "\" Then
    safeTarget = safeTarget & "\"
End If

Dim cmd, exitCode, i
cmd = """" & exePath & """ """ & binPath & """ app """ & safeTarget & """"

' Clear SSH vars just in case so `t3 app` never thinks it's over SSH
On Error Resume Next
env.Remove "SSH_CONNECTION"
env.Remove "SSH_TTY"
On Error GoTo 0

' Step 1: Fast path - check in < 1 ms if T3 Code control pipe exists before calling `t3 app`
If IsT3AppReady() Then
    env("ELECTRON_RUN_AS_NODE") = "1"
    WriteLog "Step 1: Pipe/process detected, running t3 app (fast path)"
    exitCode = shell.Run(cmd, 0, True)
    WriteLog "Step 1 exitCode=" & exitCode
    If exitCode = 0 Then
        WriteLog "SUCCESS (fast path)"
        WScript.Quit 0
    End If
Else
    WriteLog "Step 1: Skipped (T3 Code not running) -> immediate cold start"
End If

' Step 2: Cold start - launch T3 Code GUI cleanly without ELECTRON_RUN_AS_NODE
On Error Resume Next
env.Remove "ELECTRON_RUN_AS_NODE"
On Error GoTo 0

WriteLog "Step 2: Launching T3 Code GUI: " & exePath
shell.CurrentDirectory = installDir
shell.Run """" & exePath & """", 1, False

' Wait for control pipe to appear (0 ms per check, up to 20s) before calling `t3 app`
If Left(T3_PIPE_PATH, 9) = "\\.\pipe\" Then
    For i = 1 To 200
        If fso.FileExists(T3_PIPE_PATH) Then
            WriteLog "Step 2: Control pipe appeared after " & (i * 100) & "ms"
            Exit For
        End If
        WScript.Sleep 100
    Next
Else
    WScript.Sleep 1500
End If

' Step 3: Activate workspace via `t3 app` once pipe is up
env("ELECTRON_RUN_AS_NODE") = "1"
For i = 1 To 20
    exitCode = shell.Run(cmd, 0, True)
    WriteLog "Step 3 attempt " & i & " exitCode=" & exitCode
    If exitCode = 0 Then
        WriteLog "SUCCESS (cold start on attempt " & i & ")"
        WScript.Quit 0
    End If
    WScript.Sleep 500
Next

WriteLog "FAILED after 20 attempts. Last exitCode=" & exitCode
MsgBox "Impossible d'ouvrir le dossier dans T3 Code apres le demarrage." & vbCrLf & "Log : " & logPath, vbExclamation, "T3 Code"
WScript.Quit exitCode
