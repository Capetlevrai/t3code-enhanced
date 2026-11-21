Option Explicit

Dim shell, fso, env, logFile
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set env = shell.Environment("Process")

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
    Dim ts
    Set ts = fso.OpenTextFile(logPath, 8, True)
    ts.WriteLine Now & " | " & msg
    ts.Close
    On Error GoTo 0
End Sub

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

' Step 1: Fast path — try activating an already-running T3 Code desktop app
env("ELECTRON_RUN_AS_NODE") = "1"
WriteLog "Step 1: Running t3 app (fast path)"
exitCode = shell.Run(cmd, 0, True)
WriteLog "Step 1 exitCode=" & exitCode

If exitCode = 0 Then
    WriteLog "SUCCESS (fast path)"
    WScript.Quit 0
End If

' Step 2: Cold start — launch T3 Code GUI cleanly without ELECTRON_RUN_AS_NODE
On Error Resume Next
env.Remove "ELECTRON_RUN_AS_NODE"
On Error GoTo 0

WriteLog "Step 2: Launching T3 Code GUI: " & exePath
shell.CurrentDirectory = installDir
shell.Run """" & exePath & """", 1, False

' Give Electron a moment to start booting
WScript.Sleep 2000

' Step 3: Poll `t3 app` until the desktop app + renderer are ready (up to ~35s)
env("ELECTRON_RUN_AS_NODE") = "1"
For i = 1 To 40
    exitCode = shell.Run(cmd, 0, True)
    WriteLog "Step 3 attempt " & i & " exitCode=" & exitCode
    If exitCode = 0 Then
        WriteLog "SUCCESS (cold start on attempt " & i & ")"
        WScript.Quit 0
    End If
    WScript.Sleep 750
Next

WriteLog "FAILED after 40 attempts. Last exitCode=" & exitCode
MsgBox "Impossible d'ouvrir le dossier dans T3 Code apres le demarrage." & vbCrLf & "Log : " & logPath, vbExclamation, "T3 Code"
WScript.Quit exitCode
