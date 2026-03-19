// Claude Monitor v3 -- Windows System Tray App (compiled .NET)
// Strictly C# 5 / .NET 4.0 compatible (NO ?., NO =>, NO $"", NO nameof, NO ToUnixTimeSeconds)
// Compile: csc.exe /target:winexe /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll ClaudeMonitorTray.cs
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class ClaudeMonitor : ApplicationContext {
    NotifyIcon tray;
    System.Windows.Forms.Timer timer;
    System.Windows.Forms.Timer cleanupTimer;
    System.Windows.Forms.Timer smartCtxTimer;
    string claudeDir;
    JavaScriptSerializer json;
    Dictionary<string, string> prevStates;
    HashSet<string> ctxWarned;

    // Preferences (replaces loose booleans)
    MonitorPrefs prefs;
    string prefsPath;

    // Floating overlay
    OverlayForm overlay;

    // Haiku AI naming
    Dictionary<string, string> sessionNames;
    string sessionNamesPath;
    string credentialsPath;
    int haikuCallCount;
    int haikuTokensUsed;
    HashSet<string> haikuPending;

    // Smart context (ported from macOS)
    Dictionary<string, string> smartCtxCache;
    Dictionary<string, int> lastCtxHash;
    HashSet<string> pendingCtx;
    int haikuTokensToday;
    DateTime haikuBudgetDate;

    // Git info cache
    Dictionary<string, GitInfo> gitInfoCache;

    // Last scanned sessions (for overlay/menu reuse)
    List<Session> lastSessions;

    static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    static long UnixNow() {
        return (long)(DateTime.UtcNow - Epoch).TotalSeconds;
    }

    // -- Logging ---------------------------------------------------
    static string logPath;

    static void Log(string msg) {
        try {
            if (string.IsNullOrEmpty(logPath)) return;
            string line = DateTime.Now.ToString("HH:mm:ss") + " " + msg + "\r\n";
            File.AppendAllText(logPath, line, Encoding.UTF8);
        } catch {}
    }

    // -- Entry point -----------------------------------------------
    static void Main() {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        logPath = Path.Combine(home, ".claude", ".monitor_log");
        try {
            if (File.Exists(logPath)) {
                string[] old = File.ReadAllLines(logPath);
                if (old.Length > 50) {
                    string[] keep = new string[50];
                    Array.Copy(old, old.Length - 50, keep, 0, 50);
                    File.WriteAllLines(logPath, keep, Encoding.UTF8);
                }
            }
        } catch {}

        Log("Starting ClaudeMonitor v3");

        Application.ThreadException += new System.Threading.ThreadExceptionEventHandler(
            delegate(object sender, System.Threading.ThreadExceptionEventArgs e) {
                Log("ThreadException: " + e.Exception.ToString());
            });
        AppDomain.CurrentDomain.UnhandledException += new UnhandledExceptionEventHandler(
            delegate(object sender, UnhandledExceptionEventArgs e) {
                Log("UnhandledException: " + e.ExceptionObject.ToString());
            });

        bool created;
        try {
            Mutex mutex = new Mutex(true, @"Local\ClaudeMonitorTray", out created);
            if (!created) {
                Log("Another instance running, exiting");
                return;
            }
            Application.EnableVisualStyles();
            try {
                Application.Run(new ClaudeMonitor());
            } catch (Exception ex) {
                Log("FATAL: " + ex.ToString());
            }
            GC.KeepAlive(mutex);
        } catch (Exception ex) {
            Log("Mutex error: " + ex.ToString());
        }
    }

    // == PREFERENCES ===============================================

    class MonitorPrefs {
        public bool overlayEnabled = true;
        public int overlayX = -1;
        public int overlayY = -1;
        public double overlayOpacity = 0.92;
        public bool overlayCompact = false;
        public bool smartContextEnabled = true;
        public int smartContextInterval = 45;
        public bool notifyWaiting = true;
        public bool notifyContext = true;
        public bool showAgentCount = true;
        public int haikuDailyBudget = 10000;
        public bool launchAtLogin = false;
    }

    void LoadPrefs() {
        prefs = new MonitorPrefs();
        try {
            if (!File.Exists(prefsPath)) return;
            string text = File.ReadAllText(prefsPath, Encoding.UTF8);
            Dictionary<string, object> d = json.Deserialize<Dictionary<string, object>>(text);
            if (d == null) return;
            if (d.ContainsKey("overlayEnabled")) prefs.overlayEnabled = Convert.ToBoolean(d["overlayEnabled"]);
            if (d.ContainsKey("overlayX")) prefs.overlayX = Convert.ToInt32(d["overlayX"]);
            if (d.ContainsKey("overlayY")) prefs.overlayY = Convert.ToInt32(d["overlayY"]);
            if (d.ContainsKey("overlayOpacity")) prefs.overlayOpacity = Convert.ToDouble(d["overlayOpacity"]);
            if (d.ContainsKey("overlayCompact")) prefs.overlayCompact = Convert.ToBoolean(d["overlayCompact"]);
            if (d.ContainsKey("smartContextEnabled")) prefs.smartContextEnabled = Convert.ToBoolean(d["smartContextEnabled"]);
            if (d.ContainsKey("smartContextInterval")) prefs.smartContextInterval = Convert.ToInt32(d["smartContextInterval"]);
            if (d.ContainsKey("notifyWaiting")) prefs.notifyWaiting = Convert.ToBoolean(d["notifyWaiting"]);
            if (d.ContainsKey("notifyContext")) prefs.notifyContext = Convert.ToBoolean(d["notifyContext"]);
            if (d.ContainsKey("showAgentCount")) prefs.showAgentCount = Convert.ToBoolean(d["showAgentCount"]);
            if (d.ContainsKey("haikuDailyBudget")) prefs.haikuDailyBudget = Convert.ToInt32(d["haikuDailyBudget"]);
            if (d.ContainsKey("launchAtLogin")) prefs.launchAtLogin = Convert.ToBoolean(d["launchAtLogin"]);
            Log("Prefs loaded");
        } catch (Exception ex) {
            Log("LoadPrefs error: " + ex.Message);
        }
    }

    void SavePrefs() {
        try {
            Dictionary<string, object> d = new Dictionary<string, object>();
            d["overlayEnabled"] = prefs.overlayEnabled;
            d["overlayX"] = prefs.overlayX;
            d["overlayY"] = prefs.overlayY;
            d["overlayOpacity"] = prefs.overlayOpacity;
            d["overlayCompact"] = prefs.overlayCompact;
            d["smartContextEnabled"] = prefs.smartContextEnabled;
            d["smartContextInterval"] = prefs.smartContextInterval;
            d["notifyWaiting"] = prefs.notifyWaiting;
            d["notifyContext"] = prefs.notifyContext;
            d["showAgentCount"] = prefs.showAgentCount;
            d["haikuDailyBudget"] = prefs.haikuDailyBudget;
            d["launchAtLogin"] = prefs.launchAtLogin;
            string text = json.Serialize(d);
            File.WriteAllText(prefsPath, text, Encoding.UTF8);
        } catch (Exception ex) {
            Log("SavePrefs error: " + ex.Message);
        }
    }

    // == CONSTRUCTOR ===============================================

    ClaudeMonitor() {
        Log("Constructor start");
        claudeDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        json = new JavaScriptSerializer();
        prevStates = new Dictionary<string, string>();
        ctxWarned = new HashSet<string>();
        sessionNames = new Dictionary<string, string>();
        haikuPending = new HashSet<string>();
        gitInfoCache = new Dictionary<string, GitInfo>();
        smartCtxCache = new Dictionary<string, string>();
        lastCtxHash = new Dictionary<string, int>();
        pendingCtx = new HashSet<string>();
        lastSessions = new List<Session>();
        haikuBudgetDate = DateTime.Today;

        sessionNamesPath = Path.Combine(claudeDir, ".session_names");
        credentialsPath = Path.Combine(claudeDir, ".credentials.json");
        prefsPath = Path.Combine(claudeDir, ".monitor_prefs.json");

        LoadPrefs();
        LoadSessionNames();
        Log("Data loaded");

        // Tray icon
        tray = new NotifyIcon();
        tray.Icon = MakeDiamond(Color.FromArgb(100, 100, 140), false);
        tray.Text = "Claude Monitor";
        tray.Visible = true;
        tray.MouseClick += new MouseEventHandler(OnTrayClick);
        tray.ContextMenuStrip = new ContextMenuStrip();
        Log("Tray icon created");

        try {
            tray.ShowBalloonTip(3000, "Claude Monitor", "Running in system tray + overlay", ToolTipIcon.Info);
        } catch {}

        // Main refresh timer (8 seconds)
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 8000;
        timer.Tick += new EventHandler(OnTick);
        timer.Start();

        // Stale file cleanup (30 minutes)
        cleanupTimer = new System.Windows.Forms.Timer();
        cleanupTimer.Interval = 30 * 60 * 1000;
        cleanupTimer.Tick += new EventHandler(OnCleanupTick);
        cleanupTimer.Start();
        CleanupStaleFiles();

        // Smart context timer (default 45 seconds)
        smartCtxTimer = new System.Windows.Forms.Timer();
        smartCtxTimer.Interval = Math.Max(15, prefs.smartContextInterval) * 1000;
        smartCtxTimer.Tick += new EventHandler(OnSmartCtxTick);
        if (prefs.smartContextEnabled) smartCtxTimer.Start();

        // Overlay
        Log("Creating overlay");
        overlay = new OverlayForm(prefs);
        overlay.ActionRequested += new EventHandler<OverlayAction>(OnOverlayAction);
        overlay.PrefsChanged += new EventHandler(delegate(object s, EventArgs e) { SavePrefs(); });

        Log("Running first refresh");
        DoRefresh();
        Log("Constructor done");
    }

    void OnTrayClick(object sender, MouseEventArgs e) { ShowMenu(); }
    void OnTick(object sender, EventArgs e) { try { DoRefresh(); } catch {} }
    void OnCleanupTick(object sender, EventArgs e) { try { CleanupStaleFiles(); } catch {} }
    void OnSmartCtxTick(object sender, EventArgs e) {
        try { ResolveSmartContexts(); } catch (Exception ex) { Log("SmartCtx error: " + ex.Message); }
    }

    void OnOverlayAction(object sender, OverlayAction action) {
        try {
            switch (action.Type) {
                case OverlayActionType.Refresh: DoRefresh(); break;
                case OverlayActionType.CopyCompact:
                    if (!string.IsNullOrEmpty(action.SessionId)) CopyCompactForSession(action.SessionId);
                    break;
                case OverlayActionType.OpenFolder:
                    if (!string.IsNullOrEmpty(action.Dir))
                        try { Process.Start("explorer.exe", action.Dir); } catch {}
                    break;
                case OverlayActionType.ShowMenu: ShowMenu(); break;
                case OverlayActionType.ToggleCompact:
                    prefs.overlayCompact = !prefs.overlayCompact;
                    SavePrefs(); overlay.SetPrefs(prefs); DoRefresh(); break;
            }
        } catch {}
    }

    // == STALE FILE CLEANUP ========================================

    void CleanupStaleFiles() {
        try {
            if (!Directory.Exists(claudeDir)) return;
            string[] prefixes = new string[] { ".state_", ".ctx_", ".ctxlog_", ".ctx_pct_", ".tty_map_" };
            DateTime cutoff = DateTime.UtcNow.AddHours(-24);
            string[] files = Directory.GetFiles(claudeDir);
            for (int i = 0; i < files.Length; i++) {
                string name = Path.GetFileName(files[i]);
                bool matches = false;
                for (int p = 0; p < prefixes.Length; p++) {
                    if (name.StartsWith(prefixes[p])) { matches = true; break; }
                }
                if (!matches) continue;
                try {
                    FileInfo fi = new FileInfo(files[i]);
                    if (fi.LastWriteTimeUtc < cutoff) File.Delete(files[i]);
                } catch {}
            }
        } catch {}
    }

    // == ICON ======================================================

    Icon MakeDiamond(Color c, bool glow) {
        Bitmap bmp = new Bitmap(16, 16);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            if (glow) {
                using (SolidBrush gb = new SolidBrush(Color.FromArgb(60, c.R, c.G, c.B)))
                    g.FillPolygon(gb, new Point[] { new Point(8,0), new Point(16,8), new Point(8,16), new Point(0,8) });
                using (SolidBrush gb2 = new SolidBrush(Color.FromArgb(40, c.R, c.G, c.B)))
                    g.FillPolygon(gb2, new Point[] { new Point(8,0), new Point(15,8), new Point(8,16), new Point(1,8) });
            }
            using (SolidBrush brush = new SolidBrush(c))
                g.FillPolygon(brush, new Point[] { new Point(8,2), new Point(14,8), new Point(8,14), new Point(2,8) });
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // == SESSION + GIT MODELS ======================================

    class Session {
        public string Id = "";
        public string Project = "";
        public string Branch = "";
        public string Dir = "";
        public string State = "";
        public string Duration = "";
        public int CtxPct;
        public string AiName = "";
        public string ContextLine = "";
        public string SmartContext = "";
        public int AgentCount;
        public long StartedAt;
    }

    class GitInfo {
        public int ChangedFiles;
        public string LastCommit = "";
        public DateTime FetchedAt;
    }

    // == OVERLAY ACTION MODEL ======================================

    enum OverlayActionType { Refresh, CopyCompact, OpenFolder, ShowMenu, ToggleCompact }

    class OverlayAction : EventArgs {
        public OverlayActionType Type;
        public string SessionId = "";
        public string Dir = "";
        public OverlayAction(OverlayActionType t) { Type = t; }
    }

    // == HELPERS ====================================================

    static string DictStr(Dictionary<string, object> d, string key) {
        if (d == null || !d.ContainsKey(key)) return "";
        object val = d[key];
        if (val == null) return "";
        if (val is string) return (string)val;
        return "";
    }

    // == SESSION NAME CACHE ========================================

    void LoadSessionNames() {
        try {
            if (!File.Exists(sessionNamesPath)) return;
            string[] lines = File.ReadAllLines(sessionNamesPath, Encoding.UTF8);
            for (int i = 0; i < lines.Length; i++) {
                if (string.IsNullOrEmpty(lines[i])) continue;
                int pipe = lines[i].IndexOf('|');
                if (pipe < 0) continue;
                string sid = lines[i].Substring(0, pipe);
                string name = lines[i].Substring(pipe + 1);
                if (!string.IsNullOrEmpty(sid) && !string.IsNullOrEmpty(name))
                    sessionNames[sid] = name;
            }
        } catch {}
    }

    void SaveSessionNames() {
        try {
            List<string> lines = new List<string>();
            foreach (KeyValuePair<string, string> kv in sessionNames) lines.Add(kv.Key + "|" + kv.Value);
            File.WriteAllLines(sessionNamesPath, lines.ToArray(), Encoding.UTF8);
        } catch {}
    }

    // == OAUTH TOKEN ===============================================

    string ReadOAuthToken() {
        try {
            if (!File.Exists(credentialsPath)) return "";
            string text = File.ReadAllText(credentialsPath, Encoding.UTF8);
            Dictionary<string, object> creds = json.Deserialize<Dictionary<string, object>>(text);
            if (creds == null || !creds.ContainsKey("claudeAiOauth")) return "";
            Dictionary<string, object> oauth = creds["claudeAiOauth"] as Dictionary<string, object>;
            if (oauth == null) return "";
            return DictStr(oauth, "accessToken");
        } catch { return ""; }
    }

    // == FIRST USER MESSAGE (for naming) ===========================

    string ReadFirstUserMessage(string sessionId) {
        try {
            string projectsDir = Path.Combine(claudeDir, "projects");
            if (!Directory.Exists(projectsDir)) return "";
            string[] projDirs = Directory.GetDirectories(projectsDir);
            for (int i = 0; i < projDirs.Length; i++) {
                string jsonlPath = Path.Combine(projDirs[i], sessionId + ".jsonl");
                if (!File.Exists(jsonlPath)) continue;
                using (StreamReader reader = new StreamReader(jsonlPath, Encoding.UTF8)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        if (string.IsNullOrEmpty(line)) continue;
                        if (line.IndexOf("\"type\"") < 0 || line.IndexOf("\"user\"") < 0) continue;
                        try {
                            Dictionary<string, object> entry = json.Deserialize<Dictionary<string, object>>(line);
                            if (entry == null || DictStr(entry, "type") != "user") continue;
                            if (!entry.ContainsKey("message")) continue;
                            Dictionary<string, object> msg = entry["message"] as Dictionary<string, object>;
                            if (msg == null || !msg.ContainsKey("content")) continue;
                            object co = msg["content"];
                            if (co is string) {
                                string s = (string)co;
                                if (!string.IsNullOrEmpty(s)) return s.Length > 500 ? s.Substring(0, 500) : s;
                            }
                            IEnumerable arr = co as IEnumerable;
                            if (arr == null) continue;
                            foreach (object block in arr) {
                                Dictionary<string, object> bd = block as Dictionary<string, object>;
                                if (bd != null && DictStr(bd, "type") == "text") {
                                    string t = DictStr(bd, "text");
                                    if (!string.IsNullOrEmpty(t)) return t.Length > 500 ? t.Substring(0, 500) : t;
                                }
                            }
                        } catch { continue; }
                    }
                }
            }
        } catch {}
        return "";
    }

    // == HAIKU API (shared) =========================================

    string CallHaikuApi(string token, string prompt, int maxTokens) {
        try {
            string escaped = prompt.Replace("\\", "\\\\").Replace("\"", "\\\"")
                .Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t");
            string body = "{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":" + maxTokens +
                ",\"messages\":[{\"role\":\"user\",\"content\":\"" + escaped + "\"}]}";

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://api.anthropic.com/v1/messages");
            req.Method = "POST";
            req.ContentType = "application/json";
            req.Headers.Add("Authorization", "Bearer " + token);
            req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            req.Headers.Add("anthropic-version", "2023-06-01");
            req.Timeout = 10000;
            req.ReadWriteTimeout = 10000;

            byte[] bb = Encoding.UTF8.GetBytes(body);
            req.ContentLength = bb.Length;
            using (Stream s = req.GetRequestStream()) { s.Write(bb, 0, bb.Length); }

            string respText;
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) {
                respText = sr.ReadToEnd();
            }

            haikuCallCount++;
            Dictionary<string, object> rd = json.Deserialize<Dictionary<string, object>>(respText);
            if (rd == null) return "";

            if (rd.ContainsKey("usage")) {
                Dictionary<string, object> u = rd["usage"] as Dictionary<string, object>;
                if (u != null) {
                    int inp = 0, outp = 0;
                    if (u.ContainsKey("input_tokens")) try { inp = Convert.ToInt32(u["input_tokens"]); } catch {}
                    if (u.ContainsKey("output_tokens")) try { outp = Convert.ToInt32(u["output_tokens"]); } catch {}
                    haikuTokensUsed += inp + outp;
                    haikuTokensToday += inp + outp;
                }
            }

            if (!rd.ContainsKey("content")) return "";
            IEnumerable ce = rd["content"] as IEnumerable;
            if (ce == null) return "";
            foreach (object item in ce) {
                Dictionary<string, object> bl = item as Dictionary<string, object>;
                if (bl == null) continue;
                if (DictStr(bl, "type") == "text") {
                    string txt = DictStr(bl, "text").Trim();
                    if (!string.IsNullOrEmpty(txt)) {
                        if (txt.Length >= 2 && txt[0] == '"' && txt[txt.Length - 1] == '"')
                            txt = txt.Substring(1, txt.Length - 2);
                        return txt;
                    }
                }
            }
        } catch {}
        return "";
    }

    // == SESSION NAMING ============================================

    void RequestSessionName(string sessionId) {
        if (sessionNames.ContainsKey(sessionId)) return;
        lock (haikuPending) { if (haikuPending.Contains(sessionId)) return; }
        string token = ReadOAuthToken();
        if (string.IsNullOrEmpty(token)) return;
        string userMsg = ReadFirstUserMessage(sessionId);
        if (string.IsNullOrEmpty(userMsg)) return;

        lock (haikuPending) { haikuPending.Add(sessionId); }
        string sid = sessionId; string tok = token; string msg = userMsg;

        ThreadPool.QueueUserWorkItem(new WaitCallback(delegate(object state) {
            try {
                string result = CallHaikuApi(tok, "Give a 2-5 word title for this coding task. Reply ONLY the title. Task: " + msg, 30);
                if (!string.IsNullOrEmpty(result)) {
                    lock (sessionNames) { sessionNames[sid] = result; }
                    SaveSessionNames();
                }
            } catch {} finally { lock (haikuPending) { haikuPending.Remove(sid); } }
        }));
    }

    // == SMART CONTEXT ENGINE ======================================

    void ResolveSmartContexts() {
        if (!prefs.smartContextEnabled) return;
        if (DateTime.Today != haikuBudgetDate) { haikuTokensToday = 0; haikuBudgetDate = DateTime.Today; }
        if (haikuTokensToday >= prefs.haikuDailyBudget) return;

        string token = ReadOAuthToken();
        if (string.IsNullOrEmpty(token)) return;

        List<Session> sessions = lastSessions;
        for (int i = 0; i < sessions.Count; i++) {
            Session s = sessions[i];
            if (string.IsNullOrEmpty(s.Id)) continue;
            if (s.State != "active" && s.State != "waiting") continue;
            lock (pendingCtx) { if (pendingCtx.Contains(s.Id)) continue; }

            string ctxPath = Path.Combine(claudeDir, ".ctxlog_" + s.Id);
            string logData = "";
            try {
                if (!File.Exists(ctxPath)) continue;
                FileInfo fi = new FileInfo(ctxPath);
                if ((DateTime.UtcNow - fi.LastWriteTimeUtc).TotalSeconds > 120) continue;
                logData = File.ReadAllText(ctxPath, Encoding.UTF8);
            } catch { continue; }
            if (string.IsNullOrEmpty(logData.Trim())) continue;

            int hash = logData.GetHashCode();
            if (lastCtxHash.ContainsKey(s.Id) && lastCtxHash[s.Id] == hash) continue;
            lastCtxHash[s.Id] = hash;
            lock (pendingCtx) { pendingCtx.Add(s.Id); }

            string capSid = s.Id; string capToken = token; string capDir = s.Dir; string capLog = logData;

            ThreadPool.QueueUserWorkItem(new WaitCallback(delegate(object state) {
                try {
                    string[] lines = capLog.Split(new char[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
                    int start = Math.Max(0, lines.Length - 6);
                    StringBuilder actions = new StringBuilder();
                    for (int j = start; j < lines.Length; j++) {
                        if (actions.Length > 0) actions.Append(", ");
                        string ln = lines[j].Trim();
                        if (ln.Length > 80) ln = ln.Substring(0, 77) + "...";
                        actions.Append(ln);
                    }

                    string diffStat = "";
                    if (!string.IsNullOrEmpty(capDir)) {
                        string raw = RunGitCommandStatic(capDir, "diff --stat HEAD");
                        if (!string.IsNullOrEmpty(raw)) {
                            string[] dLines = raw.Split(new char[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
                            if (dLines.Length > 0) diffStat = ", Git changes: " + dLines[dLines.Length - 1].Trim();
                        }
                    }

                    string prompt = "What is this coding session doing RIGHT NOW? Recent actions: " +
                        actions.ToString() + diffStat + ". Reply in 5-10 words, present tense, specific. No quotes.";

                    string result = CallHaikuApi(capToken, prompt, 25);
                    if (!string.IsNullOrEmpty(result)) {
                        lock (smartCtxCache) { smartCtxCache[capSid] = result; }
                    }
                } catch {} finally { lock (pendingCtx) { pendingCtx.Remove(capSid); } }
            }));
        }
    }

    static string RunGitCommandStatic(string dir, string arguments) {
        try {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "git";
            psi.Arguments = "-C \"" + dir + "\" " + arguments;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            Process proc = new Process();
            proc.StartInfo = psi;
            proc.Start();
            string output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(3000);
            if (!proc.HasExited) { try { proc.Kill(); } catch {} return ""; }
            if (proc.ExitCode != 0) return "";
            return output.Trim();
        } catch { return ""; }
    }

    // == CONTEXT LOG ===============================================

    string ReadContextLog(string sessionId) {
        try {
            string ctxPath = Path.Combine(claudeDir, ".ctxlog_" + sessionId);
            if (!File.Exists(ctxPath)) return "";
            string[] allLines = File.ReadAllLines(ctxPath, Encoding.UTF8);
            for (int i = allLines.Length - 1; i >= 0; i--) {
                string line = allLines[i].Trim();
                if (!string.IsNullOrEmpty(line)) {
                    return line.Length > 80 ? line.Substring(0, 77) + "..." : line;
                }
            }
        } catch {}
        return "";
    }

    // == GIT INFO ==================================================

    GitInfo GetGitInfo(string dir) {
        if (string.IsNullOrEmpty(dir)) return null;
        if (gitInfoCache.ContainsKey(dir)) {
            GitInfo cached = gitInfoCache[dir];
            if ((DateTime.UtcNow - cached.FetchedAt).TotalSeconds < 30) return cached;
        }
        GitInfo info = new GitInfo();
        info.FetchedAt = DateTime.UtcNow;
        string porcelain = RunGitCommandStatic(dir, "status --porcelain");
        if (!string.IsNullOrEmpty(porcelain))
            info.ChangedFiles = porcelain.Split(new char[] { '\n' }, StringSplitOptions.RemoveEmptyEntries).Length;
        string lc = RunGitCommandStatic(dir, "log -1 --format=%s");
        if (!string.IsNullOrEmpty(lc)) info.LastCommit = lc.Length > 50 ? lc.Substring(0, 47) + "..." : lc;
        gitInfoCache[dir] = info;
        return info;
    }

    // == AGENT COUNT ===============================================

    int ReadAgentCount() {
        try {
            string path = Path.Combine(claudeDir, ".active_agents");
            if (!File.Exists(path)) return 0;
            int count;
            if (int.TryParse(File.ReadAllText(path).Trim(), out count)) return Math.Max(0, count);
        } catch {}
        return 0;
    }

    // == SCAN SESSIONS =============================================

    List<Session> ScanSessions() {
        List<Session> list = new List<Session>();
        string sessFile = Path.Combine(claudeDir, ".sessions.json");
        if (!File.Exists(sessFile)) return list;

        try {
            string text = File.ReadAllText(sessFile, Encoding.UTF8);
            List<Dictionary<string, object>> arr = json.Deserialize<List<Dictionary<string, object>>>(text);
            if (arr == null) return list;

            long now = UnixNow();
            int agentCount = prefs.showAgentCount ? ReadAgentCount() : 0;

            for (int idx = 0; idx < arr.Count; idx++) {
                Dictionary<string, object> s = arr[idx];
                string sid = DictStr(s, "id");
                if (string.IsNullOrEmpty(sid)) continue;

                long lastActive = 0;
                if (s.ContainsKey("lastActive")) try { lastActive = Convert.ToInt64(s["lastActive"]); } catch {}
                if (lastActive > 0 && (now - lastActive) > 21600) continue;

                string state = "";
                try {
                    string sf = Path.Combine(claudeDir, ".state_" + sid);
                    if (File.Exists(sf)) state = File.ReadAllText(sf).Trim();
                } catch {}

                int ctxPct = 0;
                try {
                    string cf = Path.Combine(claudeDir, ".ctx_pct_" + sid);
                    if (File.Exists(cf)) int.TryParse(File.ReadAllText(cf).Trim().Split('.')[0], out ctxPct);
                } catch {}

                string duration = ""; long startedAt = 0;
                if (s.ContainsKey("started")) {
                    try {
                        startedAt = Convert.ToInt64(s["started"]);
                        long elapsed = now - startedAt;
                        if (elapsed < 60) duration = elapsed + "s";
                        else if (elapsed < 3600) duration = (elapsed / 60) + "m";
                        else { long h = elapsed / 3600; long m = (elapsed % 3600) / 60; duration = m > 0 ? h + "h" + m + "m" : h + "h"; }
                    } catch {}
                }

                string aiName = "";
                lock (sessionNames) { if (sessionNames.ContainsKey(sid)) aiName = sessionNames[sid]; }
                if (string.IsNullOrEmpty(aiName)) RequestSessionName(sid);

                string smartCtx = "";
                lock (smartCtxCache) { if (smartCtxCache.ContainsKey(sid)) smartCtx = smartCtxCache[sid]; }

                string contextLine = ReadContextLog(sid);
                if (string.IsNullOrEmpty(contextLine)) {
                    if (state == "waiting") contextLine = "Waiting for your input";
                    else if (state == "active") contextLine = "Working...";
                    else contextLine = "Starting up...";
                }

                Session sess = new Session();
                sess.Id = sid; sess.Project = DictStr(s, "project"); sess.Branch = DictStr(s, "branch");
                sess.Dir = DictStr(s, "dir"); sess.State = state; sess.Duration = duration; sess.CtxPct = ctxPct;
                sess.AiName = aiName; sess.ContextLine = contextLine; sess.SmartContext = smartCtx;
                sess.AgentCount = agentCount; sess.StartedAt = startedAt;
                list.Add(sess);
            }
        } catch {}
        return list;
    }

    // == USAGE =====================================================

    int sessPct; int weekPct; string sessReset = ""; string weekReset = "";

    void ReadUsage() {
        string cache = Path.Combine(claudeDir, ".usage_cache.json");
        if (!File.Exists(cache)) return;
        try {
            string text = File.ReadAllText(cache, Encoding.UTF8);
            Dictionary<string, object> data = json.Deserialize<Dictionary<string, object>>(text);
            if (data == null) return;
            if (data.ContainsKey("five_hour")) {
                Dictionary<string, object> fh = data["five_hour"] as Dictionary<string, object>;
                if (fh != null) {
                    if (fh.ContainsKey("utilization")) try { sessPct = (int)Convert.ToDouble(fh["utilization"]); } catch {}
                    if (fh.ContainsKey("resets_at")) sessReset = FmtReset(DictStr(fh, "resets_at"));
                }
            }
            if (data.ContainsKey("seven_day")) {
                Dictionary<string, object> sd = data["seven_day"] as Dictionary<string, object>;
                if (sd != null) {
                    if (sd.ContainsKey("utilization")) try { weekPct = (int)Convert.ToDouble(sd["utilization"]); } catch {}
                    if (sd.ContainsKey("resets_at")) weekReset = FmtDay(DictStr(sd, "resets_at"));
                }
            }
        } catch {}
    }

    string ReadWeeklyDelta() {
        try {
            string sp = Path.Combine(claudeDir, ".weekly_start_pct");
            if (!File.Exists(sp)) return "";
            int startPct; if (!int.TryParse(File.ReadAllText(sp, Encoding.UTF8).Trim(), out startPct)) return "";
            int delta = weekPct - startPct;
            return delta > 0 ? "+" + delta + "%" : delta == 0 ? "" : delta + "%";
        } catch { return ""; }
    }

    string FmtReset(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try { double rem = (DateTimeOffset.Parse(iso) - DateTimeOffset.Now).TotalSeconds;
            return rem <= 0 ? "" : (int)(rem / 3600) + "h" + (int)((rem % 3600) / 60) + "m";
        } catch { return ""; }
    }

    string FmtDay(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try { return DateTimeOffset.Parse(iso).LocalDateTime.ToString("ddd HH:mm"); } catch { return ""; }
    }

    // == LAUNCH AT LOGIN ===========================================

    string GetStartupShortcutPath() {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ClaudeMonitor.lnk");
    }

    void SetLaunchAtLogin(bool enabled) {
        string shortcutPath = GetStartupShortcutPath();
        if (enabled) {
            try {
                string exePath = Path.Combine(claudeDir, "ClaudeMonitor.exe");
                if (!File.Exists(exePath)) exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
                Type wshType = Type.GetTypeFromProgID("WScript.Shell");
                if (wshType == null) return;
                object wshShell = Activator.CreateInstance(wshType);
                object sc = wshType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, wshShell, new object[] { shortcutPath });
                if (sc == null) return;
                Type sct = sc.GetType();
                sct.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { exePath });
                sct.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { Path.GetDirectoryName(exePath) });
                sct.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, sc, null);
                System.Runtime.InteropServices.Marshal.ReleaseComObject(sc);
                System.Runtime.InteropServices.Marshal.ReleaseComObject(wshShell);
            } catch {}
        } else {
            try { if (File.Exists(shortcutPath)) File.Delete(shortcutPath); } catch {}
        }
    }

    // == NOTIFICATIONS =============================================

    void CheckNotifications(List<Session> sessions) {
        try {
            for (int i = 0; i < sessions.Count; i++) {
                Session s = sessions[i];
                string prev = prevStates.ContainsKey(s.Id) ? prevStates[s.Id] : "";
                if (prefs.notifyWaiting && prev == "active" && s.State == "waiting") {
                    string title = !string.IsNullOrEmpty(s.AiName) ? s.AiName : s.Project;
                    tray.ShowBalloonTip(5000, title, "Ready for your input", ToolTipIcon.Info);
                }
                if (prefs.notifyContext && s.CtxPct >= 80 && !ctxWarned.Contains(s.Id)) {
                    ctxWarned.Add(s.Id);
                    tray.ShowBalloonTip(5000, s.Project + " -- Context " + s.CtxPct + "%", "Consider running /compact", ToolTipIcon.Warning);
                }
                prevStates[s.Id] = s.State;
            }
        } catch {}
    }

    // == REFRESH ===================================================

    void DoRefresh() {
        List<Session> sessions = ScanSessions();
        lastSessions = sessions;
        ReadUsage();
        CheckNotifications(sessions);
        UpdateIcon(sessions);

        if (overlay != null && prefs.overlayEnabled) {
            overlay.UpdateOverlay(sessions, sessPct, weekPct, sessReset, weekReset, ReadWeeklyDelta(), haikuCallCount, haikuTokensUsed);
            if (!overlay.Visible) { overlay.Show(); overlay.FadeIn(); }
        } else if (overlay != null && !prefs.overlayEnabled && overlay.Visible) {
            overlay.Hide();
        }
    }

    void UpdateIcon(List<Session> sessions) {
        bool hasCtx = false, hasWait = false, hasActive = false;
        int n = 0, w = 0;
        for (int i = 0; i < sessions.Count; i++) {
            n++;
            if (sessions[i].CtxPct >= 80) hasCtx = true;
            if (sessions[i].State == "waiting") { hasWait = true; w++; }
            if (sessions[i].State == "active") hasActive = true;
        }
        if (hasCtx) tray.Icon = MakeDiamond(Color.FromArgb(210, 56, 46), n > 0);
        else if (hasWait) tray.Icon = MakeDiamond(Color.FromArgb(242, 191, 51), n > 0);
        else if (hasActive) tray.Icon = MakeDiamond(Color.FromArgb(77, 217, 115), n > 0);
        else tray.Icon = MakeDiamond(Color.FromArgb(100, 100, 140), false);
        string tip = "Claude Monitor";
        if (n > 0) { tip = n + " session" + (n != 1 ? "s" : ""); if (w > 0) tip += " (" + w + " waiting)"; }
        if (tip.Length > 63) tip = tip.Substring(0, 63);
        tray.Text = tip;
    }

    // == COPY /COMPACT =============================================

    void CopyCompactForSession(string sessionId) {
        try {
            Clipboard.SetText("/compact");
            string name = "";
            lock (sessionNames) { if (sessionNames.ContainsKey(sessionId)) name = sessionNames[sessionId]; }
            if (string.IsNullOrEmpty(name)) name = "Session";
            tray.ShowBalloonTip(3000, name, "Copied /compact -- paste in the session terminal", ToolTipIcon.Info);
        } catch {}
    }

    // == HAIKU USAGE IMPACT ========================================

    // On Max plan, Haiku calls consume rate limit %. Estimate impact.
    // Haiku ~100 tokens/call. A 5-hour session limit is ~millions of tokens.
    // Impact is negligible but we show it for transparency.
    string EstimateHaikuImpact() {
        if (haikuTokensUsed <= 0) return "";
        // Rough estimate: each Haiku call is ~0.01% of a 5h session window
        double pctImpact = haikuCallCount * 0.01;
        if (pctImpact < 0.1) return "<0.1% session impact";
        return "~" + pctImpact.ToString("F1") + "% session impact";
    }

    // =============================================================
    // TRAY MENU
    // =============================================================

    void ShowMenu() {
        List<Session> sessions;
        try { sessions = ScanSessions(); lastSessions = sessions; ReadUsage(); UpdateIcon(sessions); }
        catch { sessions = new List<Session>(); }

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Renderer = new DarkRenderer();
        menu.BackColor = Color.FromArgb(18, 18, 28);
        menu.ForeColor = Color.White;
        menu.ShowImageMargin = false;
        menu.Padding = new Padding(0, 4, 0, 4);

        // Title
        string titleText = "\u25C7  Claude Monitor";
        if (sessions.Count > 0) titleText += " \u00B7 " + sessions.Count + " session" + (sessions.Count != 1 ? "s" : "");
        ToolStripItem ti = menu.Items.Add(titleText);
        ti.Font = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        ti.ForeColor = Color.FromArgb(160, 170, 210);
        ti.Enabled = false;
        menu.Items.Add(new ToolStripSeparator());

        if (sessions.Count == 0) {
            AddLabel(menu, "  No active sessions", Color.FromArgb(100, 100, 120));
        } else {
            Dictionary<string, List<Session>> groups = new Dictionary<string, List<Session>>();
            List<string> groupOrder = new List<string>();
            for (int i = 0; i < sessions.Count; i++) {
                string key = sessions[i].Dir;
                if (!groups.ContainsKey(key)) { groups[key] = new List<Session>(); groupOrder.Add(key); }
                groups[key].Add(sessions[i]);
            }

            for (int gi = 0; gi < groupOrder.Count; gi++) {
                string dirKey = groupOrder[gi];
                List<Session> group = groups[dirKey];
                Session first = group[0];

                ToolStripItem ph = menu.Items.Add("  " + first.Project);
                ph.Font = new Font("Segoe UI", 10f, FontStyle.Bold); ph.ForeColor = Color.White; ph.Enabled = false;

                if (!string.IsNullOrEmpty(first.Branch)) {
                    ToolStripItem bi = menu.Items.Add("    \u2387 " + first.Branch);
                    bi.Font = new Font("Segoe UI", 8.5f); bi.ForeColor = Color.FromArgb(80, 200, 190); bi.Enabled = false;
                }

                GitInfo ginfo = GetGitInfo(dirKey);
                if (ginfo != null && (ginfo.ChangedFiles > 0 || !string.IsNullOrEmpty(ginfo.LastCommit))) {
                    string gl = "    ";
                    if (ginfo.ChangedFiles > 0) gl += ginfo.ChangedFiles + " changed";
                    if (!string.IsNullOrEmpty(ginfo.LastCommit)) { if (ginfo.ChangedFiles > 0) gl += " \u00B7 "; gl += ginfo.LastCommit; }
                    AddLabel(menu, gl, Color.FromArgb(110, 115, 135));
                }

                if (group.Count > 1) {
                    AddLabel(menu, "    \u26A0 " + group.Count + " sessions on same branch", Color.FromArgb(255, 190, 70));
                    string baseBranch = first.Branch; int gs = group.Count;
                    ToolStripItem si = menu.Items.Add("    \u2442  Copy branch split commands");
                    si.Font = new Font("Segoe UI", 8.5f); si.ForeColor = Color.FromArgb(80, 200, 190);
                    si.Click += new EventHandler(delegate(object sender, EventArgs e) {
                        try {
                            StringBuilder cmds = new StringBuilder();
                            for (int k = 1; k < gs; k++) cmds.AppendLine("git branch " + baseBranch + "-s" + (k+1) + " " + baseBranch);
                            for (int k = 1; k < gs; k++) cmds.AppendLine("git checkout " + baseBranch + "-s" + (k+1));
                            Clipboard.SetText(cmds.ToString());
                            tray.ShowBalloonTip(3000, "Branch Split", "Commands copied", ToolTipIcon.Info);
                        } catch {}
                    });
                }

                for (int si2 = 0; si2 < group.Count; si2++) {
                    Session s = group[si2];
                    Color dc; string dn;
                    if (s.State == "active") { dc = Color.FromArgb(100, 220, 140); dn = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Working..."; }
                    else if (s.State == "waiting") { dc = Color.FromArgb(240, 190, 60); dn = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Waiting"; }
                    else { dc = Color.FromArgb(120, 120, 140); dn = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Session"; }

                    string sl = "    \u25CF " + dn;
                    if (prefs.showAgentCount && s.AgentCount > 0) sl += " (+" + s.AgentCount + " agent" + (s.AgentCount != 1 ? "s" : "") + ")";
                    if (!string.IsNullOrEmpty(s.Duration)) sl += "  \u00B7  " + s.Duration;
                    if (s.CtxPct > 0) sl += "  \u00B7  ctx " + s.CtxPct + "%";

                    ToolStripItem sessItem = menu.Items.Add(sl);
                    sessItem.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold); sessItem.ForeColor = dc;
                    if (s.State == "waiting") {
                        sessItem.Enabled = true;
                        string capSid = s.Id;
                        sessItem.Click += new EventHandler(delegate(object sender, EventArgs e) { CopyCompactForSession(capSid); });
                    } else { sessItem.Enabled = false; }

                    string ctxD = !string.IsNullOrEmpty(s.SmartContext) ? s.SmartContext : s.ContextLine;
                    if (!string.IsNullOrEmpty(ctxD)) {
                        ToolStripItem ci = menu.Items.Add("       " + ctxD);
                        ci.Font = new Font("Segoe UI", 8.5f, FontStyle.Italic);
                        ci.ForeColor = !string.IsNullOrEmpty(s.SmartContext) ? Color.FromArgb(140, 150, 200) : Color.FromArgb(100, 105, 125);
                        ci.Enabled = false;
                    }
                }

                string capturedDir = dirKey;
                ToolStripItem of = menu.Items.Add("    \u25A1  Open in Explorer");
                of.Font = new Font("Segoe UI", 8.5f); of.ForeColor = Color.FromArgb(80, 170, 190);
                of.Click += new EventHandler(delegate(object sender, EventArgs e) {
                    try { Process.Start("explorer.exe", capturedDir); } catch {}
                });
                menu.Items.Add(new ToolStripSeparator());
            }
        }

        // Usage bars
        if (sessPct > 0 || weekPct > 0) {
            AddBar(menu, "Session", sessPct, sessReset, "");
            AddBar(menu, "Weekly ", weekPct, weekReset, ReadWeeklyDelta());
            menu.Items.Add(new ToolStripSeparator());
        }

        // Haiku usage
        if (haikuCallCount > 0) {
            string hl = "  Haiku: " + haikuCallCount + " call" + (haikuCallCount != 1 ? "s" : "") + ", " + haikuTokensUsed + " tok";
            string impact = EstimateHaikuImpact();
            if (!string.IsNullOrEmpty(impact)) hl += " (" + impact + ")";
            if (haikuTokensToday > 0) hl += "  |  Today: " + haikuTokensToday + "/" + prefs.haikuDailyBudget;
            AddLabel(menu, hl, Color.FromArgb(120, 130, 170));
            menu.Items.Add(new ToolStripSeparator());
        }

        // Actions
        ToolStripItem refresh = menu.Items.Add("\u21BB  Refresh Now");
        refresh.ForeColor = Color.FromArgb(180, 185, 210); refresh.Font = new Font("Segoe UI", 9f);
        refresh.Click += new EventHandler(delegate(object sender, EventArgs e) { DoRefresh(); });

        // Settings
        ToolStripMenuItem settings = new ToolStripMenuItem("\u2699  Settings");
        settings.ForeColor = Color.FromArgb(180, 185, 210); settings.Font = new Font("Segoe UI", 9f);

        AddToggle(settings, "Waiting Alerts", prefs.notifyWaiting, delegate() { prefs.notifyWaiting = !prefs.notifyWaiting; SavePrefs(); });
        AddToggle(settings, "Context Warnings", prefs.notifyContext, delegate() { prefs.notifyContext = !prefs.notifyContext; SavePrefs(); });
        AddToggle(settings, "Smart Context (Haiku)", prefs.smartContextEnabled, delegate() {
            prefs.smartContextEnabled = !prefs.smartContextEnabled;
            if (prefs.smartContextEnabled) smartCtxTimer.Start(); else smartCtxTimer.Stop();
            SavePrefs();
        });
        AddToggle(settings, "Show Agent Count", prefs.showAgentCount, delegate() { prefs.showAgentCount = !prefs.showAgentCount; SavePrefs(); });

        settings.DropDownItems.Add(new ToolStripSeparator());

        AddToggle(settings, "Show Overlay", prefs.overlayEnabled, delegate() {
            prefs.overlayEnabled = !prefs.overlayEnabled;
            if (prefs.overlayEnabled && overlay != null) DoRefresh();
            else if (!prefs.overlayEnabled && overlay != null) overlay.Hide();
            SavePrefs();
        });
        AddToggle(settings, "Compact Overlay", prefs.overlayCompact, delegate() {
            prefs.overlayCompact = !prefs.overlayCompact; overlay.SetPrefs(prefs); SavePrefs(); DoRefresh();
        });

        ToolStripMenuItem opacMenu = new ToolStripMenuItem("Overlay Opacity");
        opacMenu.ForeColor = Color.White;
        double[] opVals = new double[] { 1.0, 0.92, 0.85, 0.75, 0.65 };
        string[] opLbls = new string[] { "100%", "92%", "85%", "75%", "65%" };
        for (int oi = 0; oi < opVals.Length; oi++) {
            double val = opVals[oi];
            ToolStripMenuItem oItem = new ToolStripMenuItem(opLbls[oi]);
            oItem.Checked = Math.Abs(prefs.overlayOpacity - val) < 0.02;
            oItem.ForeColor = Color.White;
            oItem.Click += new EventHandler(delegate(object sender, EventArgs e) {
                prefs.overlayOpacity = val; if (overlay != null) overlay.SetPrefs(prefs); SavePrefs();
            });
            opacMenu.DropDownItems.Add(oItem);
        }
        settings.DropDownItems.Add(opacMenu);

        ToolStripItem rp = new ToolStripMenuItem("Reset Overlay Position");
        rp.ForeColor = Color.White;
        rp.Click += new EventHandler(delegate(object sender, EventArgs e) {
            prefs.overlayX = -1; prefs.overlayY = -1; if (overlay != null) overlay.SetPrefs(prefs); SavePrefs();
        });
        settings.DropDownItems.Add(rp);
        settings.DropDownItems.Add(new ToolStripSeparator());

        AddToggle(settings, "Launch at Login", File.Exists(GetStartupShortcutPath()), delegate() {
            bool ns = !File.Exists(GetStartupShortcutPath()); SetLaunchAtLogin(ns); prefs.launchAtLogin = ns; SavePrefs();
        });
        menu.Items.Add(settings);

        ToolStripItem quit = menu.Items.Add("\u2715  Quit");
        quit.ForeColor = Color.FromArgb(180, 100, 100); quit.Font = new Font("Segoe UI", 9f);
        quit.Click += new EventHandler(delegate(object sender, EventArgs e) {
            tray.Visible = false; if (overlay != null) { overlay.Close(); overlay.Dispose(); } Application.Exit();
        });

        tray.ContextMenuStrip = menu;
        System.Reflection.MethodInfo mi = typeof(NotifyIcon).GetMethod("ShowContextMenu",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        if (mi != null) mi.Invoke(tray, null);
    }

    // == MENU HELPERS ==============================================

    delegate void ToggleAction();

    void AddToggle(ToolStripMenuItem parent, string label, bool isChecked, ToggleAction action) {
        ToolStripMenuItem item = new ToolStripMenuItem(label);
        item.Checked = isChecked; item.ForeColor = Color.White;
        item.Click += new EventHandler(delegate(object sender, EventArgs e) { action(); });
        parent.DropDownItems.Add(item);
    }

    void AddLabel(ContextMenuStrip menu, string text, Color color) {
        ToolStripItem item = menu.Items.Add(text);
        item.Enabled = false; item.ForeColor = color; item.Font = new Font("Segoe UI", 8.5f);
    }

    void AddBar(ContextMenuStrip menu, string label, int pct, string reset, string delta) {
        int filled = Math.Min(pct * 16 / 100, 16);
        string bar = new string('\u2588', filled) + new string('\u2591', 16 - filled);
        Color color = pct >= 80 ? Color.FromArgb(210, 70, 60) : pct >= 50 ? Color.FromArgb(200, 160, 40) : Color.FromArgb(80, 180, 110);
        string text = "  " + label + "  " + bar + "  " + pct + "%";
        if (!string.IsNullOrEmpty(reset)) text += "  \u21BB " + reset;
        if (!string.IsNullOrEmpty(delta)) text += "  " + delta;
        ToolStripItem item = menu.Items.Add(text);
        item.Enabled = false; item.Font = new Font("Consolas", 9f); item.ForeColor = color;
    }

    // =============================================================
    // DARK THEME RENDERER
    // =============================================================

    class DarkRenderer : ToolStripProfessionalRenderer {
        public DarkRenderer() : base(new DarkColors()) {}
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            if (e.Item is ToolStripSeparator) return;
            base.OnRenderItemText(e);
        }
    }

    class DarkColors : ProfessionalColorTable {
        static Color bg = Color.FromArgb(18, 18, 28);
        static Color border = Color.FromArgb(40, 40, 55);
        static Color hover = Color.FromArgb(32, 34, 50);
        public override Color MenuBorder { get { return border; } }
        public override Color MenuItemBorder { get { return border; } }
        public override Color MenuItemSelected { get { return hover; } }
        public override Color MenuItemSelectedGradientBegin { get { return hover; } }
        public override Color MenuItemSelectedGradientEnd { get { return hover; } }
        public override Color MenuStripGradientBegin { get { return bg; } }
        public override Color MenuStripGradientEnd { get { return bg; } }
        public override Color ToolStripDropDownBackground { get { return bg; } }
        public override Color ImageMarginGradientBegin { get { return bg; } }
        public override Color ImageMarginGradientMiddle { get { return bg; } }
        public override Color ImageMarginGradientEnd { get { return bg; } }
        public override Color SeparatorDark { get { return border; } }
        public override Color SeparatorLight { get { return border; } }
    }

    // =============================================================
    // OVERLAY FORM -- Mini-Dashboard
    // =============================================================

    class OverlayForm : Form {
        const int W = 320;
        const int HeaderH = 32;
        const int CardH = 52;
        const int UsageH = 44;
        const int ActionsH = 32;
        const int Pad = 8;
        const int CompactH = 48;

        MonitorPrefs prefs;
        List<Session> sessions;
        int sessPct, weekPct;
        string sessReset = "", weekReset = "", weeklyDelta = "";
        int haikuCalls, haikuTokens;

        bool dragging; Point dragOffset;
        int hoverCard = -1;
        int hoverAction = -1;
        bool closeHover;
        Rectangle closeRect;
        Rectangle[] cardRects;
        Rectangle refreshRect, compactCopyRect, openFolderRect;

        System.Windows.Forms.Timer fadeTimer;
        int fadeStep; double targetOpacity;

        Dictionary<string, DateTime> highlights;
        Dictionary<string, string> prevSmartCtx;

        public event EventHandler<OverlayAction> ActionRequested;
        public event EventHandler PrefsChanged;

        public OverlayForm(MonitorPrefs p) {
            prefs = p;
            sessions = new List<Session>();
            highlights = new Dictionary<string, DateTime>();
            prevSmartCtx = new Dictionary<string, string>();
            cardRects = new Rectangle[0];

            this.FormBorderStyle = FormBorderStyle.None;
            this.TopMost = true;
            this.ShowInTaskbar = false;
            this.StartPosition = FormStartPosition.Manual;
            this.BackColor = Color.FromArgb(16, 16, 26);
            this.Size = new Size(W, CompactH);
            this.Opacity = p.overlayOpacity;
            this.closeRect = new Rectangle(W - 26, 6, 18, 18);

            if (p.overlayX >= 0 && p.overlayY >= 0) this.Location = new Point(p.overlayX, p.overlayY);
            else {
                Rectangle scr = Screen.PrimaryScreen.WorkingArea;
                this.Location = new Point(scr.Right - W - 16, scr.Top + 16);
            }
            this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            RebuildRegion();
        }

        public void SetPrefs(MonitorPrefs p) {
            prefs = p; this.Opacity = p.overlayOpacity;
            if (p.overlayX >= 0 && p.overlayY >= 0) this.Location = new Point(p.overlayX, p.overlayY);
            else { Rectangle scr = Screen.PrimaryScreen.WorkingArea; this.Location = new Point(scr.Right - W - 16, scr.Top + 16); }
            RecalcSize(); this.Invalidate();
        }

        void RebuildRegion() {
            try {
                int r = 16;
                GraphicsPath path = new GraphicsPath();
                path.AddArc(0, 0, r, r, 180, 90); path.AddArc(this.Width - r, 0, r, r, 270, 90);
                path.AddArc(this.Width - r, this.Height - r, r, r, 0, 90); path.AddArc(0, this.Height - r, r, r, 90, 90);
                path.CloseFigure();
                if (this.Region != null) this.Region.Dispose();
                this.Region = new Region(path);
            } catch {}
        }

        void RecalcSize() {
            int h;
            if (prefs.overlayCompact) { h = CompactH; }
            else {
                int cards = sessions != null ? sessions.Count : 0;
                h = HeaderH + (cards * CardH) + UsageH + ActionsH + Pad;
                h = Math.Max(CompactH, Math.Min(h, 420));
            }
            if (this.Height != h) { this.Size = new Size(W, h); closeRect = new Rectangle(W - 26, 6, 18, 18); RebuildRegion(); }
        }

        public void UpdateOverlay(List<Session> sess, int sp, int wp, string sr, string wr, string wd, int hc, int ht) {
            if (sess != null) {
                for (int i = 0; i < sess.Count; i++) {
                    string sid = sess[i].Id; string sc = sess[i].SmartContext;
                    if (!string.IsNullOrEmpty(sc)) {
                        string prev = prevSmartCtx.ContainsKey(sid) ? prevSmartCtx[sid] : "";
                        if (!string.IsNullOrEmpty(prev) && prev != sc) highlights[sid] = DateTime.UtcNow.AddSeconds(2);
                        prevSmartCtx[sid] = sc;
                    }
                }
            }
            sessions = sess != null ? sess : new List<Session>();
            sessPct = sp; weekPct = wp; sessReset = sr; weekReset = wr; weeklyDelta = wd; haikuCalls = hc; haikuTokens = ht;
            RecalcSize(); this.Invalidate();
        }

        public void FadeIn() {
            targetOpacity = prefs.overlayOpacity; this.Opacity = 0; fadeStep = 0;
            if (fadeTimer != null) { fadeTimer.Stop(); fadeTimer.Dispose(); }
            fadeTimer = new System.Windows.Forms.Timer(); fadeTimer.Interval = 35;
            fadeTimer.Tick += new EventHandler(delegate(object s, EventArgs e) {
                fadeStep++; this.Opacity = targetOpacity * Math.Min(1.0, fadeStep / 6.0);
                if (fadeStep >= 6) { fadeTimer.Stop(); fadeTimer.Dispose(); fadeTimer = null; }
            });
            fadeTimer.Start();
        }

        // -- PAINT --

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

            using (LinearGradientBrush bgBrush = new LinearGradientBrush(new Point(0, 0), new Point(0, this.Height), Color.FromArgb(20, 20, 32), Color.FromArgb(14, 14, 24)))
                g.FillRectangle(bgBrush, 0, 0, this.Width, this.Height);
            using (Pen bp = new Pen(Color.FromArgb(40, 50, 70), 1f))
                g.DrawRectangle(bp, 0, 0, this.Width - 1, this.Height - 1);

            // Close button
            using (Font cf = new Font("Segoe UI", 9f, FontStyle.Bold))
            using (SolidBrush cb = new SolidBrush(closeHover ? Color.FromArgb(220, 70, 60) : Color.FromArgb(70, 75, 90)))
                g.DrawString("\u00D7", cf, cb, closeRect.X + 2, closeRect.Y);

            float y = 0;

            // HEADER
            Color diamondColor = Color.FromArgb(100, 120, 180);
            bool anyActive = false, anyWaiting = false;
            for (int i = 0; i < sessions.Count; i++) {
                if (sessions[i].State == "active") anyActive = true;
                if (sessions[i].State == "waiting") anyWaiting = true;
            }
            if (anyActive) diamondColor = Color.FromArgb(80, 200, 130);
            else if (anyWaiting) diamondColor = Color.FromArgb(230, 180, 50);

            using (SolidBrush db = new SolidBrush(diamondColor))
                g.FillPolygon(db, new Point[] { new Point(14,(int)(y+8)), new Point(20,(int)(y+16)), new Point(14,(int)(y+24)), new Point(8,(int)(y+16)) });

            using (Font hf = new Font("Segoe UI", 10f, FontStyle.Bold))
            using (SolidBrush wb = new SolidBrush(Color.FromArgb(200, 210, 240))) {
                string ht2 = sessions.Count > 0 ? sessions.Count + " session" + (sessions.Count != 1 ? "s" : "") : "Claude Monitor";
                g.DrawString(ht2, hf, wb, 28, y + 7);
                if (sessions.Count > 0) {
                    SizeF hs = g.MeasureString(ht2, hf);
                    float dx = 28 + hs.Width + 4;
                    for (int i = 0; i < sessions.Count; i++) {
                        Color dc = sessions[i].State == "active" ? Color.FromArgb(80, 200, 130) : sessions[i].State == "waiting" ? Color.FromArgb(230, 180, 50) : Color.FromArgb(60, 65, 80);
                        using (SolidBrush dBr = new SolidBrush(dc)) g.FillEllipse(dBr, dx + (i * 14), y + 12, 8, 8);
                    }
                }
            }
            y += HeaderH;

            if (prefs.overlayCompact) {
                if (sessPct > 0 || weekPct > 0) {
                    using (Font mf = new Font("Consolas", 8.5f))
                    using (SolidBrush sb = new SolidBrush(BarColor(sessPct))) {
                        string cl = "S:" + sessPct + "%"; if (weekPct > 0) cl += "  W:" + weekPct + "%";
                        g.DrawString(cl, mf, sb, 28, y - 2);
                    }
                }
                return;
            }

            // SESSION CARDS
            cardRects = new Rectangle[sessions.Count];
            for (int i = 0; i < sessions.Count; i++) {
                Session s = sessions[i];
                Rectangle cr = new Rectangle(6, (int)y, W - 12, CardH - 2);
                cardRects[i] = cr;

                Color cardBg = hoverCard == i ? Color.FromArgb(28, 30, 44) : Color.FromArgb(22, 22, 34);
                bool hl = highlights.ContainsKey(s.Id) && highlights[s.Id] > DateTime.UtcNow;
                if (hl) cardBg = Color.FromArgb(25, 30, 50);
                using (SolidBrush cBr = new SolidBrush(cardBg)) FillRoundedRect(g, cBr, cr, 8);
                if (hl) using (Pen hp = new Pen(Color.FromArgb(60, 100, 180, 255), 1f)) DrawRoundedRect(g, hp, cr, 8);

                float cx = cr.X + 8, cy = cr.Y + 4;

                // State dot
                Color dotC = s.State == "active" ? Color.FromArgb(80, 200, 130) : s.State == "waiting" ? Color.FromArgb(230, 180, 50) : Color.FromArgb(60, 65, 80);
                using (SolidBrush dBr = new SolidBrush(dotC)) g.FillEllipse(dBr, cx, cy + 3, 8, 8);

                // Name
                string nm = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Session";
                if (nm.Length > 28) nm = nm.Substring(0, 25) + "...";
                using (Font nf = new Font("Segoe UI", 9f, FontStyle.Bold))
                using (SolidBrush nb = new SolidBrush(Color.White)) g.DrawString(nm, nf, nb, cx + 12, cy);

                // Right: ctx% + duration
                string rt = "";
                if (s.CtxPct > 0) rt = "ctx " + s.CtxPct + "%";
                if (!string.IsNullOrEmpty(s.Duration)) { if (!string.IsNullOrEmpty(rt)) rt += " \u00B7 "; rt += s.Duration; }
                if (!string.IsNullOrEmpty(rt)) {
                    using (Font rf = new Font("Consolas", 8f))
                    using (SolidBrush rb = new SolidBrush(Color.FromArgb(100, 110, 140))) {
                        SizeF rs = g.MeasureString(rt, rf);
                        g.DrawString(rt, rf, rb, cr.Right - rs.Width - 6, cy + 1);
                    }
                }

                // Smart context / fallback
                string ctxL = !string.IsNullOrEmpty(s.SmartContext) ? s.SmartContext : s.ContextLine;
                if (!string.IsNullOrEmpty(ctxL)) {
                    if (ctxL.Length > 45) ctxL = ctxL.Substring(0, 42) + "...";
                    Color ctxC = !string.IsNullOrEmpty(s.SmartContext) ? Color.FromArgb(130, 150, 200) : Color.FromArgb(70, 75, 100);
                    using (Font ctf = new Font("Segoe UI", 8f))
                    using (SolidBrush ctb = new SolidBrush(ctxC)) g.DrawString(ctxL, ctf, ctb, cx + 12, cy + 16);
                }

                // Mini progress bar
                float bx = cx + 12, by = cy + 32, bw = 100, bh = 3;
                using (SolidBrush bgB = new SolidBrush(Color.FromArgb(30, 32, 48))) g.FillRectangle(bgB, bx, by, bw, bh);
                float fw = bw * Math.Min(s.CtxPct, 100) / 100f;
                if (fw > 0) using (SolidBrush fb = new SolidBrush(BarColor(s.CtxPct))) g.FillRectangle(fb, bx, by, fw, bh);

                // Waiting badge
                if (s.State == "waiting") {
                    using (Font bf = new Font("Segoe UI", 7f, FontStyle.Bold))
                    using (SolidBrush bb = new SolidBrush(Color.FromArgb(40, 38, 20)))
                    using (SolidBrush bt = new SolidBrush(Color.FromArgb(230, 180, 50))) {
                        string badge = "CLICK: /compact";
                        SizeF bs = g.MeasureString(badge, bf);
                        g.FillRectangle(bb, cr.Right - bs.Width - 12, by - 1, bs.Width + 4, 10);
                        g.DrawString(badge, bf, bt, cr.Right - bs.Width - 10, by - 2);
                    }
                }
                y += CardH;
            }

            // USAGE
            float uy = y + 4;
            if (sessPct > 0 || weekPct > 0) {
                DrawUsageBar(g, "Session", sessPct, sessReset, "", 10, uy);
                DrawUsageBar(g, "Weekly ", weekPct, weekReset, weeklyDelta, 10, uy + 18);
            } else {
                using (Font ef = new Font("Segoe UI", 8.5f))
                using (SolidBrush eb = new SolidBrush(Color.FromArgb(50, 55, 70)))
                    g.DrawString("No usage data yet", ef, eb, 10, uy + 4);
            }
            y += UsageH;

            // ACTIONS
            using (Pen sp = new Pen(Color.FromArgb(28, 32, 48), 1f)) g.DrawLine(sp, 8, y, W - 8, y);
            float ay = y + 4;
            int bW = (W - 24) / 3;
            refreshRect = new Rectangle(8, (int)ay, bW, ActionsH - 8);
            compactCopyRect = new Rectangle(8 + bW, (int)ay, bW, ActionsH - 8);
            openFolderRect = new Rectangle(8 + bW * 2, (int)ay, bW, ActionsH - 8);

            DrawActionBtn(g, "\u21BB Refresh", refreshRect, hoverAction == 0, Color.FromArgb(120, 140, 200));
            bool hw = false; for (int i = 0; i < sessions.Count; i++) if (sessions[i].State == "waiting") { hw = true; break; }
            DrawActionBtn(g, "/compact", compactCopyRect, hoverAction == 1, hw ? Color.FromArgb(230, 180, 50) : Color.FromArgb(45, 48, 60));
            DrawActionBtn(g, "\u25A1 Open", openFolderRect, hoverAction == 2, Color.FromArgb(80, 170, 160));
        }

        void DrawUsageBar(Graphics g, string label, int pct, string reset, string delta, float x, float y) {
            using (Font lf = new Font("Consolas", 8.5f)) {
                Color c = BarColor(pct);
                using (SolidBrush lb = new SolidBrush(Color.FromArgb(70, 75, 100))) g.DrawString(label, lf, lb, x, y);
                float bx = x + 56, bw = 96, bh = 8, by2 = y + 3;
                using (SolidBrush bgB = new SolidBrush(Color.FromArgb(28, 30, 44))) FillRoundedRect(g, bgB, new Rectangle((int)bx, (int)by2, (int)bw, (int)bh), 3);
                float fw = bw * Math.Min(pct, 100) / 100f;
                if (fw > 0) using (SolidBrush fb = new SolidBrush(c)) FillRoundedRect(g, fb, new Rectangle((int)bx, (int)by2, (int)fw, (int)bh), 3);
                string extra = pct + "%";
                if (!string.IsNullOrEmpty(reset)) extra += " \u21BB" + reset;
                if (!string.IsNullOrEmpty(delta)) extra += " " + delta;
                using (SolidBrush eb = new SolidBrush(c)) g.DrawString(extra, lf, eb, bx + bw + 4, y);
            }
        }

        void DrawActionBtn(Graphics g, string text, Rectangle r, bool hover, Color fg) {
            if (hover) using (SolidBrush hb = new SolidBrush(Color.FromArgb(28, 30, 46))) FillRoundedRect(g, hb, r, 6);
            using (Font bf = new Font("Segoe UI", 8f, FontStyle.Bold))
            using (SolidBrush tb = new SolidBrush(fg)) {
                SizeF ts = g.MeasureString(text, bf);
                g.DrawString(text, bf, tb, r.X + (r.Width - ts.Width) / 2, r.Y + (r.Height - ts.Height) / 2);
            }
        }

        static Color BarColor(int pct) {
            if (pct >= 80) return Color.FromArgb(210, 70, 60);
            if (pct >= 50) return Color.FromArgb(200, 160, 40);
            return Color.FromArgb(60, 160, 100);
        }

        static void FillRoundedRect(Graphics g, Brush b, Rectangle r, int rad) {
            if (rad < 1 || r.Width < rad * 2 || r.Height < rad * 2) { g.FillRectangle(b, r); return; }
            using (GraphicsPath p = new GraphicsPath()) {
                p.AddArc(r.X, r.Y, rad*2, rad*2, 180, 90); p.AddArc(r.Right-rad*2, r.Y, rad*2, rad*2, 270, 90);
                p.AddArc(r.Right-rad*2, r.Bottom-rad*2, rad*2, rad*2, 0, 90); p.AddArc(r.X, r.Bottom-rad*2, rad*2, rad*2, 90, 90);
                p.CloseFigure(); g.FillPath(b, p);
            }
        }

        static void DrawRoundedRect(Graphics g, Pen p, Rectangle r, int rad) {
            using (GraphicsPath gp = new GraphicsPath()) {
                gp.AddArc(r.X, r.Y, rad*2, rad*2, 180, 90); gp.AddArc(r.Right-rad*2, r.Y, rad*2, rad*2, 270, 90);
                gp.AddArc(r.Right-rad*2, r.Bottom-rad*2, rad*2, rad*2, 0, 90); gp.AddArc(r.X, r.Bottom-rad*2, rad*2, rad*2, 90, 90);
                gp.CloseFigure(); g.DrawPath(p, gp);
            }
        }

        // -- MOUSE --

        protected override void OnMouseDown(MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) {
                if (closeRect.Contains(e.Location)) {
                    this.Hide(); prefs.overlayEnabled = false;
                    if (PrefsChanged != null) PrefsChanged(this, EventArgs.Empty);
                    return;
                }
                if (!prefs.overlayCompact) {
                    if (refreshRect.Contains(e.Location)) { Fire(OverlayActionType.Refresh); return; }
                    if (compactCopyRect.Contains(e.Location)) {
                        for (int i = 0; i < sessions.Count; i++) {
                            if (sessions[i].State == "waiting") {
                                OverlayAction a = new OverlayAction(OverlayActionType.CopyCompact); a.SessionId = sessions[i].Id;
                                if (ActionRequested != null) ActionRequested(this, a); return;
                            }
                        }
                        return;
                    }
                    if (openFolderRect.Contains(e.Location)) {
                        if (sessions.Count > 0 && !string.IsNullOrEmpty(sessions[0].Dir)) {
                            OverlayAction a = new OverlayAction(OverlayActionType.OpenFolder); a.Dir = sessions[0].Dir;
                            if (ActionRequested != null) ActionRequested(this, a);
                        }
                        return;
                    }
                    for (int i = 0; i < cardRects.Length && i < sessions.Count; i++) {
                        if (cardRects[i].Contains(e.Location)) {
                            if (sessions[i].State == "waiting") {
                                OverlayAction a = new OverlayAction(OverlayActionType.CopyCompact); a.SessionId = sessions[i].Id;
                                if (ActionRequested != null) ActionRequested(this, a);
                            } else {
                                try { if (!string.IsNullOrEmpty(sessions[i].Dir)) Clipboard.SetText(sessions[i].Dir); } catch {}
                            }
                            return;
                        }
                    }
                }
                dragging = true; dragOffset = e.Location;
            } else if (e.Button == MouseButtons.Right) {
                ShowOverlayContextMenu(e.Location);
            }
        }

        void Fire(OverlayActionType t) {
            if (ActionRequested != null) ActionRequested(this, new OverlayAction(t));
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e) {
            if (e.Y < HeaderH) Fire(OverlayActionType.ToggleCompact);
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            bool changed = false;
            bool wc = closeHover; closeHover = closeRect.Contains(e.Location); if (wc != closeHover) changed = true;
            int nc = -1;
            if (!prefs.overlayCompact && cardRects != null) for (int i = 0; i < cardRects.Length; i++) if (cardRects[i].Contains(e.Location)) { nc = i; break; }
            if (nc != hoverCard) { hoverCard = nc; changed = true; }
            int na = -1;
            if (!prefs.overlayCompact) {
                if (refreshRect.Contains(e.Location)) na = 0;
                else if (compactCopyRect.Contains(e.Location)) na = 1;
                else if (openFolderRect.Contains(e.Location)) na = 2;
            }
            if (na != hoverAction) { hoverAction = na; changed = true; }
            if (changed) this.Invalidate();
            this.Cursor = (closeHover || nc >= 0 || na >= 0) ? Cursors.Hand : Cursors.Default;
            if (dragging) { Point cur = this.PointToScreen(e.Location); this.Location = new Point(cur.X - dragOffset.X, cur.Y - dragOffset.Y); }
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            if (e.Button == MouseButtons.Left && dragging) {
                dragging = false; prefs.overlayX = this.Location.X; prefs.overlayY = this.Location.Y;
                if (PrefsChanged != null) PrefsChanged(this, EventArgs.Empty);
            }
        }

        protected override void OnMouseLeave(EventArgs e) {
            bool c = false;
            if (hoverCard >= 0) { hoverCard = -1; c = true; }
            if (hoverAction >= 0) { hoverAction = -1; c = true; }
            if (closeHover) { closeHover = false; c = true; }
            if (c) this.Invalidate();
            this.Cursor = Cursors.Default;
        }

        void ShowOverlayContextMenu(Point location) {
            ContextMenuStrip ctx = new ContextMenuStrip();
            ctx.BackColor = Color.FromArgb(24, 24, 36); ctx.ForeColor = Color.White;
            ToolStripMenuItem compact = new ToolStripMenuItem("Compact Mode"); compact.Checked = prefs.overlayCompact;
            compact.Click += new EventHandler(delegate(object s2, EventArgs e2) { Fire(OverlayActionType.ToggleCompact); });
            ctx.Items.Add(compact);
            ToolStripMenuItem rpos = new ToolStripMenuItem("Reset Position");
            rpos.Click += new EventHandler(delegate(object s2, EventArgs e2) {
                prefs.overlayX = -1; prefs.overlayY = -1;
                Rectangle scr = Screen.PrimaryScreen.WorkingArea;
                this.Location = new Point(scr.Right - W - 16, scr.Top + 16);
                if (PrefsChanged != null) PrefsChanged(this, EventArgs.Empty);
            });
            ctx.Items.Add(rpos);
            ctx.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem hide = new ToolStripMenuItem("Hide Overlay");
            hide.Click += new EventHandler(delegate(object s2, EventArgs e2) {
                this.Hide(); prefs.overlayEnabled = false; if (PrefsChanged != null) PrefsChanged(this, EventArgs.Empty);
            });
            ctx.Items.Add(hide);
            ctx.Show(this, location);
        }

        protected override CreateParams CreateParams {
            get { CreateParams cp = base.CreateParams; cp.ExStyle = cp.ExStyle | 0x00000080; return cp; }
        }
    }
}
