// Claude Monitor -- Windows System Tray App (compiled .NET)
// Strictly C# 5 / .NET 4.0 compatible (NO ?., NO =>, NO $"", NO nameof, NO ToUnixTimeSeconds)
// Compile: csc.exe /target:winexe /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll ClaudeMonitorTray.cs
using System;
using System.Collections;
using System.Collections.Generic;
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
    string claudeDir;
    JavaScriptSerializer json;
    Dictionary<string, string> prevStates;
    HashSet<string> ctxWarned;
    bool notifyWaiting = true;
    bool notifyContext = true;

    // Haiku AI naming
    Dictionary<string, string> sessionNames;
    string sessionNamesPath;
    string credentialsPath;
    int haikuCallCount;
    int haikuTokensUsed;
    HashSet<string> haikuPending; // sessions currently being named

    static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    static long UnixNow() {
        return (long)(DateTime.UtcNow - Epoch).TotalSeconds;
    }

    // ── Entry point ─────────────────────────────────────
    static void Main() {
        bool created;
        Mutex mutex = new Mutex(true, @"Local\ClaudeMonitorTray", out created);
        if (!created) return;
        Application.EnableVisualStyles();
        Application.Run(new ClaudeMonitor());
        GC.KeepAlive(mutex);
    }

    // ── Constructor ─────────────────────────────────────
    ClaudeMonitor() {
        claudeDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        json = new JavaScriptSerializer();
        prevStates = new Dictionary<string, string>();
        ctxWarned = new HashSet<string>();
        sessionNames = new Dictionary<string, string>();
        haikuPending = new HashSet<string>();
        sessionNamesPath = Path.Combine(claudeDir, ".session_names");
        credentialsPath = Path.Combine(claudeDir, ".credentials.json");

        LoadSessionNames();

        tray = new NotifyIcon();
        tray.Icon = MakeDiamond(Color.FromArgb(100, 100, 140));
        tray.Text = "Claude Monitor";
        tray.Visible = true;
        tray.MouseClick += new MouseEventHandler(OnTrayClick);
        tray.ContextMenuStrip = new ContextMenuStrip();

        timer = new System.Windows.Forms.Timer();
        timer.Interval = 8000;
        timer.Tick += new EventHandler(OnTick);
        timer.Start();

        DoRefresh();
    }

    void OnTrayClick(object sender, MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) ShowMenu();
    }

    void OnTick(object sender, EventArgs e) {
        try {
            DoRefresh();
        } catch {
            // Never let timer crash the app
        }
    }

    // ── Icon ────────────────────────────────────────────
    Icon MakeDiamond(Color c) {
        Bitmap bmp = new Bitmap(16, 16);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            SolidBrush brush = new SolidBrush(c);
            g.FillPolygon(brush, new Point[] {
                new Point(8, 1), new Point(15, 8), new Point(8, 15), new Point(1, 8)
            });
            brush.Dispose();
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // ── Session model ───────────────────────────────────
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
    }

    // ── Safe dictionary string extraction ───────────────
    static string DictStr(Dictionary<string, object> d, string key) {
        if (d == null) return "";
        if (!d.ContainsKey(key)) return "";
        object val = d[key];
        if (val == null) return "";
        // Prevent "System.Collections.Generic.Dictionary`2" from showing as branch
        if (val is string) return (string)val;
        return "";
    }

    // ── Session name cache ──────────────────────────────
    void LoadSessionNames() {
        try {
            if (!File.Exists(sessionNamesPath)) return;
            string[] lines = File.ReadAllLines(sessionNamesPath, Encoding.UTF8);
            for (int i = 0; i < lines.Length; i++) {
                string line = lines[i];
                if (string.IsNullOrEmpty(line)) continue;
                int pipe = line.IndexOf('|');
                if (pipe < 0) continue;
                string sid = line.Substring(0, pipe);
                string name = line.Substring(pipe + 1);
                if (!string.IsNullOrEmpty(sid) && !string.IsNullOrEmpty(name)) {
                    sessionNames[sid] = name;
                }
            }
        } catch {
            // Ignore cache read errors
        }
    }

    void SaveSessionNames() {
        try {
            List<string> lines = new List<string>();
            foreach (KeyValuePair<string, string> kv in sessionNames) {
                lines.Add(kv.Key + "|" + kv.Value);
            }
            File.WriteAllLines(sessionNamesPath, lines.ToArray(), Encoding.UTF8);
        } catch {
            // Ignore cache write errors
        }
    }

    // ── Read OAuth token ────────────────────────────────
    string ReadOAuthToken() {
        try {
            if (!File.Exists(credentialsPath)) return "";
            string text = File.ReadAllText(credentialsPath, Encoding.UTF8);
            Dictionary<string, object> creds = json.Deserialize<Dictionary<string, object>>(text);
            if (creds == null) return "";
            if (!creds.ContainsKey("claudeAiOauth")) return "";
            Dictionary<string, object> oauth = creds["claudeAiOauth"] as Dictionary<string, object>;
            if (oauth == null) return "";
            return DictStr(oauth, "accessToken");
        } catch {
            return "";
        }
    }

    // ── Read first user message from JSONL ──────────────
    string ReadFirstUserMessage(string sessionId) {
        try {
            // Scan all project directories for this session's JSONL
            string projectsDir = Path.Combine(claudeDir, "projects");
            if (!Directory.Exists(projectsDir)) return "";

            string[] projDirs = Directory.GetDirectories(projectsDir);
            for (int i = 0; i < projDirs.Length; i++) {
                string jsonlPath = Path.Combine(projDirs[i], sessionId + ".jsonl");
                if (!File.Exists(jsonlPath)) continue;

                // Read line by line looking for first user message
                using (StreamReader reader = new StreamReader(jsonlPath, Encoding.UTF8)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        if (string.IsNullOrEmpty(line)) continue;
                        if (line.IndexOf("\"type\":\"user\"") < 0) continue;

                        try {
                            Dictionary<string, object> entry = json.Deserialize<Dictionary<string, object>>(line);
                            if (entry == null) continue;
                            string entryType = DictStr(entry, "type");
                            if (entryType != "user") continue;

                            if (!entry.ContainsKey("message")) continue;
                            Dictionary<string, object> msg = entry["message"] as Dictionary<string, object>;
                            if (msg == null) continue;

                            if (!msg.ContainsKey("content")) continue;
                            object contentObj = msg["content"];

                            // content can be a string or an array
                            if (contentObj is string) {
                                string s = (string)contentObj;
                                if (!string.IsNullOrEmpty(s)) {
                                    return s.Length > 500 ? s.Substring(0, 500) : s;
                                }
                            }

                            // content is an array of blocks
                            IEnumerable contentArr = contentObj as IEnumerable;
                            if (contentArr == null) continue;

                            foreach (object block in contentArr) {
                                Dictionary<string, object> blockDict = block as Dictionary<string, object>;
                                if (blockDict == null) continue;
                                string blockType = DictStr(blockDict, "type");
                                if (blockType == "text") {
                                    string textVal = DictStr(blockDict, "text");
                                    if (!string.IsNullOrEmpty(textVal)) {
                                        return textVal.Length > 500 ? textVal.Substring(0, 500) : textVal;
                                    }
                                }
                            }
                        } catch {
                            continue;
                        }
                    }
                }
            }
        } catch {
            // Ignore file read errors
        }
        return "";
    }

    // ── Haiku API call for session naming ────────────────
    void RequestSessionName(string sessionId) {
        // Already named or already pending
        if (sessionNames.ContainsKey(sessionId)) return;
        if (haikuPending.Contains(sessionId)) return;

        string token = ReadOAuthToken();
        if (string.IsNullOrEmpty(token)) return;

        string userMsg = ReadFirstUserMessage(sessionId);
        if (string.IsNullOrEmpty(userMsg)) return;

        haikuPending.Add(sessionId);

        // Capture for closure
        string capturedSid = sessionId;
        string capturedToken = token;
        string capturedMsg = userMsg;

        ThreadPool.QueueUserWorkItem(new WaitCallback(delegate(object state) {
            try {
                string result = CallHaikuApi(capturedToken, capturedMsg);
                if (!string.IsNullOrEmpty(result)) {
                    // Marshal back to UI thread for thread safety
                    lock (sessionNames) {
                        sessionNames[capturedSid] = result;
                    }
                    SaveSessionNames();
                }
            } catch {
                // Ignore API errors
            } finally {
                lock (haikuPending) {
                    haikuPending.Remove(capturedSid);
                }
            }
        }));
    }

    string CallHaikuApi(string token, string userMessage) {
        try {
            // Escape the user message for JSON
            string escapedMsg = userMessage
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"")
                .Replace("\n", "\\n")
                .Replace("\r", "\\r")
                .Replace("\t", "\\t");

            string requestBody = "{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"Give a 2-5 word title for this coding task. Reply ONLY the title. Task: " + escapedMsg + "\"}]}";

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://api.anthropic.com/v1/messages");
            req.Method = "POST";
            req.ContentType = "application/json";
            req.Headers.Add("Authorization", "Bearer " + token);
            req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            req.Headers.Add("anthropic-version", "2023-06-01");
            req.Timeout = 8000;
            req.ReadWriteTimeout = 8000;

            byte[] bodyBytes = Encoding.UTF8.GetBytes(requestBody);
            req.ContentLength = bodyBytes.Length;
            using (Stream reqStream = req.GetRequestStream()) {
                reqStream.Write(bodyBytes, 0, bodyBytes.Length);
            }

            string responseText;
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
                using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) {
                    responseText = sr.ReadToEnd();
                }
            }

            haikuCallCount++;

            // Parse response
            Dictionary<string, object> respDict = json.Deserialize<Dictionary<string, object>>(responseText);
            if (respDict == null) return "";

            // Track tokens from usage
            if (respDict.ContainsKey("usage")) {
                Dictionary<string, object> usage = respDict["usage"] as Dictionary<string, object>;
                if (usage != null) {
                    if (usage.ContainsKey("input_tokens")) {
                        try { haikuTokensUsed += Convert.ToInt32(usage["input_tokens"]); } catch {}
                    }
                    if (usage.ContainsKey("output_tokens")) {
                        try { haikuTokensUsed += Convert.ToInt32(usage["output_tokens"]); } catch {}
                    }
                }
            }

            // Extract text from content array
            // content may be ArrayList or object[] depending on deserializer
            if (!respDict.ContainsKey("content")) return "";
            object contentObj = respDict["content"];

            IEnumerable contentEnum = contentObj as IEnumerable;
            if (contentEnum == null) return "";

            foreach (object item in contentEnum) {
                Dictionary<string, object> block = item as Dictionary<string, object>;
                if (block == null) continue;
                string blockType = DictStr(block, "type");
                if (blockType == "text") {
                    string text = DictStr(block, "text");
                    if (!string.IsNullOrEmpty(text)) {
                        string trimmed = text.Trim();
                        // Remove surrounding quotes if present
                        if (trimmed.Length >= 2 && trimmed[0] == '"' && trimmed[trimmed.Length - 1] == '"') {
                            trimmed = trimmed.Substring(1, trimmed.Length - 2);
                        }
                        return trimmed;
                    }
                }
            }
        } catch {
            // Ignore all API errors
        }
        return "";
    }

    // ── Read context log ────────────────────────────────
    string ReadContextLog(string sessionId) {
        try {
            string ctxPath = Path.Combine(claudeDir, ".ctxlog_" + sessionId);
            if (!File.Exists(ctxPath)) return "";

            // Read last few lines
            string[] allLines = File.ReadAllLines(ctxPath, Encoding.UTF8);
            if (allLines.Length == 0) return "";

            // Get last non-empty line
            for (int i = allLines.Length - 1; i >= 0; i--) {
                string line = allLines[i].Trim();
                if (!string.IsNullOrEmpty(line)) {
                    // Truncate long lines
                    if (line.Length > 80) {
                        line = line.Substring(0, 77) + "...";
                    }
                    return line;
                }
            }
        } catch {
            // Ignore
        }
        return "";
    }

    // ── Scan sessions ───────────────────────────────────
    List<Session> ScanSessions() {
        List<Session> list = new List<Session>();
        string sessFile = Path.Combine(claudeDir, ".sessions.json");
        if (!File.Exists(sessFile)) return list;

        try {
            string text = File.ReadAllText(sessFile, Encoding.UTF8);
            List<Dictionary<string, object>> arr = json.Deserialize<List<Dictionary<string, object>>>(text);
            if (arr == null) return list;

            long now = UnixNow();
            for (int idx = 0; idx < arr.Count; idx++) {
                Dictionary<string, object> s = arr[idx];
                string sid = DictStr(s, "id");
                if (string.IsNullOrEmpty(sid)) continue;

                // Skip stale (>6h)
                long lastActive = 0;
                if (s.ContainsKey("lastActive")) {
                    try { lastActive = Convert.ToInt64(s["lastActive"]); } catch {}
                }
                if (lastActive > 0 && (now - lastActive) > 21600) continue;

                // Read state from file
                string state = "";
                try {
                    string stateFile = Path.Combine(claudeDir, ".state_" + sid);
                    if (File.Exists(stateFile)) {
                        state = File.ReadAllText(stateFile).Trim();
                    }
                } catch {}

                // Read context percent
                int ctxPct = 0;
                try {
                    string ctxFile = Path.Combine(claudeDir, ".ctx_pct_" + sid);
                    if (File.Exists(ctxFile)) {
                        string pctStr = File.ReadAllText(ctxFile).Trim().Split('.')[0];
                        int.TryParse(pctStr, out ctxPct);
                    }
                } catch {}

                // Compute duration
                string duration = "";
                if (s.ContainsKey("started")) {
                    try {
                        long started = Convert.ToInt64(s["started"]);
                        long elapsed = now - started;
                        if (elapsed < 60) {
                            duration = elapsed + "s";
                        } else if (elapsed < 3600) {
                            duration = (elapsed / 60) + "m";
                        } else {
                            long h = elapsed / 3600;
                            long m = (elapsed % 3600) / 60;
                            duration = m > 0 ? h + "h" + m + "m" : h + "h";
                        }
                    } catch {}
                }

                // Get AI name from cache (or trigger Haiku naming)
                string aiName = "";
                lock (sessionNames) {
                    if (sessionNames.ContainsKey(sid)) {
                        aiName = sessionNames[sid];
                    }
                }
                if (string.IsNullOrEmpty(aiName)) {
                    RequestSessionName(sid);
                }

                // Read context log for smart context line
                string contextLine = ReadContextLog(sid);
                if (string.IsNullOrEmpty(contextLine)) {
                    if (state == "waiting") {
                        contextLine = "Waiting for your input";
                    } else if (state == "active") {
                        contextLine = "Working...";
                    } else {
                        contextLine = "Starting up...";
                    }
                }

                Session sess = new Session();
                sess.Id = sid;
                sess.Project = DictStr(s, "project");
                sess.Branch = DictStr(s, "branch");
                sess.Dir = DictStr(s, "dir");
                sess.State = state;
                sess.Duration = duration;
                sess.CtxPct = ctxPct;
                sess.AiName = aiName;
                sess.ContextLine = contextLine;
                list.Add(sess);
            }
        } catch {
            // Ignore scan errors
        }
        return list;
    }

    // ── Usage ───────────────────────────────────────────
    int sessPct;
    int weekPct;
    string sessReset = "";
    string weekReset = "";

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
                    if (fh.ContainsKey("utilization")) {
                        try { sessPct = (int)Convert.ToDouble(fh["utilization"]); } catch {}
                    }
                    if (fh.ContainsKey("resets_at")) {
                        sessReset = FmtReset(DictStr(fh, "resets_at"));
                    }
                }
            }
            if (data.ContainsKey("seven_day")) {
                Dictionary<string, object> sd = data["seven_day"] as Dictionary<string, object>;
                if (sd != null) {
                    if (sd.ContainsKey("utilization")) {
                        try { weekPct = (int)Convert.ToDouble(sd["utilization"]); } catch {}
                    }
                    if (sd.ContainsKey("resets_at")) {
                        weekReset = FmtDay(DictStr(sd, "resets_at"));
                    }
                }
            }
        } catch {
            // Ignore usage read errors
        }
    }

    string FmtReset(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try {
            DateTimeOffset dt = DateTimeOffset.Parse(iso);
            double rem = (dt - DateTimeOffset.Now).TotalSeconds;
            if (rem <= 0) return "";
            return (int)(rem / 3600) + "h" + (int)((rem % 3600) / 60) + "m";
        } catch {
            return "";
        }
    }

    string FmtDay(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try {
            DateTimeOffset dt = DateTimeOffset.Parse(iso);
            DateTime local = dt.LocalDateTime;
            return local.ToString("ddd HH:mm");
        } catch {
            return "";
        }
    }

    // ── Notifications ───────────────────────────────────
    void CheckNotifications(List<Session> sessions) {
        try {
            for (int i = 0; i < sessions.Count; i++) {
                Session s = sessions[i];
                string prev = prevStates.ContainsKey(s.Id) ? prevStates[s.Id] : "";

                if (notifyWaiting && prev == "active" && s.State == "waiting") {
                    string title = s.Project;
                    if (!string.IsNullOrEmpty(s.AiName)) {
                        title = s.AiName;
                    }
                    tray.ShowBalloonTip(5000, title, "Ready for your input", ToolTipIcon.Info);
                }

                if (notifyContext && s.CtxPct >= 80 && !ctxWarned.Contains(s.Id)) {
                    ctxWarned.Add(s.Id);
                    tray.ShowBalloonTip(5000,
                        s.Project + " \u2014 Context " + s.CtxPct + "%",
                        "Consider running /compact", ToolTipIcon.Warning);
                }

                prevStates[s.Id] = s.State;
            }
        } catch {
            // Never crash on notifications
        }
    }

    // ── Refresh + Icon ──────────────────────────────────
    void DoRefresh() {
        List<Session> sessions = ScanSessions();
        ReadUsage();
        CheckNotifications(sessions);
        UpdateIcon(sessions);
    }

    void UpdateIcon(List<Session> sessions) {
        bool hasCtx = false;
        bool hasWait = false;
        bool hasActive = false;
        int n = 0;
        int w = 0;

        for (int i = 0; i < sessions.Count; i++) {
            n++;
            if (sessions[i].CtxPct >= 80) hasCtx = true;
            if (sessions[i].State == "waiting") { hasWait = true; w++; }
            if (sessions[i].State == "active") hasActive = true;
        }

        if (hasCtx) tray.Icon = MakeDiamond(Color.FromArgb(210, 56, 46));
        else if (hasWait) tray.Icon = MakeDiamond(Color.FromArgb(242, 191, 51));
        else if (hasActive) tray.Icon = MakeDiamond(Color.FromArgb(77, 217, 115));
        else tray.Icon = MakeDiamond(Color.FromArgb(100, 100, 140));

        string tip = "Claude Monitor";
        if (n > 0) {
            tip = n + " session" + (n != 1 ? "s" : "");
            if (w > 0) tip = tip + " (" + w + " waiting)";
        }
        if (tip.Length > 63) tip = tip.Substring(0, 63);
        tray.Text = tip;
    }

    // ── Menu ────────────────────────────────────────────
    void ShowMenu() {
        List<Session> sessions;
        try {
            sessions = ScanSessions();
            ReadUsage();
            UpdateIcon(sessions);
        } catch {
            sessions = new List<Session>();
        }

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Renderer = new DarkRenderer();
        menu.BackColor = Color.FromArgb(24, 24, 36);
        menu.ForeColor = Color.White;
        menu.ShowImageMargin = false;

        // ── Title ──
        ToolStripItem titleItem = menu.Items.Add("\u25C7  Claude Monitor");
        titleItem.Font = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        titleItem.ForeColor = Color.FromArgb(160, 170, 210);
        titleItem.Enabled = false;
        menu.Items.Add(new ToolStripSeparator());

        if (sessions.Count == 0) {
            AddLabel(menu, "  No active sessions", Color.FromArgb(100, 100, 120));
        } else {
            // Group by directory
            Dictionary<string, List<Session>> groups = new Dictionary<string, List<Session>>();
            List<string> groupOrder = new List<string>();
            for (int i = 0; i < sessions.Count; i++) {
                string key = sessions[i].Dir;
                if (!groups.ContainsKey(key)) {
                    groups[key] = new List<Session>();
                    groupOrder.Add(key);
                }
                groups[key].Add(sessions[i]);
            }

            for (int gi = 0; gi < groupOrder.Count; gi++) {
                string dirKey = groupOrder[gi];
                List<Session> group = groups[dirKey];
                Session first = group[0];

                // Project header: bold white project name
                ToolStripItem projHeader = menu.Items.Add("  " + first.Project);
                projHeader.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
                projHeader.ForeColor = Color.White;
                projHeader.Enabled = false;

                // Branch in teal below project name
                if (!string.IsNullOrEmpty(first.Branch)) {
                    ToolStripItem branchItem = menu.Items.Add("    \u2387 " + first.Branch);
                    branchItem.Font = new Font("Segoe UI", 8.5f);
                    branchItem.ForeColor = Color.FromArgb(80, 200, 190);
                    branchItem.Enabled = false;
                }

                // Multi-session warning
                if (group.Count > 1) {
                    ToolStripItem warn = menu.Items.Add("    \u26A0 " + group.Count + " sessions on same branch");
                    warn.ForeColor = Color.FromArgb(255, 190, 70);
                    warn.Font = new Font("Segoe UI", 8.5f);
                    warn.Enabled = false;
                }

                // Sessions
                for (int si = 0; si < group.Count; si++) {
                    Session s = group[si];

                    // State dot + name/AI name + duration + context%
                    string dot;
                    Color dotColor;
                    string displayName;

                    if (s.State == "active") {
                        dot = "\u25CF";
                        dotColor = Color.FromArgb(100, 220, 140);
                        displayName = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Working...";
                    } else if (s.State == "waiting") {
                        dot = "\u25CF";
                        dotColor = Color.FromArgb(240, 190, 60);
                        displayName = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Waiting for input";
                    } else {
                        dot = "\u25CB";
                        dotColor = Color.FromArgb(120, 120, 140);
                        displayName = !string.IsNullOrEmpty(s.AiName) ? s.AiName : "Session";
                    }

                    // Build session line
                    string sessionLine = "    " + dot + " " + displayName;
                    if (!string.IsNullOrEmpty(s.Duration)) {
                        sessionLine = sessionLine + "  \u00B7  " + s.Duration;
                    }
                    if (s.CtxPct > 0) {
                        sessionLine = sessionLine + "  \u00B7  ctx " + s.CtxPct + "%";
                    }

                    ToolStripItem sessItem = menu.Items.Add(sessionLine);
                    sessItem.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
                    sessItem.ForeColor = dotColor;
                    sessItem.Enabled = false;

                    // Context line below session (gray, indented)
                    if (!string.IsNullOrEmpty(s.ContextLine)) {
                        ToolStripItem ctxItem = menu.Items.Add("       " + s.ContextLine);
                        ctxItem.Font = new Font("Segoe UI", 8.5f);
                        ctxItem.ForeColor = Color.FromArgb(100, 105, 125);
                        ctxItem.Enabled = false;
                    }
                }

                menu.Items.Add(new ToolStripSeparator());
            }
        }

        // ── Usage bars ──
        if (sessPct > 0 || weekPct > 0) {
            AddBar(menu, "Session", sessPct, sessReset);
            AddBar(menu, "Weekly ", weekPct, weekReset);
            menu.Items.Add(new ToolStripSeparator());
        }

        // ── Haiku usage line ──
        if (haikuCallCount > 0) {
            string haikuLine = "  Monitor: " + haikuCallCount + " Haiku call" + (haikuCallCount != 1 ? "s" : "");
            if (haikuTokensUsed > 0) {
                haikuLine = haikuLine + " (" + haikuTokensUsed + " tokens)";
            }
            ToolStripItem haikuItem = menu.Items.Add(haikuLine);
            haikuItem.Font = new Font("Segoe UI", 8.5f);
            haikuItem.ForeColor = Color.FromArgb(120, 130, 170);
            haikuItem.Enabled = false;
            menu.Items.Add(new ToolStripSeparator());
        }

        // ── Actions ──
        ToolStripItem refresh = menu.Items.Add("\u21BB  Refresh");
        refresh.ForeColor = Color.FromArgb(180, 185, 210);
        refresh.Font = new Font("Segoe UI", 9f);
        refresh.Click += new EventHandler(delegate(object sender, EventArgs e) {
            DoRefresh();
        });

        ToolStripMenuItem settings = new ToolStripMenuItem("\u2699  Settings");
        settings.ForeColor = Color.FromArgb(180, 185, 210);
        settings.Font = new Font("Segoe UI", 9f);

        ToolStripMenuItem nw = new ToolStripMenuItem("Waiting Alerts");
        nw.Checked = notifyWaiting;
        nw.ForeColor = Color.White;
        nw.Click += new EventHandler(delegate(object sender, EventArgs e) {
            notifyWaiting = !notifyWaiting;
            nw.Checked = notifyWaiting;
        });
        settings.DropDownItems.Add(nw);

        ToolStripMenuItem nc = new ToolStripMenuItem("Context Warnings");
        nc.Checked = notifyContext;
        nc.ForeColor = Color.White;
        nc.Click += new EventHandler(delegate(object sender, EventArgs e) {
            notifyContext = !notifyContext;
            nc.Checked = notifyContext;
        });
        settings.DropDownItems.Add(nc);

        menu.Items.Add(settings);

        ToolStripItem quit = menu.Items.Add("\u2715  Quit");
        quit.ForeColor = Color.FromArgb(180, 100, 100);
        quit.Font = new Font("Segoe UI", 9f);
        quit.Click += new EventHandler(delegate(object sender, EventArgs e) {
            tray.Visible = false;
            Application.Exit();
        });

        tray.ContextMenuStrip = menu;
        System.Reflection.MethodInfo mi = typeof(NotifyIcon).GetMethod("ShowContextMenu",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        if (mi != null) mi.Invoke(tray, null);
    }

    // ── Menu helpers ────────────────────────────────────
    void AddLabel(ContextMenuStrip menu, string text, Color color) {
        ToolStripItem item = menu.Items.Add(text);
        item.Enabled = false;
        item.ForeColor = color;
        item.Font = new Font("Segoe UI", 9.5f);
    }

    void AddBar(ContextMenuStrip menu, string label, int pct, string reset) {
        int filled = Math.Min(pct * 16 / 100, 16);
        string bar = new string('\u2588', filled) + new string('\u2591', 16 - filled);
        Color color;
        if (pct >= 80) {
            color = Color.FromArgb(210, 70, 60);
        } else if (pct >= 50) {
            color = Color.FromArgb(200, 160, 40);
        } else {
            color = Color.FromArgb(80, 180, 110);
        }
        string text = "  " + label + "  " + bar + "  " + pct + "%";
        if (!string.IsNullOrEmpty(reset)) {
            text = text + "  \u21BB " + reset;
        }
        ToolStripItem item = menu.Items.Add(text);
        item.Enabled = false;
        item.Font = new Font("Consolas", 9f);
        item.ForeColor = color;
    }

    // ── Dark theme renderer ─────────────────────────────
    class DarkRenderer : ToolStripProfessionalRenderer {
        public DarkRenderer() : base(new DarkColors()) {}

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            if (e.Item is ToolStripSeparator) return;
            base.OnRenderItemText(e);
        }
    }

    class DarkColors : ProfessionalColorTable {
        public override Color MenuBorder {
            get { return Color.FromArgb(40, 40, 55); }
        }
        public override Color MenuItemBorder {
            get { return Color.FromArgb(50, 50, 70); }
        }
        public override Color MenuItemSelected {
            get { return Color.FromArgb(40, 42, 58); }
        }
        public override Color MenuItemSelectedGradientBegin {
            get { return Color.FromArgb(40, 42, 58); }
        }
        public override Color MenuItemSelectedGradientEnd {
            get { return Color.FromArgb(40, 42, 58); }
        }
        public override Color MenuStripGradientBegin {
            get { return Color.FromArgb(24, 24, 36); }
        }
        public override Color MenuStripGradientEnd {
            get { return Color.FromArgb(24, 24, 36); }
        }
        public override Color ToolStripDropDownBackground {
            get { return Color.FromArgb(24, 24, 36); }
        }
        public override Color ImageMarginGradientBegin {
            get { return Color.FromArgb(24, 24, 36); }
        }
        public override Color ImageMarginGradientMiddle {
            get { return Color.FromArgb(24, 24, 36); }
        }
        public override Color ImageMarginGradientEnd {
            get { return Color.FromArgb(24, 24, 36); }
        }
        public override Color SeparatorDark {
            get { return Color.FromArgb(40, 40, 55); }
        }
        public override Color SeparatorLight {
            get { return Color.FromArgb(40, 40, 55); }
        }
    }
}
