using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

// Lightweight native launcher for "Ouvrir dans T3 Code" Windows Explorer context menu.
// Talks directly to T3 Code's desktop control named pipe (\\.\pipe\t3code-app-<sha256_24>)
// instead of spawning Electron with ELECTRON_RUN_AS_NODE=1 + server.asar (which takes 5-20s).
static class Program
{
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

        string targetPath = args[0].Trim().Trim('"');
        while (targetPath.Length > 3 && targetPath.EndsWith("\\"))
        {
            targetPath = targetPath.Substring(0, targetPath.Length - 1);
        }

        try
        {
            targetPath = Path.GetFullPath(targetPath);
        }
        catch { }

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
        string stateDir = Path.Combine(t3Home, "userdata");
        string devStateDir = Path.Combine(t3Home, "dev");

        string primaryPipe = "t3code-app-" + ShortSha256(stateDir);
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
            if (SendOpenWorkspace(activePipe, targetPath, 5000, out err))
            {
                Log("SUCCESS (warm start)");
                return 0;
            }
            Log("Step 1 failed (" + err + "), falling back to cold start");
        }
        else
        {
            Log("Step 1: Pipe absent (app closed) -> immediate cold start");
        }

        // Step 2: Cold start — if T3 Code processes are still shutting down (pipe gone but
        // SingleInstanceLock still held for ~5s during backend closeScope), wait for them to exit
        // before spawning a new instance so Electron doesn't exit immediately on second-instance.
        string exeProcName = Path.GetFileNameWithoutExtension(exePath);
        bool needLaunch = true;
        if (Process.GetProcessesByName(exeProcName).Length > 0)
        {
            Log("Step 2: Pipe absent but " + exeProcName + " is still running (shutting down or booting); waiting...");
            var waitExitSw = Stopwatch.StartNew();
            while (waitExitSw.ElapsedMilliseconds < 10000)
            {
                if (File.Exists(primaryPipePath) || File.Exists(devPipePath))
                {
                    Log("Step 2: Pipe appeared after " + waitExitSw.ElapsedMilliseconds + "ms (app was booting)");
                    needLaunch = false;
                    break;
                }
                if (Process.GetProcessesByName(exeProcName).Length == 0)
                {
                    Log("Step 2: Previous instance exited after " + waitExitSw.ElapsedMilliseconds + "ms");
                    break;
                }
                Thread.Sleep(150);
            }
        }

        Process launchedProc = null;
        int launchCount = 0;
        if (needLaunch)
        {
            launchedProc = LaunchT3Code(exePath, installDir);
            if (launchedProc == null) return 1;
            launchCount = 1;
        }

        // Step 3: Poll for the named pipe every 100 ms (0 ms per File.Exists check),
        // then wait for the local backend HTTP readiness (returns immediately on HTTP 200)
        // before sending IPC so T3 Code doesn't stall inside an early timeout.
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
                    Log("Step 3: Pipe appeared, waiting for local backend readiness");
                    WaitForLocalBackend(12000);
                    waitedForBackend = true;
                }

                attempts++;
                Log("Step 3: Sending open-workspace (attempt " + attempts + ")");
                int ipcTimeout = (attempts == 1) ? 8000 : 12000;
                if (SendOpenWorkspace(readyPipe, targetPath, ipcTimeout, out lastErr))
                {
                    Log("SUCCESS (cold start on IPC attempt " + attempts + ")");
                    return 0;
                }
                Log("Step 3 IPC attempt " + attempts + " failed: " + lastErr);
                Thread.Sleep(250);
            }
            else
            {
                // Guard against Electron single-instance race: if our launched process exited
                // immediately while a previous instance was dying, wait briefly and relaunch.
                if (launchedProc != null && launchedProc.HasExited && launchCount < 3)
                {
                    Log("Step 3: Launched process exited early (code=" + launchedProc.ExitCode + "); waiting for clean state and relaunching");
                    var raceSw = Stopwatch.StartNew();
                    while (raceSw.ElapsedMilliseconds < 6000 && Process.GetProcessesByName(exeProcName).Length > 0)
                    {
                        if (File.Exists(primaryPipePath) || File.Exists(devPipePath)) break;
                        Thread.Sleep(150);
                    }
                    if (!File.Exists(primaryPipePath) && !File.Exists(devPipePath))
                    {
                        launchedProc = LaunchT3Code(exePath, installDir);
                        if (launchedProc == null) return 1;
                        launchCount++;
                    }
                }
                Thread.Sleep(100);
            }
        }

        Log("FAILED after " + Sw.ElapsedMilliseconds + "ms. Last error: " + lastErr);
        MessageBox.Show(
            "Impossible d'ouvrir le dossier dans T3 Code apres le demarrage.\nLog : " + _logPath,
            "T3 Code",
            MessageBoxButtons.OK,
            MessageBoxIcon.Warning);
        return 1;
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

    private static void WaitForLocalBackend(int maxWaitMs)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < maxWaitMs)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:3773/.well-known/t3/environment");
                req.Method = "GET";
                req.Timeout = 400;
                req.ReadWriteTimeout = 400;
                req.Proxy = null;
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    if ((int)resp.StatusCode == 200)
                    {
                        Log("Step 3: Local backend ready after " + sw.ElapsedMilliseconds + "ms");
                        // Small settle delay for renderer WebSocket handshake
                        Thread.Sleep(350);
                        return;
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

    private static bool SendOpenWorkspace(string pipeName, string workspaceRoot, int timeoutMs, out string error)
    {
        error = null;
        try
        {
            using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                client.Connect(Math.Min(timeoutMs, 2000));

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
                    return false;
                }
                client.Flush();

                using (var reader = new StreamReader(client, new UTF8Encoding(false), false, 4096, true))
                {
                    var readTask = reader.ReadLineAsync();
                    if (!readTask.Wait(timeoutMs))
                    {
                        error = "read timeout (" + timeoutMs + "ms)";
                        return false;
                    }
                    string line = readTask.Result;
                    if (string.IsNullOrEmpty(line))
                    {
                        error = "empty response";
                        return false;
                    }
                    if (line.Contains("\"ok\":true"))
                    {
                        return true;
                    }
                    error = "response=" + line;
                    return false;
                }
            }
        }
        catch (AggregateException aex)
        {
            var inner = aex.InnerException ?? aex;
            error = inner.GetType().Name + ": " + inner.Message;
            return false;
        }
        catch (Exception ex)
        {
            error = ex.GetType().Name + ": " + ex.Message;
            return false;
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
                DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss.fff") + " (+" + Sw.ElapsedMilliseconds + "ms) | " + msg + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }
}
