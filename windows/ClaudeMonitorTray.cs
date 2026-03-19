// Claude Monitor -- Windows System Tray App (compiled .NET)
// Strictly C# 5 / .NET 4.0 compatible for maximum Windows compatibility
// Compile: csc.exe /target:winexe /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll ClaudeMonitorTray.cs
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class ClaudeMonitor : ApplicationContext {
    NotifyIcon tray;
    System.Windows.Forms.Timer timer;
    string claudeDir;
    JavaScriptSerializer json = new JavaScriptSerializer();
    Dictionary<string, string> prevStates = new Dictionary<string, string>();
    HashSet<string> ctxWarned = new HashSet<string>();
    bool notifyWaiting = true, notifyContext = true;

    static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    static long UnixNow() { return (long)(DateTime.UtcNow - Epoch).TotalSeconds; }

    static void Main() {
        bool created;
        var mutex = new Mutex(true, @"Local\ClaudeMonitorTray", out created);
        if (!created) return;
        Application.EnableVisualStyles();
        Application.Run(new ClaudeMonitor());
        GC.KeepAlive(mutex);
    }

    ClaudeMonitor() {
        claudeDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        tray = new NotifyIcon();
        tray.Icon = MakeDiamond(Color.FromArgb(100, 100, 140));
        tray.Text = "Claude Monitor";
        tray.Visible = true;
        tray.MouseClick += OnTrayClick;
        tray.ContextMenuStrip = new ContextMenuStrip();
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 8000;
        timer.Tick += OnTick;
        timer.Start();
        DoRefresh();
    }

    void OnTrayClick(object sender, MouseEventArgs e) {
        if (e.Button == MouseButtons.Left) ShowMenu();
    }
    void OnTick(object sender, EventArgs e) { DoRefresh(); }

    Icon MakeDiamond(Color c) {
        var bmp = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var brush = new SolidBrush(c);
            g.FillPolygon(brush, new Point[] {
                new Point(8, 1), new Point(15, 8), new Point(8, 15), new Point(1, 8)
            });
            brush.Dispose();
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // ── Session model ─────────────────────────────────────
    class Session {
        public string Id = "";
        public string Project = "";
        public string Branch = "";
        public string Dir = "";
        public string State = "";
        public string Duration = "";
        public int CtxPct;
    }

    static string DictStr(Dictionary<string, object> d, string key) {
        if (d == null || !d.ContainsKey(key) || d[key] == null) return "";
        return d[key].ToString();
    }

    // ── Scan ──────────────────────────────────────────────
    List<Session> ScanSessions() {
        var list = new List<Session>();
        var sessFile = Path.Combine(claudeDir, ".sessions.json");
        if (!File.Exists(sessFile)) return list;

        try {
            var text = File.ReadAllText(sessFile, System.Text.Encoding.UTF8);
            var arr = json.Deserialize<List<Dictionary<string, object>>>(text);
            if (arr == null) return list;

            long now = UnixNow();
            foreach (var s in arr) {
                var sid = DictStr(s, "id");
                if (string.IsNullOrEmpty(sid)) continue;

                // Skip stale (>6h)
                long lastActive = 0;
                if (s.ContainsKey("lastActive")) {
                    try { lastActive = Convert.ToInt64(s["lastActive"]); } catch {}
                }
                if (lastActive > 0 && (now - lastActive) > 21600) continue;

                var state = "";
                var stateFile = Path.Combine(claudeDir, ".state_" + sid);
                if (File.Exists(stateFile)) {
                    try { state = File.ReadAllText(stateFile).Trim(); } catch {}
                }

                int ctxPct = 0;
                var ctxFile = Path.Combine(claudeDir, ".ctx_pct_" + sid);
                if (File.Exists(ctxFile)) {
                    try {
                        var pctStr = File.ReadAllText(ctxFile).Trim().Split('.')[0];
                        int.TryParse(pctStr, out ctxPct);
                    } catch {}
                }

                var duration = "";
                if (s.ContainsKey("started")) {
                    try {
                        long started = Convert.ToInt64(s["started"]);
                        long elapsed = now - started;
                        if (elapsed < 60) duration = elapsed + "s";
                        else if (elapsed < 3600) duration = (elapsed / 60) + "m";
                        else {
                            long h = elapsed / 3600;
                            long m = (elapsed % 3600) / 60;
                            duration = m > 0 ? h + "h" + m + "m" : h + "h";
                        }
                    } catch {}
                }

                var sess = new Session();
                sess.Id = sid;
                sess.Project = DictStr(s, "project");
                sess.Branch = DictStr(s, "branch");
                sess.Dir = DictStr(s, "dir");
                sess.State = state;
                sess.Duration = duration;
                sess.CtxPct = ctxPct;
                list.Add(sess);
            }
        } catch {}
        return list;
    }

    // ── Usage ─────────────────────────────────────────────
    int sessPct, weekPct;
    string sessReset = "", weekReset = "";

    void ReadUsage() {
        var cache = Path.Combine(claudeDir, ".usage_cache.json");
        if (!File.Exists(cache)) return;
        try {
            var text = File.ReadAllText(cache, System.Text.Encoding.UTF8);
            var data = json.Deserialize<Dictionary<string, object>>(text);
            if (data == null) return;

            if (data.ContainsKey("five_hour")) {
                var fh = data["five_hour"] as Dictionary<string, object>;
                if (fh != null) {
                    if (fh.ContainsKey("utilization"))
                        sessPct = (int)Convert.ToDouble(fh["utilization"]);
                    if (fh.ContainsKey("resets_at"))
                        sessReset = FmtReset(DictStr(fh, "resets_at"));
                }
            }
            if (data.ContainsKey("seven_day")) {
                var sd = data["seven_day"] as Dictionary<string, object>;
                if (sd != null) {
                    if (sd.ContainsKey("utilization"))
                        weekPct = (int)Convert.ToDouble(sd["utilization"]);
                    if (sd.ContainsKey("resets_at"))
                        weekReset = FmtDay(DictStr(sd, "resets_at"));
                }
            }
        } catch {}
    }

    string FmtReset(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try {
            var dt = DateTimeOffset.Parse(iso);
            double rem = (dt - DateTimeOffset.Now).TotalSeconds;
            if (rem <= 0) return "";
            return (int)(rem / 3600) + "h" + (int)((rem % 3600) / 60) + "m";
        } catch { return ""; }
    }

    string FmtDay(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try {
            var dt = DateTimeOffset.Parse(iso).LocalDateTime;
            return dt.ToString("ddd HH:mm");
        } catch { return ""; }
    }

    // ── Notifications ─────────────────────────────────────
    void CheckNotifications(List<Session> sessions) {
        foreach (var s in sessions) {
            string prev = prevStates.ContainsKey(s.Id) ? prevStates[s.Id] : "";
            if (notifyWaiting && prev == "active" && s.State == "waiting")
                tray.ShowBalloonTip(5000, s.Project, "Ready for your input", ToolTipIcon.Info);
            if (notifyContext && s.CtxPct >= 80 && !ctxWarned.Contains(s.Id)) {
                ctxWarned.Add(s.Id);
                tray.ShowBalloonTip(5000, s.Project + " \u2014 Context " + s.CtxPct + "%",
                    "Consider running /compact", ToolTipIcon.Warning);
            }
            prevStates[s.Id] = s.State;
        }
    }

    // ── Refresh + Icon ────────────────────────────────────
    void DoRefresh() {
        var sessions = ScanSessions();
        ReadUsage();
        CheckNotifications(sessions);
        UpdateIcon(sessions);
    }

    void UpdateIcon(List<Session> sessions) {
        bool hasCtx = sessions.Any(s => s.CtxPct >= 80);
        bool hasWait = sessions.Any(s => s.State == "waiting");
        bool hasActive = sessions.Any(s => s.State == "active");

        if (hasCtx) tray.Icon = MakeDiamond(Color.FromArgb(210, 56, 46));
        else if (hasWait) tray.Icon = MakeDiamond(Color.FromArgb(242, 191, 51));
        else if (hasActive) tray.Icon = MakeDiamond(Color.FromArgb(77, 217, 115));
        else tray.Icon = MakeDiamond(Color.FromArgb(100, 100, 140));

        int n = sessions.Count;
        int w = sessions.Count(s => s.State == "waiting");
        string tip = "Claude Monitor";
        if (n > 0) {
            tip = n + " session" + (n != 1 ? "s" : "");
            if (w > 0) tip += " (" + w + " waiting)";
        }
        if (tip.Length > 63) tip = tip.Substring(0, 63);
        tray.Text = tip;
    }

    // ── Menu ──────────────────────────────────────────────
    void ShowMenu() {
        var sessions = ScanSessions();
        ReadUsage();
        UpdateIcon(sessions);

        var menu = new ContextMenuStrip();
        menu.Renderer = new DarkRenderer();
        menu.BackColor = Color.FromArgb(30, 30, 42);
        menu.ForeColor = Color.White;
        menu.ShowImageMargin = false;

        if (sessions.Count == 0) {
            AddLabel(menu, "No active sessions", Color.FromArgb(130, 130, 150));
        } else {
            foreach (var group in sessions.GroupBy(s => s.Dir).OrderBy(g => g.Key)) {
                var first = group.First();
                string hdr = first.Project;
                if (!string.IsNullOrEmpty(first.Branch)) hdr += "  " + first.Branch;
                var header = menu.Items.Add(hdr);
                header.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
                header.ForeColor = Color.White;
                header.Enabled = false;

                if (group.Count() > 1) {
                    var warn = menu.Items.Add("  \u26A0 " + group.Count() + " sessions on same branch");
                    warn.ForeColor = Color.FromArgb(255, 190, 70);
                    warn.Font = new Font("Segoe UI", 9f);
                    warn.Enabled = false;
                }

                menu.Items.Add(new ToolStripSeparator());

                foreach (var s in group) {
                    string dot = s.State == "active" ? "\u25CF " : s.State == "waiting" ? "\u25CF " : "\u25CB ";
                    string name = s.State == "active" ? "Working..." : s.State == "waiting" ? "Waiting for input" : "Session";
                    string label = "  " + dot + name + "  " + s.Duration;
                    if (s.CtxPct > 0) label += "  ctx " + s.CtxPct + "%";

                    var item = menu.Items.Add(label);
                    item.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
                    if (s.State == "active") item.ForeColor = Color.FromArgb(100, 220, 140);
                    else if (s.State == "waiting") item.ForeColor = Color.FromArgb(240, 190, 60);
                    else item.ForeColor = Color.FromArgb(140, 140, 140);
                }
                menu.Items.Add(new ToolStripSeparator());
            }
        }

        // Usage bars
        if (sessPct > 0 || weekPct > 0) {
            AddBar(menu, "Session", sessPct, sessReset);
            AddBar(menu, "Weekly ", weekPct, weekReset);
            menu.Items.Add(new ToolStripSeparator());
        }

        var refresh = menu.Items.Add("Refresh");
        refresh.ForeColor = Color.White;
        refresh.Click += delegate { DoRefresh(); };

        var settings = new ToolStripMenuItem("Settings");
        settings.ForeColor = Color.White;

        var nw = new ToolStripMenuItem("Waiting Alerts");
        nw.Checked = notifyWaiting;
        nw.ForeColor = Color.White;
        nw.Click += delegate { notifyWaiting = !notifyWaiting; nw.Checked = notifyWaiting; };
        settings.DropDownItems.Add(nw);

        var nc = new ToolStripMenuItem("Context Warnings");
        nc.Checked = notifyContext;
        nc.ForeColor = Color.White;
        nc.Click += delegate { notifyContext = !notifyContext; nc.Checked = notifyContext; };
        settings.DropDownItems.Add(nc);

        menu.Items.Add(settings);

        var quit = menu.Items.Add("Quit");
        quit.ForeColor = Color.White;
        quit.Click += delegate { tray.Visible = false; Application.Exit(); };

        tray.ContextMenuStrip = menu;
        var mi = typeof(NotifyIcon).GetMethod("ShowContextMenu",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        if (mi != null) mi.Invoke(tray, null);
    }

    void AddLabel(ContextMenuStrip menu, string text, Color color) {
        var item = menu.Items.Add(text);
        item.Enabled = false;
        item.ForeColor = color;
        item.Font = new Font("Segoe UI", 9.5f);
    }

    void AddBar(ContextMenuStrip menu, string label, int pct, string reset) {
        int filled = Math.Min(pct * 16 / 100, 16);
        string bar = new string('\u2588', filled) + new string('\u2591', 16 - filled);
        Color color;
        if (pct >= 80) color = Color.FromArgb(210, 70, 60);
        else if (pct >= 50) color = Color.FromArgb(200, 160, 40);
        else color = Color.FromArgb(80, 180, 110);
        string text = "  " + label + "  " + bar + "  " + pct + "%";
        if (!string.IsNullOrEmpty(reset)) text += "  \u21BB " + reset;
        var item = menu.Items.Add(text);
        item.Enabled = false;
        item.Font = new Font("Consolas", 9f);
        item.ForeColor = color;
    }

    class DarkRenderer : ToolStripProfessionalRenderer {
        public DarkRenderer() : base(new DarkColors()) {}
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            if (e.Item is ToolStripSeparator) return;
            base.OnRenderItemText(e);
        }
    }

    class DarkColors : ProfessionalColorTable {
        public override Color MenuBorder { get { return Color.FromArgb(50, 50, 65); } }
        public override Color MenuItemBorder { get { return Color.FromArgb(60, 60, 80); } }
        public override Color MenuItemSelected { get { return Color.FromArgb(50, 50, 70); } }
        public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(50, 50, 70); } }
        public override Color MenuItemSelectedGradientEnd { get { return Color.FromArgb(50, 50, 70); } }
        public override Color MenuStripGradientBegin { get { return Color.FromArgb(30, 30, 42); } }
        public override Color MenuStripGradientEnd { get { return Color.FromArgb(30, 30, 42); } }
        public override Color ToolStripDropDownBackground { get { return Color.FromArgb(30, 30, 42); } }
        public override Color ImageMarginGradientBegin { get { return Color.FromArgb(30, 30, 42); } }
        public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(30, 30, 42); } }
        public override Color ImageMarginGradientEnd { get { return Color.FromArgb(30, 30, 42); } }
        public override Color SeparatorDark { get { return Color.FromArgb(50, 50, 65); } }
        public override Color SeparatorLight { get { return Color.FromArgb(50, 50, 65); } }
    }
}
