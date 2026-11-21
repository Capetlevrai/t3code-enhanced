using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

// Lightweight native launcher for "Ouvrir dans T3 Code" Windows Explorer context menu.
// Talks directly to T3 Code's desktop control named pipe (\\.\pipe\t3code-app-<sha256_24>)
// instead of spawning Electron with ELECTRON_RUN_AS_NODE=1 + server.asar (which takes 5-20s).
static class Program
{
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int dwProcessId);
    private const int ASFW_ANY = -1;

    private static readonly Stopwatch Sw = Stopwatch.StartNew();
    private static string _logPath;

    [STAThread]
    static int Main(string[] args)
    {
        string appDataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "t3code-context-menu");
        try { Directory.CreateDirectory(appDataDir); } catch { }
        _logPath = Path.Combine(appDataDir, "last-run.log");
        try { if (File.Exists(_logPath)) File.Delete(_logPath); } catch { }

        if (args.Length == 0 || string.IsNullOrWhiteSpace(args[0]))
        {
            Log("ERROR: No folder argument provided.");
            return 1;
        }

        string targetPath = NormalizeFolderArg(args[0]);
        Log("Target folder: " + targetPath);

        if (!Directory.Exists(targetPath))
        {
            Log("ERROR: Folder does not exist.");
            MessageBox.Show("Le dossier est introuvable : " + targetPath, "T3 Code", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }

        string installDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Programs\t3code");

        string exePath = Path.Combine(installDir, "T3 Code (Beta).exe");
        if (!File.Exists(exePath))
        {
            exePath = Path.Combine(installDir, "T3 Code.exe");
        }
        if (!File.Exists(exePath))
        {
            Log("ERROR: T3 Code executable not found in " + installDir);
            MessageBox.Show("T3 Code est introuvable dans : " + installDir, "T3 Code", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // Resolve T3 Code state directory & control named pipe (matches packages/shared/src/desktopAppControl.ts)
        string t3Home = Environment.GetEnvironmentVariable("T3CODE_HOME");
        if (string.IsNullOrWhiteSpace(t3Home))
        {
            t3Home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".t3");
        }
        else
        {
            try { t3Home = Path.GetFullPath(t3Home.Trim().Trim('"')); }
            catch { t3Home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".t3"); }
        }
        string stateDir = Path.GetFullPath(Path.Combine(t3Home, "userdata"));
        string devStateDir = Path.GetFullPath(Path.Combine(t3Home, "dev"));

        string primaryPipeHash = ShortSha256(stateDir);
        string primaryPipe = "t3code-app-" + primaryPipeHash;
        string devPipe = "t3code-app-" + ShortSha256(devStateDir);
        string primaryPipePath = @"\\.\pipe\" + primaryPipe;
        string devPipePath = @"\\.\pipe\" + devPipe;

        Log("Pipe: " + primaryPipePath);

        // Step 1: Fast path (< 5 ms check) — if pipe exists, send open-workspace directly
        string activePipe = File.Exists(primaryPipePath) ? primaryPipe : (File.Exists(devPipePath) ? devPipe : null);
        if (activePipe != null)
        {
            Log("Step 1: Pipe detected, sending open-workspace directly");
            string err;
            IpcResult warm = SendOpenWorkspace(activePipe, targetPath, out err);
            if (warm == IpcResult.Ok)
            {
                Log("SUCCESS (warm start)");
                return 0;
            }
            if (warm == IpcResult.Fatal) return FailWithT3Message(err);
            Log("Step 1 failed (" + err + "), falling back to cold start");
        }
        else
        {
            Log("Step 1: Pipe absent (app closed) -> immediate cold start");
        }

        // Step 2: Cold start coordinated via per-user/profile Mutex so concurrent Explorer clicks
        // or rapid close-and-relaunch never fight over Electron's SingleInstanceLock.
        string exeProcName = Path.GetFileNameWithoutExtension(exePath);
        string mutexName = @"Local\T3CodeLauncher_" + primaryPipeHash;
        Process launchedProc = null;
        int launchCount = 0;

        if (!EnsureT3CodeStarted(mutexName, exePath, installDir, exeProcName, primaryPipePath, devPipePath, ref launchedProc, ref launchCount))
        {
            return 1;
        }

        // Step 3: Poll for the named pipe every 100 ms, wait for local backend HTTP readiness
        // (reading dynamic port from server-runtime.json), then send IPC within overall deadline.
        const int maxWaitMs = 45000;
        int attempts = 0;
        bool waitedForBackend = false;
        string lastErr = "pipe never appeared";

        while (Sw.ElapsedMilliseconds < maxWaitMs)
        {
            string readyPipe = File.Exists(primaryPipePath) ? primaryPipe : (File.Exists(devPipePath) ? devPipe : null);
            if (readyPipe != null)
            {
                if (!waitedForBackend)
                {
                    int remainingForBackend = (int)Math.Max(0, Math.Min(12000, maxWaitMs - Sw.ElapsedMilliseconds - 5000));
                    if (remainingForBackend > 0)
                    {
                        string activeStateDir = (readyPipe == devPipe) ? devStateDir : stateDir;
                        Log("Step 3: Pipe appeared, waiting for local backend readiness");
                        WaitForLocalBackend(activeStateDir, remainingForBackend);
                    }
                    waitedForBackend = true;
                }

                int remainingMs = (int)(maxWaitMs - Sw.ElapsedMilliseconds);
                if (remainingMs <= 500) break;

                attempts++;
                Log("Step 3: Sending open-workspace (attempt " + attempts + ")");
                IpcResult cold = SendOpenWorkspace(readyPipe, targetPath, out lastErr);
                if (cold == IpcResult.Ok)
                {
                    Log("SUCCESS (cold start on IPC attempt " + attempts + ")");
                    return 0;
                }
                if (cold == IpcResult.Fatal) return FailWithT3Message(lastErr);
                Log("Step 3 IPC attempt " + attempts + " failed: " + lastErr);
                Thread.Sleep(250);
            }
            else
            {
                // Guard against both: (a) our launched process exiting on second-instance race,
                // and (b) a previously observed instance exiting after we skipped launching.
                bool noProcessesLeft = CountCurrentSessionProcesses(exeProcName) == 0;
                bool launchedExited = (launchedProc != null && launchedProc.HasExited);
                if ((noProcessesLeft || launchedExited) && launchCount < 3)
                {
                    Log("Step 3: No active pipe and instance absent/exited (noProcs=" + noProcessesLeft + ", launchedExited=" + launchedExited + "); ensuring launch");
                    if (!EnsureT3CodeStarted(mutexName, exePath, installDir, exeProcName, primaryPipePath, devPipePath, ref launchedProc, ref launchCount))
                    {
                        return 1;
                    }
                }
                Thread.Sleep(100);
            }
        }

        Log("FAILED after " + Sw.ElapsedMilliseconds + "ms. Last error: " + lastErr);
        MessageBox.Show(
            "Impossible d'ouvrir le dossier dans T3 Code apres le demarrage.\n" + lastErr + "\n\nLog : " + _logPath,
            "T3 Code",
            MessageBoxButtons.OK,
            MessageBoxIcon.Warning);
        return 1;
    }

    // T3 Code answered ok:false with a code that retrying cannot fix (platform-mismatch,
    // project-create-failed, thread-open-failed, invalid-request): show its own message.
    private static int FailWithT3Message(string error)
    {
        Log("FAILED (T3 Code refused the request) after " + Sw.ElapsedMilliseconds + "ms: " + error);
        MessageBox.Show(
            "T3 Code n'a pas pu ouvrir ce dossier :\n" + error + "\n\nLog : " + _logPath,
            "T3 Code",
            MessageBoxButtons.OK,
            MessageBoxIcon.Warning);
        return 1;
    }

    private static string NormalizeFolderArg(string raw)
    {
        string p = raw.Trim().Trim('"');
        // Defensive fix: Windows argv parsing turns `"C:\"` into `C:"` -> `C:` after Trim('"').
        // `C:` means current working directory of drive C, NOT `C:\`!
        if (p.Length == 2 && char.IsLetter(p[0]) && p[1] == ':')
        {
            p = p + "\\";
        }
        try
        {
            p = Path.GetFullPath(p);
        }
        catch { }
        // Trim trailing slash except for drive roots (C:\) and UNC roots
        while (p.Length > 3 && p.EndsWith("\\") && !p.StartsWith(@"\\"))
        {
            p = p.Substring(0, p.Length - 1);
        }
        return p;
    }

    private static int CountCurrentSessionProcesses(string procName)
    {
        int mySession = Process.GetCurrentProcess().SessionId;
        int count = 0;
        foreach (var p in Process.GetProcessesByName(procName))
        {
            try
            {
                if (p.SessionId == mySession) count++;
            }
            catch { }
            finally { p.Dispose(); }
        }
        return count;
    }

    private static bool EnsureT3CodeStarted(
        string mutexName,
        string exePath,
        string installDir,
        string exeProcName,
        string primaryPipePath,
        string devPipePath,
        ref Process launchedProc,
        ref int launchCount)
    {
        bool createdNew;
        using (var mutex = new Mutex(false, mutexName, out createdNew))
        {
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(12000); }
                catch (AbandonedMutexException) { acquired = true; }

                if (!acquired)
                {
                    Log("Step 2: Another launcher holds startup mutex; deferring to poll loop");
                    return true;
                }

                if (File.Exists(primaryPipePath) || File.Exists(devPipePath))
                {
                    return true;
                }

                // Wait for any shutting-down T3 Code processes (closeScope takes ~5s) to release SingleInstanceLock
                if (CountCurrentSessionProcesses(exeProcName) > 0)
                {
                    Log("Step 2: Pipe absent while " + exeProcName + " is running (shutting down or booting); waiting...");
                    var waitExitSw = Stopwatch.StartNew();
                    while (waitExitSw.ElapsedMilliseconds < 10000)
                    {
                        if (File.Exists(primaryPipePath) || File.Exists(devPipePath))
                        {
                            Log("Step 2: Pipe appeared after " + waitExitSw.ElapsedMilliseconds + "ms");
                            return true;
                        }
                        if (CountCurrentSessionProcesses(exeProcName) == 0)
                        {
                            Log("Step 2: Previous instance exited after " + waitExitSw.ElapsedMilliseconds + "ms");
                            break;
                        }
                        Thread.Sleep(150);
                    }
                }

                if (!File.Exists(primaryPipePath) && !File.Exists(devPipePath) && launchCount < 3)
                {
                    launchCount++;
                    launchedProc = LaunchT3Code(exePath, installDir);
                    if (launchedProc == null) return false;
                }
                return true;
            }
            finally
            {
                if (acquired)
                {
                    try { mutex.ReleaseMutex(); } catch { }
                }
            }
        }
    }

    private static Process LaunchT3Code(string exePath, string installDir)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                WorkingDirectory = installDir,
                UseShellExecute = false
            };
            psi.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
            psi.EnvironmentVariables.Remove("SSH_CONNECTION");
            psi.EnvironmentVariables.Remove("SSH_TTY");

            Log("Step 2: Launching T3 Code GUI: " + exePath);
            return Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log("ERROR launching T3 Code: " + ex.Message);
            MessageBox.Show("Impossible de lancer T3 Code : " + ex.Message, "T3 Code", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return null;
        }
    }

    private static int ResolveBackendPort(string stateDir)
    {
        try
        {
            string runtimeFile = Path.Combine(stateDir, "server-runtime.json");
            if (File.Exists(runtimeFile))
            {
                string content = File.ReadAllText(runtimeFile, Encoding.UTF8);
                Match m = Regex.Match(content, "\"port\"\\s*:\\s*(\\d+)");
                Match pidMatch = Regex.Match(content, "\"pid\"\\s*:\\s*(\\d+)");
                int port, pid;
                // Ignore a stale file left by a previous backend (its pid is gone): the new backend
                // rewrites it once it listens, and we re-read it on every poll.
                bool stale = pidMatch.Success && int.TryParse(pidMatch.Groups[1].Value, out pid) && !IsProcessAlive(pid);
                if (!stale && m.Success && int.TryParse(m.Groups[1].Value, out port) && port > 0 && port <= 65535)
                {
                    return port;
                }
            }
        }
        catch { }
        int envPort;
        if (int.TryParse(Environment.GetEnvironmentVariable("T3CODE_PORT"), out envPort) && envPort > 0 && envPort <= 65535)
        {
            return envPort;
        }
        return 3773;
    }

    private static bool IsProcessAlive(int pid)
    {
        try
        {
            using (var p = Process.GetProcessById(pid)) return !p.HasExited;
        }
        catch { return false; }
    }

    private static void WaitForLocalBackend(string stateDir, int maxWaitMs)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < maxWaitMs)
        {
            int port = ResolveBackendPort(stateDir);
            try
            {
                var req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/.well-known/t3/environment");
                req.Method = "GET";
                req.Timeout = 400;
                req.ReadWriteTimeout = 400;
                req.Proxy = null;
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    if ((int)resp.StatusCode == 200)
                    {
                        using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                        {
                            string body = sr.ReadToEnd();
                            if (body.Contains("environmentId") || body.Contains("t3"))
                            {
                                Log("Step 3: Local backend ready on port " + port + " after " + sw.ElapsedMilliseconds + "ms");
                                Thread.Sleep(350);
                                return;
                            }
                        }
                    }
                }
            }
            catch
            {
                // Backend still booting
            }
            Thread.Sleep(150);
        }
        Log("Step 3: Local backend wait timed out (" + maxWaitMs + "ms), proceeding to IPC");
    }

    private enum IpcResult { Ok, Retry, Fatal }

    // T3 Code queues the request until its window is ready and always answers within 15 s
    // (REQUEST_TIMEOUT_MS in DesktopAppActivation). Closing the pipe before that cancels the
    // request while the renderer may already be adding the project, and a retry could then add
    // it twice. So the read timeout is always longer than T3 Code's own deadline.
    private const int IpcReadTimeoutMs = 20000;

    private static IpcResult SendOpenWorkspace(string pipeName, string workspaceRoot, out string error)
    {
        error = null;
        const int timeoutMs = IpcReadTimeoutMs;
        try
        {
            try { AllowSetForegroundWindow(ASFW_ANY); } catch { }
            using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                client.Connect(2000);

                string requestId = Guid.NewGuid().ToString();
                string payload =
                    "{\"version\":1,\"requestId\":\"" + requestId +
                    "\",\"type\":\"open-workspace\",\"workspaceRoot\":\"" + EscapeJson(workspaceRoot) +
                    "\",\"platform\":\"win32\"}\n";

                byte[] reqBytes = Encoding.UTF8.GetBytes(payload);
                var writeTask = client.WriteAsync(reqBytes, 0, reqBytes.Length);
                if (!writeTask.Wait(2000))
                {
                    error = "write timeout";
                    return IpcResult.Retry;
                }
                client.Flush();

                using (var reader = new StreamReader(client, new UTF8Encoding(false), false, 4096, true))
                {
                    var readTask = reader.ReadLineAsync();
                    if (!readTask.Wait(timeoutMs))
                    {
                        error = "read timeout (" + timeoutMs + "ms)";
                        return IpcResult.Fatal;
                    }
                    string line = readTask.Result;
                    if (string.IsNullOrEmpty(line))
                    {
                        error = "empty response";
                        return IpcResult.Retry;
                    }
                    bool idMatch = line.Contains("\"" + requestId + "\"");
                    bool okTrue = Regex.IsMatch(line, "\"ok\"\\s*:\\s*true");
                    if (idMatch && okTrue)
                    {
                        return IpcResult.Ok;
                    }
                    return ClassifyFailure(line, out error);
                }
            }
        }
        catch (AggregateException aex)
        {
            var inner = aex.InnerException ?? aex;
            error = inner.GetType().Name + ": " + inner.Message;
            return IpcResult.Retry;
        }
        catch (Exception ex)
        {
            error = ex.GetType().Name + ": " + ex.Message;
            return IpcResult.Retry;
        }
    }

    // Response shape: {"version":1,"requestId":"...","ok":false,"code":"...","message":"..."}
    private static IpcResult ClassifyFailure(string line, out string error)
    {
        Match code = Regex.Match(line, "\"code\"\\s*:\\s*\"([a-z-]+)\"");
        Match msg = Regex.Match(line, "\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
        string message = line;
        if (msg.Success)
        {
            try { message = Regex.Unescape(msg.Groups[1].Value); } catch { message = msg.Groups[1].Value; }
        }
        string codeValue = code.Success ? code.Groups[1].Value : "";
        error = (codeValue.Length > 0 ? codeValue + ": " : "") + message;
        switch (codeValue)
        {
            // Window not ready yet, local environment still connecting, app restarting: retry.
            case "renderer-unavailable":
            case "environment-unavailable":
            case "internal-error":
            case "":
                return IpcResult.Retry;
            // request-timeout, invalid-request, platform-mismatch, project-create-failed, thread-open-failed:
            // retrying cannot help and could duplicate work if the renderer is still processing.
            default:
                return IpcResult.Fatal;
        }
    }

    private static string ShortSha256(string input)
    {
        using (var sha = SHA256.Create())
        {
            byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(input));
            var sb = new StringBuilder(24);
            for (int i = 0; i < 12; i++)
            {
                sb.Append(hash[i].ToString("x2"));
            }
            return sb.ToString();
        }
    }

    private static string EscapeJson(string s)
    {
        var sb = new StringBuilder(s.Length + 16);
        foreach (char c in s)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\b': sb.Append(@"\b"); break;
                case '\f': sb.Append(@"\f"); break;
                case '\n': sb.Append(@"\n"); break;
                case '\r': sb.Append(@"\r"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c);
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private static void Log(string msg)
    {
        try
        {
            File.AppendAllText(
                _logPath,
                DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss.fff") + " [pid " + Process.GetCurrentProcess().Id + "] (+" +
                Sw.ElapsedMilliseconds + "ms) | " + msg + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }
}
