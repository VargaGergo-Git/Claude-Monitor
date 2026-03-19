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
    var autoBranch: String
    var parentBranch: String
}

// MARK: - Velocity Tracker

class VelocityTracker {
    private let path: String
    private var readings: [(ts: TimeInterval, pct: Int)] = []
    init(home: String) { path = "\(home)/.claude/.usage_velocity.json"; load() }
    func record(pct: Int) {
        let now = Date().timeIntervalSince1970
        if let last = readings.last, last.pct == pct && (now - last.ts) < 60 { return }
        readings.append((now, pct)); if readings.count > 200 { readings = Array(readings.suffix(200)) }; save()
    }
    func etaMinutes(current: Int, target: Int) -> Int? {
        guard current < target else { return nil }; let now = Date().timeIntervalSince1970
        let recent = readings.filter { now - $0.ts < 7200 && now - $0.ts > 60 }
        guard recent.count >= 2, let o = recent.first else { return nil }
        let g = current - o.pct; guard g > 0 else { return nil }
        return Int(Double(target - current) / (Double(g) / (now - o.ts)) / 60)
    }
    func velocityPerHour(current: Int) -> Double? {
        let now = Date().timeIntervalSince1970
        let recent = readings.filter { now - $0.ts < 3600 && now - $0.ts > 60 }
        guard recent.count >= 2, let o = recent.first, (now - o.ts) > 120 else { return nil }
        return Double(current - o.pct) / ((now - o.ts) / 3600.0)
    }
    private func load() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        readings = a.compactMap { guard let t = $0["t"] as? Double, let p = $0["p"] as? Int else { return nil }; return (t, p) }
    }
    private func save() { guard let d = try? JSONSerialization.data(withJSONObject: readings.map { ["t": $0.ts, "p": $0.pct] }) else { return }; try? d.write(to: URL(fileURLWithPath: path)) }
}

// MARK: - Monitor

@available(macOS, deprecated: 11.0)
class Monitor: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {

    // MARK: - State

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
    private var sessPct = 0, weekPct = 0, opusPct = 0, sonnetPct = 0
    private var sessResetStr = "", weekResetStr = ""
    private var weekResetDate: Date?
    private var previousSids = Set<String>()

    private let ud = UserDefaults.standard
    private var notifyWaiting: Bool { get { ud.object(forKey: "notifyWaiting") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyWaiting") } }
    private var notifyContext: Bool { get { ud.object(forKey: "notifyContext") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyContext") } }
    private var notifySound: Bool { get { ud.object(forKey: "notifySound") as? Bool ?? true } set { ud.set(newValue, forKey: "notifySound") } }
    private var enableHaiku: Bool { get { ud.object(forKey: "enableHaiku") as? Bool ?? true } set { ud.set(newValue, forKey: "enableHaiku") } }
    private var renameTerminals: Bool { get { ud.object(forKey: "renameTerminals") as? Bool ?? true } set { ud.set(newValue, forKey: "renameTerminals") } }
    private var autoMergeBranches: Bool { get { ud.object(forKey: "autoMerge") as? Bool ?? true } set { ud.set(newValue, forKey: "autoMerge") } }

    let teal = NSColor(red: 0.31, green: 0.78, blue: 0.72, alpha: 1)
    let amber = NSColor(red: 0.92, green: 0.68, blue: 0.18, alpha: 1)
    let green = NSColor(red: 0.35, green: 0.82, blue: 0.52, alpha: 1)
    let coral = NSColor(red: 0.92, green: 0.32, blue: 0.28, alpha: 1)
    let active = NSColor(red: 0.35, green: 0.88, blue: 0.52, alpha: 1)
    let waiting = NSColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1)
    let purple = NSColor(red: 0.55, green: 0.58, blue: 0.88, alpha: 1)
    let w90 = NSColor(white: 0.90, alpha: 1)
    let w60 = NSColor(white: 0.60, alpha: 1)
    let w45 = NSColor(white: 0.45, alpha: 1)
    let w30 = NSColor(white: 0.30, alpha: 1)
    let w20 = NSColor(white: 0.20, alpha: 1)

    private var haikuCallCount: Int { get { ud.integer(forKey: "haikuCalls") } set { ud.set(newValue, forKey: "haikuCalls") } }
    private var haikuTokensUsed: Int { get { ud.integer(forKey: "haikuTokens") } set { ud.set(newValue, forKey: "haikuTokens") } }
    private var cachedToken: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        try? FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        cleanupStaleFiles(); loadNameCache()
        velocityTracker = VelocityTracker(home: home)
        NSUserNotificationCenter.default.delegate = self
        scan(); build()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pickupHookNotifications(); self?.build() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(); self?.build() }
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in guard self?.enableHaiku == true else { return }; self?.resolveSmartContexts() }
    }

    // MARK: - Terminal

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

    private func jumpToSession(_ tty: String) {
        guard !tty.isEmpty else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\"\nactivate\nrepeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/\(tty)\" then\nset selected tab of w to t\nset index of w to 1\nreturn\nend if\nend repeat\nend repeat\nend tell"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    private func typeInTerminal(tty: String, text: String) {
        let e = text.replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\"\nactivate\nrepeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/\(tty)\" then\nset selected tab of w to t\nset index of w to 1\nend if\nend repeat\nend repeat\nend tell\ndelay 0.3\ntell application \"System Events\"\ntell process \"Terminal\"\nkeystroke \"\(e)\"\nkeystroke return\nend tell\nend tell"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    // MARK: - Branch Management

    private func gitCmd(dir: String, _ args: String...) -> (ok: Bool, out: String) {
        let pipe = Pipe(); let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir] + args
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return (false, "") }
        proc.waitUntilExit()
        return (proc.terminationStatus == 0, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private func mergeSessionBranch(dir: String, autoBranch: String, parentBranch: String, sid: String, silent: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (_, status) = self.gitCmd(dir: dir, "status", "--porcelain")
            guard status.isEmpty else {
                if !silent { DispatchQueue.main.async { self.sendNotification(title: "Can't Merge", body: "Uncommitted changes \u{2014} commit first") } }
                return
            }
            let (_, cur) = self.gitCmd(dir: dir, "branch", "--show-current")
            if cur != parentBranch { let _ = self.gitCmd(dir: dir, "checkout", parentBranch) }
            let (merged, _) = self.gitCmd(dir: dir, "merge", autoBranch, "--no-edit")
            if merged {
                let _ = self.gitCmd(dir: dir, "branch", "-d", autoBranch)
                try? FileManager.default.removeItem(atPath: "\(self.home)/.claude/.auto_branch_\(sid)")
                try? FileManager.default.removeItem(atPath: "\(self.home)/.claude/.parent_branch_\(sid)")
                DispatchQueue.main.async {
                    self.sendNotification(title: "Merged", body: "\(autoBranch) \u{2192} \(parentBranch)", playSound: true)
                    self.scan(); self.build()
                }
            } else {
                let _ = self.gitCmd(dir: dir, "checkout", autoBranch)
                if !silent { DispatchQueue.main.async { self.sendNotification(title: "Merge Failed", body: "Conflicts in \(autoBranch) \u{2014} resolve manually") } }
            }
        }
    }

    private func autoCleanupGoneSession(sid: String) {
        guard autoMergeBranches else { return }
        guard let auto = try? String(contentsOfFile: "\(home)/.claude/.auto_branch_\(sid)", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let parent = try? String(contentsOfFile: "\(home)/.claude/.parent_branch_\(sid)", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !auto.isEmpty, !parent.isEmpty else { return }
        var dir = ""
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude/.sessions.json")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in arr where entry["id"] as? String == sid { dir = entry["dir"] as? String ?? "" }
        }
        guard !dir.isEmpty else { return }
        mergeSessionBranch(dir: dir, autoBranch: auto, parentBranch: parent, sid: sid, silent: true)
    }

    private func renameBranchIfNeeded(sid: String, name: String) {
        guard let session = sessions.first(where: { $0.sid == sid }),
              !session.autoBranch.isEmpty, !session.parentBranch.isEmpty else { return }
        let slug = String(name.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(25))
        guard !slug.isEmpty else { return }
        let newBranch = "\(session.parentBranch)-\(slug)"
        guard newBranch != session.autoBranch else { return }
        let dir = session.dir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (ok, _) = self.gitCmd(dir: dir, "branch", "-m", session.autoBranch, newBranch)
            if ok { try? newBranch.write(toFile: "\(self.home)/.claude/.auto_branch_\(sid)", atomically: true, encoding: .utf8) }
        }
    }

    // MARK: - Actions

    private func compactAllWaiting() {
        let w = sessions.filter { $0.state == "waiting" && !$0.tty.isEmpty }; guard !w.isEmpty else { return }
        for s in w { typeInTerminal(tty: s.tty, text: "/compact") }
        sendNotification(title: "Claude Monitor", body: "Sent /compact to \(w.count) session\(w.count != 1 ? "s" : "")")
    }

    private func exportSummary() {
        var l = ["## Claude Sessions \u{2014} \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"]
        for s in sessions {
            let n = s.name.isEmpty ? "Session" : s.name; let cost = weekPct - s.weeklyAtStart
            l.append("\(s.state == "active" ? "\u{1F7E2}" : "\u{1F7E1}") **\(n)** \u{2014} \(s.duration) \u{2014} ctx \(s.contextPct)%\(cost > 0 ? " \u{2014} ~\(cost)% weekly" : "")")
            if !s.autoBranch.isEmpty { l.append("   \u{21B3} Branch: \(s.autoBranch) (from \(s.parentBranch))") }
            if !s.smartContext.isEmpty { l.append("   \(s.smartContext)") }; l.append("")
        }
        l.append("Session \(sessPct)% | Weekly \(weekPct)% | Opus \(opusPct)% | Sonnet \(sonnetPct)%")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(l.joined(separator: "\n"), forType: .string)
        sendNotification(title: "Copied", body: "Session summary on clipboard")
    }

    // MARK: - Usage

    private func readUsage() {
        guard let d = FileManager.default.contents(atPath: "\(home)/.claude/.usage_cache.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let fh = j["five_hour"] as? [String: Any] { sessPct = Int(fh["utilization"] as? Double ?? 0); sessResetStr = fmtReset(fh["resets_at"] as? String) ?? "" }
        if let sd = j["seven_day"] as? [String: Any] { weekPct = Int(sd["utilization"] as? Double ?? 0); weekResetStr = fmtDay(sd["resets_at"] as? String) ?? ""; if let ra = sd["resets_at"] as? String { weekResetDate = iso(ra) } }
        opusPct = Int((j["seven_day_opus"] as? [String: Any])?["utilization"] as? Double ?? 0)
        sonnetPct = Int((j["seven_day_sonnet"] as? [String: Any])?["utilization"] as? Double ?? 0)
        velocityTracker.record(pct: weekPct)
    }

    private func readAgentActivity() -> (count: Int, descs: [String]) {
        var count = 0
        if let s = try? String(contentsOfFile: "\(home)/.claude/.active_agents", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let c = Int(s) { count = max(0, c) }
        var descs: [String] = []
        if let d = try? String(contentsOfFile: "\(home)/.claude/.agent_activity", encoding: .utf8) {
            let now = Date().timeIntervalSince1970
            for line in d.split(separator: "\n").suffix(10) { let p = line.split(separator: "|", maxSplits: 1)
                guard p.count == 2, let ts = Double(p[0]), now - ts < 300 else { continue }; descs.append(String(p[1]).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return (count, descs)
    }

    // MARK: - Notifications

    private func cleanupStaleFiles() {
        let fm = FileManager.default; let cd = "\(home)/.claude"
        guard let files = try? fm.contentsOfDirectory(atPath: cd) else { return }
        let px = [".ctx_", ".state_", ".ctxlog_", ".tty_map_", ".tty_resolved_", ".name_tried_", ".activity_", ".files_", ".ctx_pct_", ".parent_branch_", ".auto_branch_"]
        let cutoff = Date().addingTimeInterval(-86400)
        for f in files where px.contains(where: { f.hasPrefix($0) }) {
            if let a = try? fm.attributesOfItem(atPath: "\(cd)/\(f)"), let m = a[.modificationDate] as? Date, m < cutoff { try? fm.removeItem(atPath: "\(cd)/\(f)") } }
    }

    private func checkNotifications() {
        for s in sessions where !s.sid.isEmpty {
            let prev = prevStates[s.sid] ?? ""
            if notifyWaiting && prev == "active" && s.state == "waiting" {
                sendNotification(title: s.name.isEmpty ? s.project : s.name, body: "Ready for input \u{2014} click to jump", playSound: true, tty: s.tty) }
            if notifyContext && s.contextPct >= 80 && !ctxWarned.contains(s.sid) { ctxWarned.insert(s.sid)
                sendNotification(title: "\(s.name.isEmpty ? s.project : s.name) \u{2014} ctx \(s.contextPct)%", body: "Consider /compact", playSound: true, tty: s.tty) }
            prevStates[s.sid] = s.state
        }
    }

    private func sendNotification(title: String, body: String, playSound: Bool = false, tty: String = "") {
        let n = NSUserNotification(); n.title = title; n.informativeText = body
        if playSound && notifySound { n.soundName = NSUserNotificationDefaultSoundName }
        n.userInfo = ["tty": tty]
        NSUserNotificationCenter.default.deliver(n)
    }
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        guard let tty = notification.userInfo?["tty"] as? String, !tty.isEmpty else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.jumpToSession(tty) }
    }
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool { true }

    private func pickupHookNotifications() {
        let path = "\(home)/.claude/.notify_pending"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8), !raw.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1)
        if parts.count == 2 { sendNotification(title: String(parts[0]), body: String(parts[1]), playSound: true) }
        else { sendNotification(title: "Claude Code", body: raw.trimmingCharacters(in: .whitespacesAndNewlines), playSound: true) }
    }

    // MARK: - Haiku

    private func loadNameCache() {
        guard let d = try? String(contentsOfFile: "\(home)/.claude/.session_names", encoding: .utf8) else { return }
        for line in d.split(separator: "\n") { let p = line.split(separator: "|", maxSplits: 1); guard p.count == 2 else { continue }; nameCache[String(p[0])] = String(p[1]) }
    }
    private func saveNameToCache(_ sid: String, _ name: String) {
        nameCache[sid] = name; let line = "\(sid)|\(name)\n"; let path = "\(home)/.claude/.session_names"
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
                    DispatchQueue.main.async {
                        self.saveNameToCache(sid, name)
                        self.pendingNames.remove(sid)
                        self.renameBranchIfNeeded(sid: sid, name: name)
                        self.build()
                    }
                }
            }
        }
    }

    private func resolveSmartContexts() {
        for s in sessions where !s.sid.isEmpty {
            guard !pendingCtx.contains(s.sid) else { continue }
            let lp = "\(home)/.claude/.ctxlog_\(s.sid)"
            guard let ld = try? String(contentsOfFile: lp, encoding: .utf8), !ld.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let hash = String(ld.hashValue); if lastCtxHash[s.sid] == hash { continue }
            lastCtxHash[s.sid] = hash; pendingCtx.insert(s.sid)
            let actions = ld.split(separator: "\n").suffix(6).joined(separator: ", ")
            var diffStat = ""
            if let dir = sessions.first(where: { $0.sid == s.sid })?.dir {
                let (_, last) = gitCmd(dir: dir, "diff", "--stat", "HEAD")
                if let lastLine = last.split(separator: "\n").last { diffStat = ", Git: \(lastLine)" }
            }
            let sid = s.sid
            callHaiku(prompt: "What is this coding session doing RIGHT NOW? Recent actions: \(actions)\(diffStat). Reply in 5-10 words, present tense, specific. No quotes.", maxTokens: 25) { [weak self] result in
                guard let self else { return }
                if let r = result { DispatchQueue.main.async { self.smartCtxCache[sid] = r; self.pendingCtx.remove(sid); self.build() } }
                else { self.pendingCtx.remove(sid) }
            }
        }
    }

    private func callHaiku(prompt: String, maxTokens: Int, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { completion(nil); return }
            let token: String
            if let c = self.cachedToken { token = c } else if let t = self.getOAuthToken() { self.cachedToken = t; token = t } else { completion(nil); return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta"); req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type"); req.timeoutInterval = 8
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "claude-haiku-4-5-20251001", "max_tokens": maxTokens, "messages": [["role": "user", "content": prompt]]] as [String: Any])
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                var result: String?
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]], let text = content.first?["text"] as? String {
                    result = text
                    if let u = json["usage"] as? [String: Any] { DispatchQueue.main.async { self?.haikuCallCount += 1; self?.haikuTokensUsed += (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0) } }
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
              let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = j["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    // MARK: - Scan

    private func scan() {
        let script = """
        for bpid in $(ps -eo pid,tty,args 2>/dev/null | awk '$2 == "??" && /--resume/' | awk '{print $1}'); do
            sid=$(ps -p "$bpid" -o args= 2>/dev/null | sed -n 's/.*--resume \\([^ ]*\\).*/\\1/p')
            [ -z "$sid" ] && continue; current=$bpid
            for i in $(seq 1 15); do
                parent=$(ps -p "$current" -o ppid= 2>/dev/null | tr -d ' ')
                [ -z "$parent" ] || [ "$parent" = "1" ] && break
                ptty=$(ps -p "$parent" -o tty= 2>/dev/null | tr -d ' ')
                if [ "$ptty" != "??" ] && [ -n "$ptty" ]; then [ ! -f "$HOME/.claude/.tty_map_$ptty" ] && echo "$sid" > "$HOME/.claude/.tty_map_$ptty"; break; fi
                current=$parent; done; done
        for pid in $(ps -eo pid,tty,comm 2>/dev/null | awk '$3 == "claude" && $2 != "??" {print $1}'); do
            dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2)}'); [ -z "$dir" ] && continue
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "")
            etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' '); tty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
            modified=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            lastcommit=$(git -C "$dir" log -1 --format='%s' 2>/dev/null | head -1 | cut -c1-50); sid=""
            [ -f "$HOME/.claude/.tty_map_$tty" ] && sid=$(cat "$HOME/.claude/.tty_map_$tty" 2>/dev/null)
            ctx=""; [ -n "$sid" ] && [ -f "$HOME/.claude/.ctx_$sid" ] && ctx=$(cat "$HOME/.claude/.ctx_$sid" 2>/dev/null | head -1 | cut -c1-40)
            state=""; [ -n "$sid" ] && [ -f "$HOME/.claude/.state_$sid" ] && state=$(cat "$HOME/.claude/.state_$sid" 2>/dev/null | head -1)
            ctxpct=""; [ -n "$sid" ] && [ -f "$HOME/.claude/.ctx_pct_$sid" ] && ctxpct=$(cat "$HOME/.claude/.ctx_pct_$sid" 2>/dev/null | head -1)
            echo "$pid|$dir|$branch|$etime|$tty|$modified|$lastcommit|$ctx|$sid|$state|$ctxpct"; done
        """
        let pipe = Pipe(); let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }; proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        readUsage(); let ai = readAgentActivity()

        // Per-session agent counts from sessions.json
        var sessionAgents: [String: Int] = [:]
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude/.sessions.json")),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            for entry in arr { if let id = entry["id"] as? String, let ag = entry["agents"] as? Int { sessionAgents[id] = ag } }
        }

        var result: [Session] = []
        for line in output.split(separator: "\n") where !line.isEmpty {
            let p = line.split(separator: "|", maxSplits: 10, omittingEmptySubsequences: false); guard p.count >= 5 else { continue }
            let sid = p.count > 8 ? String(p[8]) : ""; let dir = String(p[1])
            if !sid.isEmpty && sessionStartUsage[sid] == nil { sessionStartUsage[sid] = weekPct }
            let ab = sid.isEmpty ? "" : (try? String(contentsOfFile: "\(home)/.claude/.auto_branch_\(sid)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pb = sid.isEmpty ? "" : (try? String(contentsOfFile: "\(home)/.claude/.parent_branch_\(sid)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(Session(pid: String(p[0]).trimmingCharacters(in: .whitespaces),
                project: (dir as NSString).lastPathComponent, branch: p.count > 2 ? String(p[2]) : "", dir: dir,
                duration: p.count > 3 ? fmtElapsed(String(p[3])) : "", tty: String(p[4]),
                lastCommit: p.count > 6 ? String(p[6]) : "", context: p.count > 7 ? String(p[7]) : "",
                name: nameCache[sid] ?? "", sid: sid,
                modifiedFiles: p.count > 5 ? Int(String(p[5]).trimmingCharacters(in: .whitespaces)) ?? 0 : 0,
                state: p.count > 9 ? String(p[9]) : "",
                contextPct: p.count > 10 ? Int(String(p[10]).trimmingCharacters(in: .whitespaces).split(separator: ".").first ?? "") ?? 0 : 0,
                smartContext: smartCtxCache[sid] ?? "",
                agentCount: sessionAgents[sid] ?? ai.count, agentDescs: ai.descs,
                weeklyAtStart: sessionStartUsage[sid] ?? weekPct,
                autoBranch: ab, parentBranch: pb))
        }

        // Detect gone sessions for auto-cleanup
        let currentSids = Set(result.compactMap { $0.sid.isEmpty ? nil : $0.sid })
        let goneSids = previousSids.subtracting(currentSids)
        for sid in goneSids { autoCleanupGoneSession(sid: sid) }
        previousSids = currentSids

        sessions = result; resolveNames(); checkNotifications(); renameTerminalTabs()
    }

    private func fmtElapsed(_ s: String) -> String {
        let c = s.trimmingCharacters(in: .whitespaces); guard !c.isEmpty else { return "" }
        var total = 0; let dp = c.split(separator: "-", maxSplits: 1); var tp = c
        if dp.count == 2 { total += (Int(dp[0]) ?? 0) * 86400; tp = String(dp[1]) }
        let n = tp.split(separator: ":").compactMap { Int($0) }
        switch n.count { case 3: total += n[0]*3600+n[1]*60+n[2]; case 2: total += n[0]*60+n[1]; case 1: total += n[0]; default: break }
        if total < 60 { return "\(total)s" }; if total < 3600 { return "\(total/60)m" }
        let h = total/3600; let m = (total%3600)/60; return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }

    // ================================================================
    // MARK: - Build Menu
    // ================================================================

    private func build() {
        readUsage()
        let menu = NSMenu(); menu.autoenablesItems = false; menu.appearance = NSAppearance(named: .darkAqua)
        let n = sessions.count; let wc = sessions.filter { $0.state == "waiting" }.count
        let ac = sessions.filter { $0.state == "active" }.count

        // Menu bar button
        if let b = statusItem.button {
            let s = NSMutableAttributedString()
            let dc: NSColor = ac > 0 ? active : wc > 0 ? waiting : w45
            s.append(a(" \u{25C6}", sz: 13, wt: .bold, cl: n > 0 ? dc : .tertiaryLabelColor))
            if n > 0 {
                s.append(a("\(n)", sz: 11, wt: .bold, cl: .labelColor))
                if wc > 0 { s.append(a(" \u{23F3}\(wc)", sz: 9, wt: .medium, cl: waiting)) }
            }
            if weekPct > 0 {
                let wc2 = weekPct >= 80 ? coral : weekPct >= 60 ? amber : w45
                s.append(a(" \(weekPct)%", sz: 10, wt: .bold, cl: wc2))
            }
            s.append(a(" ", sz: 6, wt: .regular, cl: .clear))
            b.attributedTitle = s
        }

        guard !sessions.isEmpty else {
            addDisabled(a("  \u{25C7} No active sessions", sz: 12, wt: .medium, cl: w45), menu)
            menu.addItem(NSMenuItem.separator())
            usageBlock(menu); footer(menu); statusItem.menu = menu; return
        }

        // Sessions grouped by project
        let byDir = Dictionary(grouping: sessions, by: \.dir)
        for (_, group) in byDir.sorted(by: { $0.key < $1.key }) {
            let f = group[0]

            // Project header
            let ph = NSMutableAttributedString()
            ph.append(a("  \(f.project)", sz: 13, wt: .heavy, cl: w90))
            if !f.branch.isEmpty { ph.append(a("  \(f.branch)", sz: 9, wt: .bold, cl: teal, mono: true)) }
            let totalMod = group.reduce(0) { $0 + $1.modifiedFiles }
            if totalMod > 0 { ph.append(a("  \(totalMod)\u{0394}", sz: 9, wt: .medium, cl: w30, mono: true)) }
            addDisabled(ph, menu)

            // Conflict warning with auto-split
            if group.count > 1 {
                let sameBranch = Set(group.map(\.branch)).count == 1 && !f.branch.isEmpty
                if sameBranch {
                    let si = NSMenuItem(title: "", action: #selector(splitBranches(_:)), keyEquivalent: "")
                    si.target = self; si.attributedTitle = a("  \u{26A0} \(group.count) sessions \u{2014} split branches", sz: 10, wt: .bold, cl: amber)
                    si.representedObject = group.map { ["name": $0.name.isEmpty ? $0.tty : $0.name, "dir": $0.dir, "branch": $0.branch, "tty": $0.tty, "sid": $0.sid] }
                    menu.addItem(si)
                }
            }

            // Session rows
            for s in group {
                let dn = s.name.isEmpty ? (pendingNames.contains(s.sid) ? "Naming..." : "Session") : s.name
                let r = NSMutableAttributedString()

                let dotC: NSColor = s.state == "active" ? active : s.state == "waiting" ? waiting : w30
                r.append(a("  \u{25CF} ", sz: 10, wt: .bold, cl: dotC))
                r.append(a(dn, sz: 13, wt: .bold, cl: w90))

                // Inline metadata
                var meta: [String] = [s.duration]
                if s.contextPct > 0 { meta.append("\(s.contextPct)%") }
                let cost = weekPct - s.weeklyAtStart; if cost > 0 { meta.append("~\(cost)%w") }
                if s.agentCount > 0 { meta.append("+\(s.agentCount)ag") }
                let metaC: NSColor = s.contextPct >= 80 ? coral : s.contextPct >= 60 ? amber : w45
                r.append(a("  \(meta.joined(separator: "\u{00B7}"))", sz: 9, wt: .medium, cl: metaC, mono: true))

                // Auto-branch badge
                if !s.autoBranch.isEmpty {
                    r.append(a("  \u{21B3}", sz: 9, wt: .bold, cl: teal))
                }

                // Smart context on second line
                let ctx = !s.smartContext.isEmpty ? s.smartContext : !s.context.isEmpty ? s.context : s.state == "waiting" ? "Waiting for your input" : "Working..."
                let ctxC: NSColor = !s.smartContext.isEmpty ? purple : s.state == "waiting" ? waiting : w45
                r.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 2)]))
                r.append(a("      \(ctx)", sz: 11, wt: .medium, cl: ctxC))

                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = r; mi.submenu = sessionSubmenu(for: s); menu.addItem(mi)
            }
            menu.addItem(NSMenuItem.separator())
        }

        usageBlock(menu); footer(menu); statusItem.menu = menu
    }

    // MARK: - Session Submenu

    private func sessionSubmenu(for s: Session) -> NSMenu {
        let sub = NSMenu(); sub.autoenablesItems = false
        let isWaiting = s.state == "waiting" || s.state.isEmpty
        let hasTTY = !s.tty.isEmpty

        // Jump to Terminal
        let jump = NSMenuItem(title: "Jump to Terminal", action: #selector(openTerm(_:)), keyEquivalent: "")
        jump.target = self; jump.representedObject = s.tty; jump.isEnabled = hasTTY; sub.addItem(jump)
        sub.addItem(NSMenuItem.separator())

        // Quick commands
        for cmd in ["/compact", "/done", "/clear"] {
            let item = NSMenuItem(title: "Send \(cmd)", action: #selector(sendCmd(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ["tty": s.tty, "cmd": cmd]
            item.isEnabled = isWaiting && hasTTY; sub.addItem(item)
        }
        let custom = NSMenuItem(title: "Custom command\u{2026}", action: #selector(wrapUpSession(_:)), keyEquivalent: "")
        custom.target = self; custom.representedObject = ["tty": s.tty, "name": s.name.isEmpty ? "Session" : s.name]
        custom.isEnabled = isWaiting && hasTTY; sub.addItem(custom)

        // Branch section
        if !s.autoBranch.isEmpty {
            sub.addItem(NSMenuItem.separator())
            let bi = NSMenuItem(); bi.isEnabled = false
            bi.attributedTitle = a("\u{21B3} \(s.autoBranch)", sz: 10, wt: .medium, cl: teal, mono: true); sub.addItem(bi)
            if !s.parentBranch.isEmpty {
                let pi = NSMenuItem(); pi.isEnabled = false
                pi.attributedTitle = a("\u{21B3} from \(s.parentBranch)", sz: 10, wt: .medium, cl: w45, mono: true); sub.addItem(pi)
            }
            if s.branch != s.autoBranch {
                let sw = NSMenuItem(title: "Switch to \(s.autoBranch)", action: #selector(switchBranch(_:)), keyEquivalent: "")
                sw.target = self; sw.representedObject = ["tty": s.tty, "branch": s.autoBranch]
                sw.isEnabled = isWaiting && hasTTY; sub.addItem(sw)
            }
            let merge = NSMenuItem(title: "Merge \u{2192} \(s.parentBranch)", action: #selector(mergeAction(_:)), keyEquivalent: "")
            merge.target = self; merge.representedObject = ["dir": s.dir, "auto": s.autoBranch, "parent": s.parentBranch, "sid": s.sid]
            sub.addItem(merge)
        }

        sub.addItem(NSMenuItem.separator())

        // Open in Finder + Copy Path
        let finder = NSMenuItem(title: "Open in Finder", action: #selector(openFinder(_:)), keyEquivalent: "")
        finder.target = self; finder.representedObject = s.dir; sub.addItem(finder)
        let cp = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        cp.target = self; cp.representedObject = s.dir; sub.addItem(cp)

        return sub
    }

    // MARK: - Usage Block

    private func usageBlock(_ menu: NSMenu) {
        bar("Sess", sessPct, sessResetStr, menu)
        bar("Week", weekPct, weekResetStr, menu)

        var infoItems: [String] = []
        if opusPct > 0 { infoItems.append("Opus \(opusPct)%") }
        if sonnetPct > 0 { infoItems.append("Son \(sonnetPct)%") }
        if let vel = velocityTracker.velocityPerHour(current: weekPct), vel > 0 {
            infoItems.append(String(format: "%.1f%%/hr", vel))
        }
        if let reset = weekResetDate {
            let days = max(1, reset.timeIntervalSinceNow / 86400)
            let perDay = Double(max(0, 100 - weekPct)) / days
            infoItems.append(String(format: "%.0f%%/day", perDay))
        }
        if !infoItems.isEmpty {
            addDisabled(a("  \(infoItems.joined(separator: "  \u{00B7}  "))", sz: 9, wt: .medium, cl: w45, mono: true), menu)
        }

        if let eta = velocityTracker.etaMinutes(current: weekPct, target: 80), weekPct < 80 {
            let etaC: NSColor; let etaS: String
            if eta < 60 { etaC = coral; etaS = "  \u{26A0} 80% in <1h" }
            else if eta < 180 { etaC = amber; etaS = "  80% in ~\(eta/60)h\(eta%60)m" }
            else { etaC = w30; etaS = "  80% in ~\(eta/60)h" }
            addDisabled(a(etaS, sz: 9, wt: .bold, cl: etaC, mono: true), menu)
        } else if weekPct >= 80 {
            addDisabled(a("  \u{26A0} Over 80% weekly limit", sz: 9, wt: .bold, cl: coral, mono: true), menu)
        }

        if let ss = try? String(contentsOfFile: "\(home)/.claude/.weekly_start_pct", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let sp = Int(ss) {
            let d = weekPct - sp; if d > 0 { addDisabled(a("  +\(d)% today", sz: 9, wt: .medium, cl: w30, mono: true), menu) }
        }

        menu.addItem(NSMenuItem.separator())
    }

    private func bar(_ label: String, _ pct: Int, _ reset: String, _ menu: NSMenu) {
        let bc = pct >= 80 ? coral : pct >= 50 ? amber : green
        let f = min(pct * 14 / 100, 14)
        let b = String(repeating: "\u{2588}", count: f) + String(repeating: "\u{2591}", count: 14 - f)
        let r = NSMutableAttributedString()
        r.append(a("  \(label) ", sz: 10, wt: .semibold, cl: w45, mono: true))
        r.append(a(b, sz: 10, wt: .regular, cl: bc, mono: true))
        r.append(a(" \(pct)%", sz: 10, wt: .bold, cl: bc, mono: true))
        if !reset.isEmpty { r.append(a("  \u{21BB}\(reset)", sz: 8, wt: .medium, cl: w30, mono: true)) }
        addDisabled(r, menu)
    }

    // MARK: - Footer

    private func footer(_ menu: NSMenu) {
        let wc = sessions.filter { $0.state == "waiting" }.count
        if wc > 0 {
            let ca = NSMenuItem(title: "", action: #selector(compactAllAction), keyEquivalent: "")
            ca.target = self; ca.attributedTitle = a("  /compact all (\(wc))", sz: 11, wt: .bold, cl: waiting); menu.addItem(ca) }

        if sessions.contains(where: { !$0.autoBranch.isEmpty }) {
            let ma = NSMenuItem(title: "", action: #selector(mergeAllClean), keyEquivalent: "m")
            ma.target = self; ma.attributedTitle = a("  Merge clean branches", sz: 11, wt: .bold, cl: teal); menu.addItem(ma) }

        if !sessions.isEmpty {
            let ex = NSMenuItem(title: "", action: #selector(exportAction), keyEquivalent: "e")
            ex.target = self; ex.attributedTitle = a("  Export summary", sz: 10, wt: .medium, cl: w45); menu.addItem(ex) }

        menu.addItem(NSMenuItem.separator())
        let r = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"); r.target = self; menu.addItem(r)
        let sm = NSMenu()
        tog(sm, "Waiting Alerts", notifyWaiting, #selector(toggleWaiting))
        tog(sm, "Context Warnings", notifyContext, #selector(toggleContext))
        tog(sm, "Notification Sounds", notifySound, #selector(toggleSound))
        tog(sm, "AI Names + Smart Context", enableHaiku, #selector(toggleHaiku))
        tog(sm, "Rename Terminal Tabs", renameTerminals, #selector(toggleRename))
        tog(sm, "Auto-merge on Exit", autoMergeBranches, #selector(toggleAutoMerge))
        sm.addItem(NSMenuItem.separator())
        tog(sm, "Launch at Login", FileManager.default.fileExists(atPath: "\(home)/Library/LaunchAgents/com.claude.monitor.plist"), #selector(toggleAutoLaunch))
        let si = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""); si.submenu = sm; menu.addItem(si)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - @objc Actions

    @objc private func compactAllAction() { compactAllWaiting() }
    @objc private func exportAction() { exportSummary() }
    @objc private func toggleWaiting() { notifyWaiting.toggle(); build() }
    @objc private func toggleContext() { notifyContext.toggle(); build() }
    @objc private func toggleSound() { notifySound.toggle(); build() }
    @objc private func toggleHaiku() { enableHaiku.toggle(); build() }
    @objc private func toggleRename() { renameTerminals.toggle(); build() }
    @objc private func toggleAutoMerge() { autoMergeBranches.toggle(); build() }
    @objc private func refresh() { scan(); build() }
    @objc private func openTerm(_ sender: NSMenuItem) { if let t = sender.representedObject as? String, !t.isEmpty { jumpToSession(t) } }

    @objc private func sendCmd(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let tty = info["tty"], let cmd = info["cmd"], !tty.isEmpty else { return }
        typeInTerminal(tty: tty, text: cmd)
    }

    @objc private func wrapUpSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let tty = info["tty"], !tty.isEmpty else { return }
        let al = NSAlert(); al.messageText = "Send to \"\(info["name"] ?? "session")\""; al.informativeText = "Type command:"
        al.addButton(withTitle: "Send"); al.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); f.placeholderString = "/compact, /done, etc."
        al.accessoryView = f; NSApp.activate(ignoringOtherApps: true)
        if al.runModal() == .alertFirstButtonReturn && !f.stringValue.isEmpty { typeInTerminal(tty: tty, text: f.stringValue) }
    }

    @objc private func switchBranch(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let tty = info["tty"], let branch = info["branch"], !tty.isEmpty else { return }
        typeInTerminal(tty: tty, text: "Switch to branch \(branch) to isolate your changes. Run: git checkout \(branch)")
    }

    @objc private func mergeAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let dir = info["dir"], let auto = info["auto"], let parent = info["parent"], let sid = info["sid"] else { return }
        mergeSessionBranch(dir: dir, autoBranch: auto, parentBranch: parent, sid: sid)
    }

    @objc private func mergeAllClean() {
        let mergeable = sessions.filter { !$0.autoBranch.isEmpty && !$0.parentBranch.isEmpty }
        guard !mergeable.isEmpty else { sendNotification(title: "Nothing to Merge", body: "No auto-branches found"); return }
        for s in mergeable { mergeSessionBranch(dir: s.dir, autoBranch: s.autoBranch, parentBranch: s.parentBranch, sid: s.sid) }
    }

    @objc private func openFinder(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [dir]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(dir, forType: .string)
        sendNotification(title: "Copied", body: dir)
    }

    @objc private func splitBranches(_ sender: NSMenuItem) {
        guard let infos = sender.representedObject as? [[String: String]], infos.count > 1,
              let dir = infos.first?["dir"], let bb = infos.first?["branch"], !bb.isEmpty else { return }
        var created: [String] = []
        for (i, info) in infos.enumerated() {
            guard i > 0, let tty = info["tty"], !tty.isEmpty else { continue }
            let sid = info["sid"] ?? ""
            let slug = String((info["name"] ?? "s\(i)").lowercased().replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(30))
            let br = "\(bb)-\(slug.isEmpty ? "s\(i)" : slug)"
            let (ok, _) = gitCmd(dir: dir, "branch", br, bb)
            guard ok else { continue }
            if !sid.isEmpty {
                try? bb.write(toFile: "\(home)/.claude/.parent_branch_\(sid)", atomically: true, encoding: .utf8)
                try? br.write(toFile: "\(home)/.claude/.auto_branch_\(sid)", atomically: true, encoding: .utf8)
            }
            created.append(br)
            // Tell Claude to switch if session is idle
            let sessState = sessions.first(where: { $0.tty == tty })?.state ?? ""
            if sessState == "waiting" || sessState.isEmpty {
                typeInTerminal(tty: tty, text: "Switch to branch \(br) to avoid conflicts. Run: git checkout \(br)")
            }
        }
        sendNotification(title: "Branches Split", body: "\(created.count) branch\(created.count != 1 ? "es" : "") created", playSound: true)
        scan(); build()
    }

    @objc private func toggleAutoLaunch() {
        let pp = "\(home)/Library/LaunchAgents/com.claude.monitor.plist"; let fm = FileManager.default
        if fm.fileExists(atPath: pp) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["unload", pp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            try? fm.removeItem(atPath: pp); sendNotification(title: "Monitor", body: "Removed from Login Items")
        } else {
            try? fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            try? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>com.claude.monitor</string><key>ProgramArguments</key><array><string>/usr/bin/open</string><string>\(home)/.claude/ClaudeMonitor.app</string></array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>".write(toFile: pp, atomically: true, encoding: .utf8)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["load", pp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            sendNotification(title: "Monitor", body: "Will launch at login", playSound: true)
        }; build()
    }

    // MARK: - Helpers

    private func addDisabled(_ attr: NSAttributedString, _ menu: NSMenu) {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: ""); i.attributedTitle = attr; i.isEnabled = false; menu.addItem(i) }
    private func tog(_ menu: NSMenu, _ label: String, _ on: Bool, _ sel: Selector) {
        let i = NSMenuItem(title: on ? "\u{2713} \(label)" : "   \(label)", action: sel, keyEquivalent: ""); i.target = self; menu.addItem(i) }
    private func a(_ s: String, sz: CGFloat, wt: NSFont.Weight, cl: NSColor, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: sz, weight: wt) : NSFont.systemFont(ofSize: sz, weight: wt), .foregroundColor: cl]) }
    private func fmtReset(_ s: String?) -> String? { guard let s, let d = iso(s) else { return nil }; let r = d.timeIntervalSinceNow; guard r > 0 else { return nil }; return "\(Int(r)/3600)h\((Int(r)%3600)/60)m" }
    private func fmtDay(_ s: String?) -> String? { guard let s, let d = iso(s) else { return nil }; let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d) }
    private func iso(_ s: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }() }
}

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let d = Monitor(); app.delegate = d; app.run()
