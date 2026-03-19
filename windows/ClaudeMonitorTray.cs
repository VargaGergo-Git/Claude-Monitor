// Claude Monitor — Windows System Tray App (compiled .NET)
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

    static void Main() {
        bool created;
        var mutex = new Mutex(true, @"Local\ClaudeMonitorTray", out created);
        if (!created) return; // already running
        Application.EnableVisualStyles();
        Application.Run(new ClaudeMonitor());
        GC.KeepAlive(mutex);
    }

    ClaudeMonitor() {
        claudeDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        tray = new NotifyIcon {
            Icon = MakeDiamond(Color.FromArgb(100, 100, 140)),
            Text = "Claude Monitor",
            Visible = true
        };
        tray.Click += (s, e) => { if (((MouseEventArgs)e).Button == MouseButtons.Left) ShowMenu(); };
        tray.ContextMenuStrip = new ContextMenuStrip();

        timer = new System.Windows.Forms.Timer { Interval = 8000 };
        timer.Tick += (s, e) => Refresh();
        timer.Start();
        Refresh();
    }

    // ── Icon ──────────────────────────────────────────────
    Icon MakeDiamond(Color c) {
        var bmp = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            g.FillPolygon(new SolidBrush(c), new[] {
                new Point(8, 1), new Point(15, 8), new Point(8, 15), new Point(1, 8)
            });
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // ── Scan ──────────────────────────────────────────────
    class Session {
        public string Id, Project, Branch, Dir, State, Duration;
        public int CtxPct, Modified;
    }

    List<Session> ScanSessions() {
        var list = new List<Session>();
        var sessFile = Path.Combine(claudeDir, ".sessions.json");
        if (!File.Exists(sessFile)) return list;

        try {
            var text = File.ReadAllText(sessFile, System.Text.Encoding.UTF8);
            var arr = json.Deserialize<List<Dictionary<string, object>>>(text);
            if (arr == null) return list;

            foreach (var s in arr) {
                var sid = s.ContainsKey("id") ? s["id"]?.ToString() : "";
                if (string.IsNullOrEmpty(sid)) continue;

                var state = "";
                var stateFile = Path.Combine(claudeDir, ".state_" + sid);
                if (File.Exists(stateFile)) state = File.ReadAllText(stateFile).Trim();

                var ctxPct = 0;
                var ctxFile = Path.Combine(claudeDir, ".ctx_pct_" + sid);
                if (File.Exists(ctxFile)) {
                    var pctStr = File.ReadAllText(ctxFile).Trim().Split('.')[0];
                    int.TryParse(pctStr, out ctxPct);
                }

                var project = s.ContainsKey("project") ? s["project"]?.ToString() ?? "" : "";
                var branch = s.ContainsKey("branch") ? s["branch"]?.ToString() ?? "" : "";
                var dir = s.ContainsKey("dir") ? s["dir"]?.ToString() ?? "" : "";

                // Duration
                var duration = "";
                if (s.ContainsKey("started")) {
                    try {
                        var started = Convert.ToInt64(s["started"]);
                        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - started;
                        if (elapsed < 60) duration = elapsed + "s";
                        else if (elapsed < 3600) duration = (elapsed / 60) + "m";
                        else { var h = elapsed / 3600; var m = (elapsed % 3600) / 60; duration = m > 0 ? h + "h" + m + "m" : h + "h"; }
                    } catch {}
                }

                list.Add(new Session { Id = sid, Project = project, Branch = branch, Dir = dir, State = state, Duration = duration, CtxPct = ctxPct });
            }
        } catch {}

        // Remove stale sessions (>6 hours)
        var cutoff = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 21600;
        try {
            var text = File.ReadAllText(sessFile, System.Text.Encoding.UTF8);
            var arr = json.Deserialize<List<Dictionary<string, object>>>(text);
            if (arr != null)
                list.RemoveAll(s => {
                    var match = arr.FirstOrDefault(a => a.ContainsKey("id") && a["id"]?.ToString() == s.Id);
                    if (match != null && match.ContainsKey("lastActive")) {
                        try { return Convert.ToInt64(match["lastActive"]) < cutoff; } catch {}
                    }
                    return false;
                });
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
                if (fh != null && fh.ContainsKey("utilization"))
                    sessPct = (int)Convert.ToDouble(fh["utilization"]);
                if (fh != null && fh.ContainsKey("resets_at"))
                    sessReset = FmtReset(fh["resets_at"]?.ToString());
            }
            if (data.ContainsKey("seven_day")) {
                var sd = data["seven_day"] as Dictionary<string, object>;
                if (sd != null && sd.ContainsKey("utilization"))
                    weekPct = (int)Convert.ToDouble(sd["utilization"]);
                if (sd != null && sd.ContainsKey("resets_at"))
                    weekReset = FmtDay(sd["resets_at"]?.ToString());
            }
        } catch {}
    }

    string FmtReset(string iso) {
        if (string.IsNullOrEmpty(iso)) return "";
        try {
            var dt = DateTimeOffset.Parse(iso);
            var rem = (dt - DateTimeOffset.Now).TotalSeconds;
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
            var prev = prevStates.ContainsKey(s.Id) ? prevStates[s.Id] : "";
            if (notifyWaiting && prev == "active" && s.State == "waiting")
                tray.ShowBalloonTip(5000, s.Project, "Ready for your input", ToolTipIcon.Info);
            if (notifyContext && s.CtxPct >= 80 && !ctxWarned.Contains(s.Id)) {
                ctxWarned.Add(s.Id);
                tray.ShowBalloonTip(5000, s.Project + " — Context " + s.CtxPct + "%", "Consider running /compact", ToolTipIcon.Warning);
            }
            prevStates[s.Id] = s.State;
        }
    }

    // ── Build Menu ────────────────────────────────────────
    void Refresh() {
        var sessions = ScanSessions();
        ReadUsage();
        CheckNotifications(sessions);
        UpdateIcon(sessions);
    }

    void UpdateIcon(List<Session> sessions) {
        var hasCtxWarn = sessions.Any(s => s.CtxPct >= 80);
        var hasWaiting = sessions.Any(s => s.State == "waiting");
        var hasActive = sessions.Any(s => s.State == "active");

        tray.Icon = hasCtxWarn ? MakeDiamond(Color.FromArgb(210, 56, 46))
            : hasWaiting ? MakeDiamond(Color.FromArgb(242, 191, 51))
            : hasActive ? MakeDiamond(Color.FromArgb(77, 217, 115))
            : MakeDiamond(Color.FromArgb(100, 100, 140));

        var n = sessions.Count;
        var w = sessions.Count(s => s.State == "waiting");
        var tip = n == 0 ? "Claude Monitor" : n + " session" + (n != 1 ? "s" : "") + (w > 0 ? " (" + w + " waiting)" : "");
        tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
    }

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
            var groups = sessions.GroupBy(s => s.Dir).OrderBy(g => g.Key);
            foreach (var group in groups) {
                var first = group.First();

                // Project header
                var header = menu.Items.Add(first.Project + (string.IsNullOrEmpty(first.Branch) ? "" : "  " + first.Branch));
                header.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
                header.ForeColor = Color.White;
                header.Enabled = false;

                if (group.Count() > 1) {
                    var warn = menu.Items.Add("  ⚠ " + group.Count() + " sessions on same branch");
                    warn.ForeColor = Color.FromArgb(255, 190, 70);
                    warn.Font = new Font("Segoe UI", 9f);
                    warn.Enabled = false;
                }

                menu.Items.Add(new ToolStripSeparator());

                foreach (var s in group) {
                    var dot = s.State == "active" ? "● " : s.State == "waiting" ? "● " : "○ ";
                    var name = string.IsNullOrEmpty(s.State) ? "Session" : s.State == "waiting" ? "Waiting for input" : "Working...";
                    var label = "  " + dot + name + "  " + s.Duration;
                    if (s.CtxPct > 0) label += "  ctx " + s.CtxPct + "%";

                    var item = menu.Items.Add(label);
                    item.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
                    item.ForeColor = s.State == "active" ? Color.FromArgb(100, 220, 140)
                        : s.State == "waiting" ? Color.FromArgb(240, 190, 60)
                        : Color.FromArgb(140, 140, 140);
                }

                menu.Items.Add(new ToolStripSeparator());
            }
        }

        // Usage
        if (sessPct > 0 || weekPct > 0) {
            AddBar(menu, "Session", sessPct, sessReset);
            AddBar(menu, "Weekly ", weekPct, weekReset);
            menu.Items.Add(new ToolStripSeparator());
        }

        // Actions
        var refresh = menu.Items.Add("Refresh");
        refresh.ForeColor = Color.White;
        refresh.Click += (s, e) => Refresh();

        var settings = new ToolStripMenuItem("Settings") { ForeColor = Color.White };
        var nw = new ToolStripMenuItem("Waiting Alerts") { Checked = notifyWaiting, ForeColor = Color.White };
        nw.Click += (s, e) => { notifyWaiting = !notifyWaiting; nw.Checked = notifyWaiting; };
        settings.DropDownItems.Add(nw);
        var nc = new ToolStripMenuItem("Context Warnings") { Checked = notifyContext, ForeColor = Color.White };
        nc.Click += (s, e) => { notifyContext = !notifyContext; nc.Checked = notifyContext; };
        settings.DropDownItems.Add(nc);
        menu.Items.Add(settings);

        var quit = menu.Items.Add("Quit");
        quit.ForeColor = Color.White;
        quit.Click += (s, e) => { tray.Visible = false; Application.Exit(); };

        tray.ContextMenuStrip = menu;
        // Show it immediately
        var mi = typeof(NotifyIcon).GetMethod("ShowContextMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        if (mi != null) mi.Invoke(tray, null);
    }

    void AddLabel(ContextMenuStrip menu, string text, Color color) {
        var item = menu.Items.Add(text);
        item.Enabled = false;
        item.ForeColor = color;
        item.Font = new Font("Segoe UI", 9.5f);
    }

    void AddBar(ContextMenuStrip menu, string label, int pct, string reset) {
        var filled = Math.Min(pct * 16 / 100, 16);
        var bar = new string('█', filled) + new string('░', 16 - filled);
        var color = pct >= 80 ? Color.FromArgb(210, 70, 60)
            : pct >= 50 ? Color.FromArgb(200, 160, 40)
            : Color.FromArgb(80, 180, 110);
        var text = "  " + label + "  " + bar + "  " + pct + "%";
        if (!string.IsNullOrEmpty(reset)) text += "  ↻ " + reset;
        var item = menu.Items.Add(text);
        item.Enabled = false;
        item.Font = new Font("Cascadia Mono,Consolas", 9f);
        item.ForeColor = color;
    }

    // Dark theme renderer
    class DarkRenderer : ToolStripProfessionalRenderer {
        public DarkRenderer() : base(new DarkColors()) {}
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            if (e.Item is ToolStripSeparator) return;
            base.OnRenderItemText(e);
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
}
