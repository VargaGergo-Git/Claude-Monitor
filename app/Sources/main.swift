import AppKit
import Foundation

struct Session {
    var pid, project, branch, dir, duration, tty, lastCommit, context, name, sid: String
    var modifiedFiles: Int
    var state: String
    var contextPct: Int
    var smartContext: String
    var agentCount: Int
    var agentDescs: [String]
    var weeklyAtStart: Int
    var memoryCount: Int        // number of memory files for this project
    var handoffSnippet: String  // first line of handoff.md
}

// MARK: - Velocity Tracker

class VelocityTracker {
    private let path: String
    private var readings: [(ts: TimeInterval, pct: Int)] = []
    init(home: String) { path = "\(home)/.claude/.usage_velocity.json"; load() }

    func record(pct: Int) {
        let now = Date().timeIntervalSince1970
        if let last = readings.last, last.pct == pct && (now - last.ts) < 60 { return }
        readings.append((now, pct))
        if readings.count > 200 { readings = Array(readings.suffix(200)) }
        save()
    }

    func etaMinutes(current: Int, target: Int) -> Int? {
        guard current < target else { return nil }
        let now = Date().timeIntervalSince1970
        let recent = readings.filter { now - $0.ts < 7200 && now - $0.ts > 60 }
        guard recent.count >= 2, let oldest = recent.first else { return nil }
        let gained = current - oldest.pct
        guard gained > 0 else { return nil }
        return Int(Double(target - current) / (Double(gained) / (now - oldest.ts)) / 60)
    }

    func velocityPerHour(current: Int) -> Double? {
        let now = Date().timeIntervalSince1970
        let recent = readings.filter { now - $0.ts < 3600 && now - $0.ts > 60 }
        guard recent.count >= 2, let oldest = recent.first, (now - oldest.ts) > 120 else { return nil }
        return Double(current - oldest.pct) / ((now - oldest.ts) / 3600.0)
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        readings = arr.compactMap { guard let t = $0["t"] as? Double, let p = $0["p"] as? Int else { return nil }; return (t, p) }
    }
    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: readings.map { ["t": $0.ts, "p": $0.pct] }) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Monitor

class Monitor: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var sessions: [Session] = []
    private let home = NSHomeDirectory()
    private var nameCache: [String: String] = [:]
    private var pendingNames = Set<String>()
    private var smartCtxCache: [String: String] = [:]
    private var lastCtxHash: [String: String] = [:]
    private var pendingCtx = Set<String>()
    private var prevStates: [String: String] = [:]
    private var ctxWarned = Set<String>()
    private var sessionStartUsage: [String: Int] = [:]
    private var velocityTracker: VelocityTracker!

    // Usage
    private var sessPct = 0, weekPct = 0, opusPct = 0, sonnetPct = 0
    private var sessResetStr = "", weekResetStr = ""
    private var weekResetDate: Date?

    // Settings
    private let ud = UserDefaults.standard
    private var notifyWaiting: Bool { get { ud.object(forKey: "notifyWaiting") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyWaiting") } }
    private var notifyContext: Bool { get { ud.object(forKey: "notifyContext") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyContext") } }
    private var notifySound: Bool { get { ud.object(forKey: "notifySound") as? Bool ?? true } set { ud.set(newValue, forKey: "notifySound") } }
    private var enableHaiku: Bool { get { ud.object(forKey: "enableHaiku") as? Bool ?? true } set { ud.set(newValue, forKey: "enableHaiku") } }
    private var renameTerminals: Bool { get { ud.object(forKey: "renameTerminals") as? Bool ?? true } set { ud.set(newValue, forKey: "renameTerminals") } }

    // Palette
    let C = (
        teal:    NSColor(red: 0.31, green: 0.78, blue: 0.72, alpha: 1),
        amber:   NSColor(red: 0.92, green: 0.68, blue: 0.18, alpha: 1),
        green:   NSColor(red: 0.35, green: 0.82, blue: 0.52, alpha: 1),
        coral:   NSColor(red: 0.92, green: 0.32, blue: 0.28, alpha: 1),
        active:  NSColor(red: 0.35, green: 0.88, blue: 0.52, alpha: 1),
        waiting: NSColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1),
        purple:  NSColor(red: 0.55, green: 0.5, blue: 0.85, alpha: 1),
        section: NSColor(red: 0.42, green: 0.52, blue: 0.72, alpha: 1),
        w90:     NSColor(white: 0.90, alpha: 1),
        w70:     NSColor(white: 0.70, alpha: 1),
        w55:     NSColor(white: 0.55, alpha: 1),
        w42:     NSColor(white: 0.42, alpha: 1),
        w30:     NSColor(white: 0.30, alpha: 1),
        w20:     NSColor(white: 0.20, alpha: 1)
    )

    private var haikuCallCount: Int { get { ud.integer(forKey: "haikuCalls") } set { ud.set(newValue, forKey: "haikuCalls") } }
    private var haikuTokensUsed: Int { get { ud.integer(forKey: "haikuTokens") } set { ud.set(newValue, forKey: "haikuTokens") } }
    private var cachedToken: String?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        try? FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        cleanupStaleFiles(); loadNameCache()
        velocityTracker = VelocityTracker(home: home)
        NSUserNotificationCenter.default.delegate = self
        scan(); build()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.build() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(); self?.build() }
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in guard self?.enableHaiku == true else { return }; self?.resolveSmartContexts() }
    }

    // MARK: - Terminal Renaming

    private func renameTerminalTabs() {
        guard renameTerminals else { return }
        var checks = ""
        for s in sessions where !s.name.isEmpty && !s.tty.isEmpty {
            let t = s.name.replacingOccurrences(of: "\"", with: "'")
            checks += "if ttyPath is \"/dev/\(s.tty)\" then\nset custom title of t to \"\(t)\"\nset title displays custom title of t to true\nset title displays shell path of t to false\nset title displays window size of t to false\nset title displays device name of t to false\nset title displays file name of t to false\nset title displays settings name of t to false\nend if\n"
        }
        guard !checks.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Terminal\"\nrepeat with w in windows\nrepeat with t in tabs of w\nset ttyPath to tty of t\n\(checks)end repeat\nend repeat\nend tell"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        }
    }

    // MARK: - Actions

    private func jumpToSession(_ tty: String) {
        guard !tty.isEmpty else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\"\nactivate\nrepeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/\(tty)\" then\nset selected tab of w to t\nset index of w to 1\nreturn\nend if\nend repeat\nend repeat\nend tell"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    private func compactAllWaiting() {
        let w = sessions.filter { $0.state == "waiting" && !$0.tty.isEmpty }
        guard !w.isEmpty else { return }
        for s in w { typeInTerminal(tty: s.tty, text: "/compact") }
        sendNotification(title: "Claude Monitor", body: "Sent /compact to \(w.count) session\(w.count != 1 ? "s" : "")")
    }

    private func exportSummary() {
        var lines = ["## Claude Sessions \u{2014} \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"]
        for s in sessions {
            let name = s.name.isEmpty ? "Session" : s.name; let icon = s.state == "active" ? "\u{1F7E2}" : s.state == "waiting" ? "\u{1F7E1}" : "\u{26AA}"
            lines.append("\(icon) **\(name)** (\(s.project)/\(s.branch)) \u{2014} \(s.duration)")
            lines.append("   Context: \(s.contextPct)% | Weekly cost: ~\(weekPct - s.weeklyAtStart)%")
            if !s.smartContext.isEmpty { lines.append("   Doing: \(s.smartContext)") }
            if s.memoryCount > 0 { lines.append("   Memory: \(s.memoryCount) files") }
            lines.append("")
        }
        lines.append("Session: \(sessPct)% | Weekly: \(weekPct)% (Opus \(opusPct)%, Sonnet \(sonnetPct)%)")
        if let b = dailyBudget() { lines.append("Budget: \(b)") }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        sendNotification(title: "Claude Monitor", body: "Summary copied to clipboard")
    }

    // MARK: - Usage Reading

    private func readUsage() {
        guard let data = FileManager.default.contents(atPath: "\(home)/.claude/.usage_cache.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let fh = json["five_hour"] as? [String: Any] {
            sessPct = Int(fh["utilization"] as? Double ?? 0); sessResetStr = fmtReset(fh["resets_at"] as? String) ?? "" }
        if let sd = json["seven_day"] as? [String: Any] {
            weekPct = Int(sd["utilization"] as? Double ?? 0); weekResetStr = fmtDay(sd["resets_at"] as? String) ?? ""
            if let ra = sd["resets_at"] as? String { weekResetDate = iso(ra) } }
        opusPct = Int((json["seven_day_opus"] as? [String: Any])?["utilization"] as? Double ?? 0)
        sonnetPct = Int((json["seven_day_sonnet"] as? [String: Any])?["utilization"] as? Double ?? 0)
        velocityTracker.record(pct: weekPct)
    }

    private func dailyBudget() -> String? {
        guard let reset = weekResetDate else { return nil }
        let days = max(1, reset.timeIntervalSinceNow / 86400)
        let rem = Double(max(0, 100 - weekPct))
        return String(format: "%.0f%%/day for %.0f days", rem / days, days)
    }

    // MARK: - Memory & Handoff

    private func memoryCount(for dir: String) -> Int {
        let projHash = dir.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        let memDir = "\(home)/.claude/projects/\(projHash)/memory"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: memDir) else { return 0 }
        return files.filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" }.count
    }

    private func handoffSnippet(for dir: String) -> String {
        let path = "\(dir)/.claude/handoff.md"
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        // Get first non-header, non-empty line
        for line in data.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix(">") || l.hasPrefix("-") && l.count < 5 { continue }
            let clean = l.hasPrefix("- ") ? String(l.dropFirst(2)) : l
            return clean.count > 55 ? String(clean.prefix(52)) + "..." : clean
        }
        return ""
    }

    // MARK: - Agent Activity

    private func readAgentActivity() -> (count: Int, descs: [String]) {
        var count = 0
        if let s = try? String(contentsOfFile: "\(home)/.claude/.active_agents", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let c = Int(s) { count = max(0, c) }
        var descs: [String] = []
        if let data = try? String(contentsOfFile: "\(home)/.claude/.agent_activity", encoding: .utf8) {
            let now = Date().timeIntervalSince1970
            for line in data.split(separator: "\n").suffix(10) {
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let ts = Double(parts[0]), now - ts < 300 else { continue }
                descs.append(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (count, descs)
    }

    // MARK: - Notifications

    private func cleanupStaleFiles() {
        let fm = FileManager.default; let cd = "\(home)/.claude"
        let px = [".ctx_", ".state_", ".ctxlog_", ".tty_map_", ".tty_resolved_", ".name_tried_", ".activity_", ".files_", ".ctx_pct_"]
        let cutoff = Date().addingTimeInterval(-86400)
        guard let files = try? fm.contentsOfDirectory(atPath: cd) else { return }
        for f in files where px.contains(where: { f.hasPrefix($0) }) {
            if let a = try? fm.attributesOfItem(atPath: "\(cd)/\(f)"), let m = a[.modificationDate] as? Date, m < cutoff { try? fm.removeItem(atPath: "\(cd)/\(f)") } }
    }

    private func checkNotifications() {
        for s in sessions where !s.sid.isEmpty {
            let prev = prevStates[s.sid] ?? ""
            if notifyWaiting && prev == "active" && s.state == "waiting" {
                sendNotification(title: s.name.isEmpty ? s.project : s.name, body: "Ready for input \u{2014} click to jump", sound: notifySound ? "Tink" : nil, tty: s.tty) }
            if notifyContext && s.contextPct >= 80 && !ctxWarned.contains(s.sid) {
                ctxWarned.insert(s.sid)
                sendNotification(title: "\(s.name.isEmpty ? s.project : s.name) \u{2014} ctx \(s.contextPct)%", body: "Consider /compact", sound: notifySound ? "Submarine" : nil, tty: s.tty) }
            prevStates[s.sid] = s.state
        }
    }

    private func sendNotification(title: String, body: String, sound: String? = "Tink", tty: String = "") {
        let n = NSUserNotification(); n.title = title; n.informativeText = body
        if let sn = sound { n.soundName = sn }; n.userInfo = ["tty": tty]
        NSUserNotificationCenter.default.deliver(n)
    }
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if let tty = notification.userInfo?["tty"] as? String, !tty.isEmpty { jumpToSession(tty) } }
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool { true }

    // MARK: - Name Cache + Haiku

    private func loadNameCache() {
        guard let data = try? String(contentsOfFile: "\(home)/.claude/.session_names", encoding: .utf8) else { return }
        for line in data.split(separator: "\n") { let p = line.split(separator: "|", maxSplits: 1); guard p.count == 2 else { continue }; nameCache[String(p[0])] = String(p[1]) }
    }
    private func saveNameToCache(_ sid: String, _ name: String) {
        nameCache[sid] = name; let path = "\(home)/.claude/.session_names"; let line = "\(sid)|\(name)\n"
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8) ?? Data()); fh.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    private func resolveNames() {
        guard enableHaiku else { return }
        for s in sessions where s.name.isEmpty && !s.sid.isEmpty {
            let sid = s.sid; guard !pendingNames.contains(sid) else { continue }; pendingNames.insert(sid)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let ph = s.dir.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                guard let data = try? String(contentsOfFile: "\(self.home)/.claude/projects/\(ph)/\(sid).jsonl", encoding: .utf8) else { self.pendingNames.remove(sid); return }
                var rawMsg = ""
                for line in data.split(separator: "\n").prefix(200) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], obj["type"] as? String == "user",
                          let msg = obj["message"] as? [String: Any], let content = msg["content"] as? String,
                          !content.hasPrefix("<"), content.count > 5 else { continue }
                    rawMsg = String(content.prefix(200)); break
                }
                guard !rawMsg.isEmpty else { self.pendingNames.remove(sid); return }
                self.callHaiku(prompt: "What is the goal or theme of this coding session? Summarize in 2-5 words (e.g. 'Sleep Lab Redesign', 'Fix Auth Bug', 'Sync Pipeline Hardening'). Reply ONLY the theme. User's request: \(rawMsg)", maxTokens: 15) { result in
                    let name = result ?? String(rawMsg.split(separator: "\n").first?.prefix(35) ?? "Unknown")
                    DispatchQueue.main.async { self.saveNameToCache(sid, name); self.pendingNames.remove(sid); self.build() }
                }
            }
        }
    }

    private func resolveSmartContexts() {
        for s in sessions where !s.sid.isEmpty {
            guard !pendingCtx.contains(s.sid) else { continue }
            let logPath = "\(home)/.claude/.ctxlog_\(s.sid)"
            guard let logData = try? String(contentsOfFile: logPath, encoding: .utf8), !logData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let hash = String(logData.hashValue)
            if lastCtxHash[s.sid] == hash { continue }
            lastCtxHash[s.sid] = hash; pendingCtx.insert(s.sid)
            let actions = logData.split(separator: "\n").suffix(6).joined(separator: ", ")
            var diffStat = ""
            if let dir = sessions.first(where: { $0.sid == s.sid })?.dir {
                let pipe = Pipe(); let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                proc.arguments = ["-C", dir, "diff", "--stat", "HEAD"]; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
                try? proc.run(); proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let last = out.split(separator: "\n").last { diffStat = ", Git changes: \(last)" }
            }
            let sid = s.sid
            callHaiku(prompt: "What is this coding session doing RIGHT NOW? Recent actions: \(actions)\(diffStat). Reply in 5-10 words, present tense, specific. No quotes.", maxTokens: 25) { [weak self] result in
                guard let self else { return }
                if let summary = result { DispatchQueue.main.async { self.smartCtxCache[sid] = summary; self.pendingCtx.remove(sid); self.build() } }
                else { self.pendingCtx.remove(sid) }
            }
        }
    }

    private func callHaiku(prompt: String, maxTokens: Int, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { completion(nil); return }
            let token: String
            if let c = self.cachedToken { token = c } else if let t = self.getOAuthToken() { self.cachedToken = t; token = t } else { completion(nil); return }
            let body: [String: Any] = ["model": "claude-haiku-4-5-20251001", "max_tokens": maxTokens, "messages": [["role": "user", "content": prompt]]]
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta"); req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body); req.timeoutInterval = 8
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                var result: String?
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]], let text = content.first?["text"] as? String {
                    result = text
                    if let usage = json["usage"] as? [String: Any] { DispatchQueue.main.async { self?.haikuCallCount += 1; self?.haikuTokensUsed += (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0) } }
                }
                completion(result)
            }.resume()
        }
    }

    private func getOAuthToken() -> String? {
        let pipe = Pipe(); let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }; proc.waitUntilExit()
        guard let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    // MARK: - Scan

    private func scan() {
        let script = """
        for bpid in $(ps -eo pid,tty,args 2>/dev/null | awk '$2 == "??" && /--resume/' | awk '{print $1}'); do
            sid=$(ps -p "$bpid" -o args= 2>/dev/null | sed -n 's/.*--resume \\([^ ]*\\).*/\\1/p')
            [ -z "$sid" ] && continue
            current=$bpid
            for i in $(seq 1 15); do
                parent=$(ps -p "$current" -o ppid= 2>/dev/null | tr -d ' ')
                [ -z "$parent" ] || [ "$parent" = "1" ] && break
                ptty=$(ps -p "$parent" -o tty= 2>/dev/null | tr -d ' ')
                if [ "$ptty" != "??" ] && [ -n "$ptty" ]; then
                    [ ! -f "$HOME/.claude/.tty_map_$ptty" ] && echo "$sid" > "$HOME/.claude/.tty_map_$ptty"
                    break
                fi
                current=$parent
            done
        done
        for pid in $(ps -eo pid,tty,comm 2>/dev/null | awk '$3 == "claude" && $2 != "??" {print $1}'); do
            dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2)}')
            [ -z "$dir" ] && continue
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "")
            etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
            tty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
            modified=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            lastcommit=$(git -C "$dir" log -1 --format='%s' 2>/dev/null | head -1 | cut -c1-50)
            sid=""
            [ -f "$HOME/.claude/.tty_map_$tty" ] && sid=$(cat "$HOME/.claude/.tty_map_$tty" 2>/dev/null)
            ctx=""
            [ -n "$sid" ] && [ -f "$HOME/.claude/.ctx_$sid" ] && ctx=$(cat "$HOME/.claude/.ctx_$sid" 2>/dev/null | head -1 | cut -c1-40)
            state=""
            [ -n "$sid" ] && [ -f "$HOME/.claude/.state_$sid" ] && state=$(cat "$HOME/.claude/.state_$sid" 2>/dev/null | head -1)
            ctxpct=""
            [ -n "$sid" ] && [ -f "$HOME/.claude/.ctx_pct_$sid" ] && ctxpct=$(cat "$HOME/.claude/.ctx_pct_$sid" 2>/dev/null | head -1)
            echo "$pid|$dir|$branch|$etime|$tty|$modified|$lastcommit|$ctx|$sid|$state|$ctxpct"
        done
        """
        let pipe = Pipe(); let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }; proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        readUsage()
        let ai = readAgentActivity()
        var result: [Session] = []
        for line in output.split(separator: "\n") where !line.isEmpty {
            let p = line.split(separator: "|", maxSplits: 10, omittingEmptySubsequences: false)
            guard p.count >= 5 else { continue }
            let sid = p.count > 8 ? String(p[8]) : ""
            let dir = String(p[1])
            if !sid.isEmpty && sessionStartUsage[sid] == nil { sessionStartUsage[sid] = weekPct }
            result.append(Session(pid: String(p[0]).trimmingCharacters(in: .whitespaces),
                project: (dir as NSString).lastPathComponent, branch: p.count > 2 ? String(p[2]) : "",
                dir: dir, duration: p.count > 3 ? fmtElapsed(String(p[3])) : "", tty: String(p[4]),
                lastCommit: p.count > 6 ? String(p[6]) : "", context: p.count > 7 ? String(p[7]) : "",
                name: nameCache[sid] ?? "", sid: sid,
                modifiedFiles: p.count > 5 ? Int(String(p[5]).trimmingCharacters(in: .whitespaces)) ?? 0 : 0,
                state: p.count > 9 ? String(p[9]) : "",
                contextPct: p.count > 10 ? Int(String(p[10]).trimmingCharacters(in: .whitespaces).split(separator: ".").first ?? "") ?? 0 : 0,
                smartContext: smartCtxCache[sid] ?? "",
                agentCount: ai.count, agentDescs: ai.descs,
                weeklyAtStart: sessionStartUsage[sid] ?? weekPct,
                memoryCount: memoryCount(for: dir), handoffSnippet: handoffSnippet(for: dir)))
        }
        sessions = result; resolveNames(); checkNotifications(); renameTerminalTabs()
    }

    private func fmtElapsed(_ s: String) -> String {
        let c = s.trimmingCharacters(in: .whitespaces); guard !c.isEmpty else { return "" }
        var total = 0; let dp = c.split(separator: "-", maxSplits: 1); var tp = c
        if dp.count == 2 { total += (Int(dp[0]) ?? 0) * 86400; tp = String(dp[1]) }
        let n = tp.split(separator: ":").compactMap { Int($0) }
        switch n.count { case 3: total += n[0]*3600 + n[1]*60 + n[2]; case 2: total += n[0]*60 + n[1]; case 1: total += n[0]; default: break }
        if total < 60 { return "\(total)s" }; if total < 3600 { return "\(total/60)m" }
        let h = total/3600; let m = (total%3600)/60; return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }

    private func typeInTerminal(tty: String, text: String) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\"\nactivate\nrepeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/\(tty)\" then\nset selected tab of w to t\nset index of w to 1\nend if\nend repeat\nend repeat\nend tell\ndelay 0.3\ntell application \"System Events\"\ntell process \"Terminal\"\nkeystroke \"\(escaped)\"\nkeystroke return\nend tell\nend tell"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    // ================================================================
    // MARK: - BUILD MENU
    // ================================================================

    private func build() {
        readUsage()
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        let n = sessions.count; let wc = sessions.filter { $0.state == "waiting" }.count
        let ac = sessions.filter { $0.state == "active" }.count
        let ts = (sessions.first { $0.state == "active" } ?? sessions.first)?.duration ?? ""

        // ── Status bar button ──
        if let b = statusItem.button {
            let s = NSMutableAttributedString()
            if n == 0 {
                s.append(a(" \u{25C6} ", sz: 13, wt: .bold, cl: .tertiaryLabelColor))
            } else {
                let diamondC: NSColor = ac > 0 ? C.active : wc > 0 ? C.waiting : C.w55
                s.append(a(" \u{25C6}", sz: 13, wt: .bold, cl: diamondC))
                s.append(a(" \(n)", sz: 12, wt: .bold, cl: .labelColor))
                if wc > 0 { s.append(a(" \u{23F3}\(wc)", sz: 10, wt: .medium, cl: C.waiting)) }
                if !ts.isEmpty { s.append(a(" \(ts)", sz: 10, wt: .medium, cl: C.w55)) }
            }
            // Always show weekly %
            if weekPct > 0 {
                let wkC = weekPct >= 80 ? C.coral : weekPct >= 60 ? C.amber : C.w55
                s.append(a(" \(weekPct)%", sz: 10, wt: .bold, cl: wkC))
            }
            s.append(a(" ", sz: 8, wt: .regular, cl: .clear))
            b.attributedTitle = s
        }

        // ── Empty state ──
        guard !sessions.isEmpty else {
            sec("\u{25C7}  CLAUDE MONITOR", menu)
            txt("    No active sessions", C.w42, 12, menu)
            menu.addItem(NSMenuItem.separator())
            usageSection(menu)
            footer(menu); statusItem.menu = menu; return
        }

        // ── SESSIONS ──
        sec("\u{25C6}  SESSIONS", menu)

        let byDir = Dictionary(grouping: sessions, by: \.dir)
        for (_, group) in byDir.sorted(by: { $0.key < $1.key }) {
            let f = group[0]

            // Project header
            let h = NSMutableAttributedString()
            h.append(a("  \(f.project)", sz: 14, wt: .heavy, cl: C.w90))
            if !f.branch.isEmpty { h.append(a("  \(f.branch)", sz: 10, wt: .bold, cl: C.teal, mono: true)) }
            item(h, menu)

            // Git line
            let r2 = NSMutableAttributedString()
            if f.modifiedFiles > 0 { r2.append(a("    \(f.modifiedFiles) files changed", sz: 10, wt: .medium, cl: C.w42)) }
            if !f.lastCommit.isEmpty {
                if r2.length > 0 { r2.append(a("  \u{00B7}  ", sz: 9, wt: .regular, cl: C.w20)) }
                else { r2.append(a("    ", sz: 10, wt: .regular, cl: .clear)) }
                r2.append(a(f.lastCommit, sz: 10, wt: .medium, cl: C.w30))
            }
            if r2.length > 0 { item(r2, menu) }

            // Memory + handoff
            if f.memoryCount > 0 || !f.handoffSnippet.isEmpty {
                let mx = NSMutableAttributedString()
                mx.append(a("    ", sz: 10, wt: .regular, cl: .clear))
                if f.memoryCount > 0 { mx.append(a("\u{1F9E0} \(f.memoryCount) memories", sz: 9, wt: .medium, cl: C.purple)) }
                if !f.handoffSnippet.isEmpty {
                    if f.memoryCount > 0 { mx.append(a("  \u{00B7}  ", sz: 9, wt: .regular, cl: C.w20)) }
                    mx.append(a("\u{1F4CB} \(f.handoffSnippet)", sz: 9, wt: .medium, cl: C.w30))
                }
                item(mx, menu)
            }

            // Branch conflict
            if group.count > 1 {
                txt("    \u{26A0} \(group.count) sessions on same branch", C.amber, 11, menu)
                let si = NSMenuItem(title: "", action: #selector(splitBranches(_:)), keyEquivalent: "")
                si.target = self; si.attributedTitle = a("    \u{2192} Split into branches", sz: 10, wt: .medium, cl: C.teal)
                si.representedObject = group.map { ["name": $0.name.isEmpty ? $0.tty : $0.name, "dir": $0.dir, "branch": $0.branch, "tty": $0.tty] }
                menu.addItem(si)
            }

            menu.addItem(NSMenuItem.separator())

            // Session rows
            for s in group { sessionRow(s, menu) }
        }

        menu.addItem(NSMenuItem.separator())

        // ── USAGE ──
        usageSection(menu)

        // ── FOOTER ──
        footer(menu)
        statusItem.menu = menu
    }

    // MARK: - Session Row

    private func sessionRow(_ s: Session, _ menu: NSMenu) {
        let dn = s.name.isEmpty ? (pendingNames.contains(s.sid) ? "Naming..." : "Session") : s.name

        // Line 1: dot + name + agents + duration + ctx% + cost
        let r = NSMutableAttributedString()
        let dotC: NSColor = s.state == "active" ? C.active : s.state == "waiting" ? C.waiting : C.w30
        r.append(a("  \u{25CF} ", sz: 11, wt: .bold, cl: dotC))
        r.append(a(dn, sz: 13, wt: .bold, cl: C.w90))

        if s.agentCount > 0 {
            r.append(a("  ", sz: 9, wt: .regular, cl: .clear))
            r.append(a("+\(s.agentCount) agents", sz: 9, wt: .bold, cl: C.section))
        }

        r.append(a("  ", sz: 10, wt: .regular, cl: .clear))
        r.append(a(s.duration, sz: 10, wt: .semibold, cl: C.w42, mono: true))

        if s.contextPct > 0 {
            let cc = s.contextPct >= 80 ? C.coral : s.contextPct >= 60 ? C.amber : C.w42
            r.append(a("  ctx \(s.contextPct)%", sz: 9, wt: .bold, cl: cc, mono: true))
        }

        let cost = weekPct - s.weeklyAtStart
        if cost > 0 { r.append(a("  ~\(cost)%w", sz: 9, wt: .medium, cl: C.w30, mono: true)) }

        // Line 2: smart context
        let ctx = !s.smartContext.isEmpty ? s.smartContext : !s.context.isEmpty ? s.context : s.state == "waiting" ? "Waiting for your input" : "Working..."
        let ctxC: NSColor = !s.smartContext.isEmpty ? NSColor(red: 0.55, green: 0.6, blue: 0.85, alpha: 1) : C.w42
        r.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 2)]))
        r.append(a("      \(ctx)", sz: 11, wt: .medium, cl: ctxC))

        // Line 3: agent descriptions (if any)
        if !s.agentDescs.isEmpty {
            let agLine = s.agentDescs.prefix(3).joined(separator: " \u{00B7} ")
            r.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1)]))
            r.append(a("      \u{2937} \(agLine.count > 60 ? String(agLine.prefix(57)) + "..." : agLine)", sz: 9, wt: .medium, cl: C.section))
        }

        let mi = NSMenuItem(title: "", action: #selector(openTerm(_:)), keyEquivalent: "")
        mi.target = self; mi.representedObject = s.tty; mi.attributedTitle = r; mi.isEnabled = true; menu.addItem(mi)

        // Send command
        if s.state == "waiting" || s.state.isEmpty {
            let wrap = NSMenuItem(title: "", action: #selector(wrapUpSession(_:)), keyEquivalent: "")
            wrap.target = self; wrap.representedObject = ["tty": s.tty, "name": dn]
            wrap.attributedTitle = a("      \u{23FB} Send command...", sz: 10, wt: .medium, cl: C.w30)
            menu.addItem(wrap)
        }
    }

    // MARK: - Usage Section

    private func usageSection(_ menu: NSMenu) {
        sec("\u{2261}  USAGE", menu)

        // Bars
        usageBar("Session", sessPct, sessResetStr, menu)
        usageBar("Weekly ", weekPct, weekResetStr, menu)

        // Model breakdown
        if opusPct > 0 || sonnetPct > 0 {
            let r = NSMutableAttributedString(); r.append(a("    ", sz: 9, wt: .regular, cl: .clear))
            if opusPct > 0 {
                r.append(a("Opus ", sz: 9, wt: .semibold, cl: C.w42, mono: true))
                r.append(a("\(opusPct)%", sz: 9, wt: .bold, cl: opusPct >= 50 ? C.amber : C.green, mono: true))
            }
            if opusPct > 0 && sonnetPct > 0 { r.append(a("    ", sz: 9, wt: .regular, cl: .clear)) }
            if sonnetPct > 0 {
                r.append(a("Sonnet ", sz: 9, wt: .semibold, cl: C.w42, mono: true))
                r.append(a("\(sonnetPct)%", sz: 9, wt: .bold, cl: sonnetPct >= 50 ? C.amber : C.green, mono: true))
            }
            item(r, menu)
        }

        // Pace
        sec("\u{25B8}  PACE", menu)

        if let vel = velocityTracker.velocityPerHour(current: weekPct), vel > 0 {
            let r = NSMutableAttributedString()
            let vc = vel > 8 ? C.coral : vel > 4 ? C.amber : C.green
            r.append(a("    ", sz: 10, wt: .regular, cl: .clear))
            r.append(a(String(format: "%.1f%%/hr", vel), sz: 11, wt: .bold, cl: vc, mono: true))

            if let eta = velocityTracker.etaMinutes(current: weekPct, target: 80), weekPct < 80 {
                let ec: NSColor; let es: String
                if eta < 60 { ec = C.coral; es = "80% in <1h \u{26A0}" }
                else if eta < 120 { ec = C.amber; es = "80% in ~\(eta/60)h\(eta%60)m" }
                else { ec = C.green; es = "80% in ~\(eta/60)h\(eta%60)m" }
                r.append(a("  \u{2192}  \(es)", sz: 10, wt: .semibold, cl: ec, mono: true))
            } else if weekPct >= 80 {
                r.append(a("  \u{26A0} over 80%", sz: 10, wt: .bold, cl: C.coral, mono: true))
            }
            item(r, menu)
        } else {
            txt("    Collecting pace data...", C.w30, 10, menu)
        }

        if let b = dailyBudget() { txt("    Budget: \(b)", C.w42, 10, menu) }

        // Today
        if let ss = try? String(contentsOfFile: "\(home)/.claude/.weekly_start_pct", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let sp = Int(ss) {
            let d = weekPct - sp
            if d > 0 { txt("    Today: +\(d)% weekly", C.w42, 10, menu) }
        }

        menu.addItem(NSMenuItem.separator())
    }

    private func usageBar(_ label: String, _ pct: Int, _ reset: String, _ menu: NSMenu) {
        let bc = pct >= 80 ? C.coral : pct >= 50 ? C.amber : C.green
        let f = min(pct * 16 / 100, 16)
        let bar = String(repeating: "\u{2588}", count: f) + String(repeating: "\u{2591}", count: 16 - f)
        let r = NSMutableAttributedString()
        r.append(a("    \(label) ", sz: 10, wt: .semibold, cl: C.w42, mono: true))
        r.append(a(bar, sz: 10, wt: .regular, cl: bc, mono: true))
        r.append(a(" \(pct)%", sz: 10, wt: .bold, cl: bc, mono: true))
        if !reset.isEmpty { r.append(a("  \u{21BB} \(reset)", sz: 9, wt: .medium, cl: C.w30, mono: true)) }
        item(r, menu)
    }

    // MARK: - Footer

    private func footer(_ menu: NSMenu) {
        let wc = sessions.filter { $0.state == "waiting" }.count
        if wc > 0 {
            let ca = NSMenuItem(title: "", action: #selector(compactAllAction), keyEquivalent: "")
            ca.target = self; ca.attributedTitle = a("  /compact all (\(wc) waiting)", sz: 12, wt: .bold, cl: C.waiting)
            menu.addItem(ca)
        }
        if !sessions.isEmpty {
            let ex = NSMenuItem(title: "", action: #selector(exportAction), keyEquivalent: "e")
            ex.target = self; ex.attributedTitle = a("  Export summary", sz: 11, wt: .medium, cl: C.w42)
            menu.addItem(ex)
        }
        menu.addItem(NSMenuItem.separator())
        let r = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"); r.target = self; menu.addItem(r)
        let sm = NSMenu()
        tog(sm, "Waiting Alerts", notifyWaiting, #selector(toggleWaiting))
        tog(sm, "Context Warnings", notifyContext, #selector(toggleContext))
        tog(sm, "Notification Sounds", notifySound, #selector(toggleSound))
        tog(sm, "AI Names + Smart Context", enableHaiku, #selector(toggleHaiku))
        tog(sm, "Rename Terminal Tabs", renameTerminals, #selector(toggleRename))
        sm.addItem(NSMenuItem.separator())
        tog(sm, "Launch at Login", FileManager.default.fileExists(atPath: "\(home)/Library/LaunchAgents/com.claude.monitor.plist"), #selector(toggleAutoLaunch))
        let si = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""); si.submenu = sm; menu.addItem(si)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Helpers

    private func sec(_ title: String, _ menu: NSMenu) { item(a("  \(title)", sz: 9, wt: .heavy, cl: C.section), menu) }
    private func txt(_ s: String, _ cl: NSColor, _ sz: CGFloat, _ menu: NSMenu) { item(a(s, sz: sz, wt: .medium, cl: cl), menu) }
    private func tog(_ menu: NSMenu, _ label: String, _ on: Bool, _ sel: Selector) {
        let i = NSMenuItem(title: on ? "\u{2713} \(label)" : "   \(label)", action: sel, keyEquivalent: ""); i.target = self; menu.addItem(i) }
    private func a(_ s: String, sz: CGFloat, wt: NSFont.Weight, cl: NSColor, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: sz, weight: wt) : NSFont.systemFont(ofSize: sz, weight: wt), .foregroundColor: cl]) }
    private func item(_ attr: NSAttributedString, _ menu: NSMenu) {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: ""); i.attributedTitle = attr; i.isEnabled = false; menu.addItem(i) }
    private func fmtReset(_ s: String?) -> String? { guard let s, let d = iso(s) else { return nil }; let r = d.timeIntervalSinceNow; guard r > 0 else { return nil }; return "\(Int(r)/3600)h\((Int(r)%3600)/60)m" }
    private func fmtDay(_ s: String?) -> String? { guard let s, let d = iso(s) else { return nil }; let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d) }
    private func iso(_ s: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }() }

    // MARK: - Actions

    @objc private func compactAllAction() { compactAllWaiting() }
    @objc private func exportAction() { exportSummary() }
    @objc private func toggleWaiting() { notifyWaiting.toggle(); build() }
    @objc private func toggleContext() { notifyContext.toggle(); build() }
    @objc private func toggleSound() { notifySound.toggle(); build() }
    @objc private func toggleHaiku() { enableHaiku.toggle(); build() }
    @objc private func toggleRename() { renameTerminals.toggle(); build() }
    @objc private func refresh() { scan(); build() }

    @objc private func openTerm(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String, !tty.isEmpty else { return }; jumpToSession(tty) }

    @objc private func wrapUpSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let tty = info["tty"], !tty.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Send command to \"\(info["name"] ?? "session")\""
        alert.informativeText = "Type a command:"; alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.placeholderString = "/compact, /done, or custom"
        alert.accessoryView = field; NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty { typeInTerminal(tty: tty, text: field.stringValue) }
    }

    @objc private func splitBranches(_ sender: NSMenuItem) {
        guard let infos = sender.representedObject as? [[String: String]], infos.count > 1, let dir = infos.first?["dir"], let bb = infos.first?["branch"], !bb.isEmpty else { return }
        var cmds: [String] = []; var created: [String] = []
        for (i, info) in infos.enumerated() {
            if i == 0 { continue }
            let slug = String((info["name"] ?? "s\(i)").lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(30))
            let branch = "\(bb)-\(slug)"
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", dir, "branch", branch, bb]; proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit(); created.append(branch); cmds.append("git checkout \(branch)")
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmds.joined(separator: "\n"), forType: .string)
        sendNotification(title: "Branches Split", body: "Created \(created.count) branches. Commands copied.", sound: "Glass")
    }

    @objc private func toggleAutoLaunch() {
        let pp = "\(home)/Library/LaunchAgents/com.claude.monitor.plist"; let fm = FileManager.default
        if fm.fileExists(atPath: pp) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["unload", pp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            try? fm.removeItem(atPath: pp); sendNotification(title: "Claude Monitor", body: "Removed from Login Items")
        } else {
            try? fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            try? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>com.claude.monitor</string><key>ProgramArguments</key><array><string>/usr/bin/open</string><string>\(home)/.claude/ClaudeMonitor.app</string></array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>".write(toFile: pp, atomically: true, encoding: .utf8)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["load", pp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            sendNotification(title: "Claude Monitor", body: "Will launch at login", sound: "Glass")
        }
        build()
    }
}

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let d = Monitor(); app.delegate = d; app.run()
