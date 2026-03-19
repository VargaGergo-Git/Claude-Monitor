import AppKit
import Foundation

struct Session {
    var pid, project, branch, dir, duration, tty, lastCommit, context, name, sid: String
    var modifiedFiles: Int
    var state: String          // "active", "waiting", or ""
    var contextPct: Int        // context window usage 0-100
    var smartContext: String   // Haiku-summarized context
}

class Monitor: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var sessions: [Session] = []
    private let home = NSHomeDirectory()
    private var nameCache: [String: String] = [:]
    private var pendingNames = Set<String>()
    private var smartCtxCache: [String: String] = [:]    // sid -> smart summary
    private var lastCtxHash: [String: String] = [:]      // sid -> hash of context log
    private var pendingCtx = Set<String>()
    private var prevStates: [String: String] = [:]       // sid -> last known state
    private var ctxWarned = Set<String>()                // sids already warned about context
    private var renamedTTYs = Set<String>()              // ttys already renamed in Terminal

    // Settings (persisted in UserDefaults)
    private let ud = UserDefaults.standard
    private var notifyWaiting: Bool { get { ud.object(forKey: "notifyWaiting") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyWaiting") } }
    private var notifyContext: Bool { get { ud.object(forKey: "notifyContext") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyContext") } }
    private var notifySound: Bool { get { ud.object(forKey: "notifySound") as? Bool ?? true } set { ud.set(newValue, forKey: "notifySound") } }
    private var enableHaiku: Bool { get { ud.object(forKey: "enableHaiku") as? Bool ?? true } set { ud.set(newValue, forKey: "enableHaiku") } }

    let teal  = NSColor(red: 0.0, green: 0.55, blue: 0.48, alpha: 1.0)
    let amber = NSColor(red: 0.75, green: 0.50, blue: 0.0, alpha: 1.0)
    let green = NSColor(red: 0.22, green: 0.72, blue: 0.42, alpha: 1.0)
    let coral = NSColor(red: 0.82, green: 0.22, blue: 0.18, alpha: 1.0)
    let activeGreen  = NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1.0)
    let waitingAmber = NSColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1.0)
    let ctxWarn      = NSColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1.0)

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Ensure ~/.claude/ exists (works even before first Claude Code session)
        try? FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        cleanupStaleFiles()
        loadNameCache()
        scan(); build()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.build() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(); self?.build() }
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard self?.enableHaiku == true else { return }
            self?.resolveSmartContexts()
        }
    }

    // MARK: - Cleanup

    private func cleanupStaleFiles() {
        let fm = FileManager.default
        let claudeDir = "\(home)/.claude"
        let prefixes = [".ctx_", ".state_", ".ctxlog_", ".tty_map_", ".tty_resolved_", ".name_tried_", ".activity_", ".files_", ".ctx_pct_"]
        let cutoff = Date().addingTimeInterval(-86400) // 24 hours ago
        guard let files = try? fm.contentsOfDirectory(atPath: claudeDir) else { return }
        for file in files {
            guard prefixes.contains(where: { file.hasPrefix($0) }) else { continue }
            let path = "\(claudeDir)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date, mod < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Notifications

    private func checkNotifications() {
        for session in sessions where !session.sid.isEmpty {
            let sid = session.sid
            let prev = prevStates[sid] ?? ""
            let curr = session.state

            // Notify: active -> waiting (Claude finished, needs input)
            if notifyWaiting && prev == "active" && curr == "waiting" {
                let name = session.name.isEmpty ? session.project : session.name
                notify(title: "\(name)", body: "Ready for your input", sound: notifySound ? "Tink" : nil)
            }

            // Warn: context crossed 80%
            if notifyContext && session.contextPct >= 80 && !ctxWarned.contains(sid) {
                ctxWarned.insert(sid)
                let name = session.name.isEmpty ? session.project : session.name
                notify(title: "\(name) — Context \(session.contextPct)%", body: "Consider running /compact to free up space", sound: notifySound ? "Submarine" : nil)
            }

            prevStates[sid] = curr
        }
    }

    private func notify(title: String, body: String, sound: String? = "Tink") {
        let et = title.replacingOccurrences(of: "\"", with: "'")
        let eb = body.replacingOccurrences(of: "\"", with: "'")
        let soundPart = sound != nil ? " sound name \"\(sound!)\"" : ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(eb)\" with title \"\(et)\"\(soundPart)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: - Name Cache

    private func loadNameCache() {
        let path = "\(home)/.claude/.session_names"
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in data.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            nameCache[String(parts[0])] = String(parts[1])
        }
    }

    private func saveNameToCache(_ sid: String, _ name: String) {
        nameCache[sid] = name
        let path = "\(home)/.claude/.session_names"
        let line = "\(sid)|\(name)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8) ?? Data()); fh.closeFile()
        } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    // MARK: - Haiku Name Resolution

    private func resolveNames() {
        guard enableHaiku else { return }
        for session in sessions where session.name.isEmpty && !session.sid.isEmpty {
            let sid = session.sid
            guard !pendingNames.contains(sid) else { continue }
            pendingNames.insert(sid)

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let projectHash = session.dir.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                let jsonlPath = "\(self.home)/.claude/projects/\(projectHash)/\(sid).jsonl"
                guard let data = try? String(contentsOfFile: jsonlPath, encoding: .utf8) else {
                    self.pendingNames.remove(sid); return
                }
                var rawMsg = ""
                for line in data.split(separator: "\n").prefix(200) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          obj["type"] as? String == "user",
                          let message = obj["message"] as? [String: Any],
                          let content = message["content"] as? String,
                          !content.hasPrefix("<"), content.count > 5 else { continue }
                    rawMsg = String(content.prefix(200)); break
                }
                guard !rawMsg.isEmpty else { self.pendingNames.remove(sid); return }
                self.callHaiku(
                    prompt: "Give a 2-5 word title for this coding task. Reply ONLY the title. Task: \(rawMsg)",
                    maxTokens: 15
                ) { result in
                    let name = result ?? String(rawMsg.split(separator: "\n").first?.prefix(35) ?? "Unknown")
                    DispatchQueue.main.async {
                        self.saveNameToCache(sid, name)
                        self.pendingNames.remove(sid)
                        self.build()
                    }
                }
            }
        }
    }

    // MARK: - Haiku Smart Context

    private func resolveSmartContexts() {
        for session in sessions where !session.sid.isEmpty {
            let sid = session.sid
            guard !pendingCtx.contains(sid) else { continue }

            let logPath = "\(home)/.claude/.ctxlog_\(sid)"
            guard let logData = try? String(contentsOfFile: logPath, encoding: .utf8),
                  !logData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Only call if log changed
            let hash = String(logData.hashValue)
            if lastCtxHash[sid] == hash { continue }
            lastCtxHash[sid] = hash
            pendingCtx.insert(sid)

            let actions = logData.split(separator: "\n").suffix(6).joined(separator: ", ")

            // Get git diff stat for richer context
            var diffStat = ""
            if let dir = sessions.first(where: { $0.sid == sid })?.dir {
                let pipe = Pipe(); let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                proc.arguments = ["-C", dir, "diff", "--stat", "HEAD"]
                proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
                try? proc.run(); proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let last = out.split(separator: "\n").last { diffStat = ", Git changes: \(last)" }
            }

            callHaiku(
                prompt: "What is this coding session doing RIGHT NOW? Recent actions: \(actions)\(diffStat). Reply in 5-10 words, present tense, specific. No quotes.",
                maxTokens: 25
            ) { [weak self] result in
                guard let self else { return }
                if let summary = result {
                    DispatchQueue.main.async {
                        self.smartCtxCache[sid] = summary
                        self.pendingCtx.remove(sid)
                        self.build()
                    }
                } else {
                    self.pendingCtx.remove(sid)
                }
            }
        }
    }

    // MARK: - Haiku API

    private var cachedToken: String?
    // Haiku usage -- persisted in UserDefaults
    private var haikuCallCount: Int {
        get { ud.integer(forKey: "haikuCalls") }
        set { ud.set(newValue, forKey: "haikuCalls") }
    }
    private var haikuTokensUsed: Int {
        get { ud.integer(forKey: "haikuTokens") }
        set { ud.set(newValue, forKey: "haikuTokens") }
    }

    private func callHaiku(prompt: String, maxTokens: Int, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { completion(nil); return }
            let token: String
            if let cached = self.cachedToken { token = cached }
            else if let t = self.getOAuthToken() { self.cachedToken = t; token = t }
            else { completion(nil); return }

            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001", "max_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 8

            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                var result: String?
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String {
                    result = text
                    // Track usage
                    if let usage = json["usage"] as? [String: Any] {
                        let inp = usage["input_tokens"] as? Int ?? 0
                        let out = usage["output_tokens"] as? Int ?? 0
                        DispatchQueue.main.async {
                            self?.haikuCallCount += 1
                            self?.haikuTokensUsed += inp + out
                        }
                    }
                }
                completion(result)
            }.resume()
        }
    }

    private func getOAuthToken() -> String? {
        let pipe = Pipe(); let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }; proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
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
            lastcommit=$(git -C "$dir" log -1 --format='%s' 2>/dev/null | head -1 | cut -c1-45)
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

        let pipe = Pipe(); let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }; proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var result: [Session] = []
        for line in output.split(separator: "\n") where !line.isEmpty {
            let p = line.split(separator: "|", maxSplits: 10, omittingEmptySubsequences: false)
            guard p.count >= 5 else { continue }
            let sid = p.count > 8 ? String(p[8]) : ""
            result.append(Session(
                pid: String(p[0]).trimmingCharacters(in: .whitespaces),
                project: (String(p[1]) as NSString).lastPathComponent,
                branch: p.count > 2 ? String(p[2]) : "",
                dir: String(p[1]),
                duration: p.count > 3 ? fmtElapsed(String(p[3])) : "",
                tty: String(p[4]),
                lastCommit: p.count > 6 ? String(p[6]) : "",
                context: p.count > 7 ? String(p[7]) : "",
                name: nameCache[sid] ?? "",
                sid: sid,
                modifiedFiles: p.count > 5 ? Int(String(p[5]).trimmingCharacters(in: .whitespaces)) ?? 0 : 0,
                state: p.count > 9 ? String(p[9]) : "",
                contextPct: p.count > 10 ? Int(String(p[10]).trimmingCharacters(in: .whitespaces).split(separator: ".").first ?? "") ?? 0 : 0,
                smartContext: smartCtxCache[sid] ?? ""
            ))
        }
        sessions = result
        resolveNames()
        checkNotifications()
        renameTerminalTabs()
    }

    // MARK: - Terminal Tab Renaming

    private func renameTerminalTabs() {
        var renames: [(tty: String, title: String)] = []
        for session in sessions where !session.name.isEmpty && !session.tty.isEmpty {
            let title = session.name.replacingOccurrences(of: "\"", with: "'")
            renames.append((session.tty, title))
        }
        guard !renames.isEmpty else { return }

        var checks = ""
        for r in renames {
            checks += """
                            if ttyPath is "/dev/\(r.tty)" then
                                set custom title of t to "\(r.title)"
                                set title displays custom title of t to true
                                set title displays shell path of t to false
                                set title displays window size of t to false
                                set title displays device name of t to false
                                set title displays file name of t to false
                                set title displays settings name of t to false
                            end if\n
            """
        }

        DispatchQueue.global(qos: .utility).async {
            let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        set ttyPath to tty of t
                        \(checks)
                    end repeat
                end repeat
            end tell
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }

    private func fmtElapsed(_ s: String) -> String {
        let c = s.trimmingCharacters(in: .whitespaces); guard !c.isEmpty else { return "" }
        var total = 0; let dp = c.split(separator: "-", maxSplits: 1); var tp = c
        if dp.count == 2 { total += (Int(dp[0]) ?? 0) * 86400; tp = String(dp[1]) }
        let n = tp.split(separator: ":").compactMap { Int($0) }
        switch n.count {
        case 3: total += n[0]*3600 + n[1]*60 + n[2]
        case 2: total += n[0]*60 + n[1]; case 1: total += n[0]; default: break }
        if total < 60 { return "\(total)s" }; if total < 3600 { return "\(total/60)m" }
        let h = total/3600; let m = (total%3600)/60; return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }

    // MARK: - Build Menu

    private func build() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)

        // Menu bar button: count + waiting + timer
        let n = sessions.count
        let waitingCount = sessions.filter { $0.state == "waiting" }.count
        let activeSession = sessions.first { $0.state == "active" }
        let timerStr = activeSession?.duration ?? sessions.first?.duration ?? ""

        if let b = statusItem.button {
            let str = NSMutableAttributedString()
            if n == 0 {
                str.append(a(" \u{25C6} ", sz: 13, wt: .bold, cl: .tertiaryLabelColor))
            } else {
                str.append(a(" \u{25C6} \(n)", sz: 13, wt: .bold, cl: .labelColor))
                if waitingCount > 0 {
                    str.append(a(" \u{00B7} \(waitingCount)\u{23F3}", sz: 11, wt: .medium, cl: waitingAmber))
                }
                if !timerStr.isEmpty {
                    str.append(a(" \u{00B7} \(timerStr) ", sz: 11, wt: .medium, cl: NSColor(white: 0.55, alpha: 1)))
                }
            }
            b.attributedTitle = str
        }

        guard !sessions.isEmpty else {
            txt("  No active sessions", sz: 13, wt: .medium, cl: .white, menu: menu)
            footer(menu); statusItem.menu = menu; return
        }

        let byDir = Dictionary(grouping: sessions, by: \.dir)
        for (_, group) in byDir.sorted(by: { $0.key < $1.key }) {
            let first = group[0]

            // Project header
            let h = NSMutableAttributedString()
            h.append(a("  \(first.project) ", sz: 14, wt: .bold, cl: .white))
            if !first.branch.isEmpty { h.append(a(first.branch, sz: 12, wt: .bold, cl: teal, mono: true)) }
            item(h, menu: menu)

            // Branch warning + split
            if group.count > 1 {
                txt("  \u{26A0} \(group.count) sessions sharing one branch", sz: 12, wt: .bold, cl: amber, menu: menu)
                let splitItem = NSMenuItem(title: "", action: #selector(splitBranches(_:)), keyEquivalent: "")
                splitItem.target = self
                splitItem.attributedTitle = a("  \u{2192} Split into separate branches", sz: 11, wt: .medium, cl: teal)
                splitItem.representedObject = group.map { ["name": $0.name.isEmpty ? $0.tty : $0.name, "dir": $0.dir, "branch": $0.branch, "tty": $0.tty] }
                menu.addItem(splitItem)
            }

            // Git info
            if first.modifiedFiles > 0 || !first.lastCommit.isEmpty {
                var info = first.modifiedFiles > 0 ? "  \(first.modifiedFiles) changed" : ""
                if !first.lastCommit.isEmpty { info += info.isEmpty ? "  \(first.lastCommit)" : " \u{00B7} \(first.lastCommit)" }
                txt(info, sz: 11, wt: .medium, cl: NSColor(white: 0.65, alpha: 1), menu: menu)
            }

            menu.addItem(NSMenuItem.separator())
            for session in group { sessionRow(session, menu: menu) }
            menu.addItem(NSMenuItem.separator())
        }

        usage(menu); footer(menu); statusItem.menu = menu
    }

    private func sessionRow(_ s: Session, menu: NSMenu) {
        let displayName = s.name.isEmpty ? (pendingNames.contains(s.sid) ? "Naming..." : "Session") : s.name

        let row = NSMutableAttributedString()

        // State dot
        let dot: String; let dotColor: NSColor
        switch s.state {
        case "active":  dot = "\u{25CF} "; dotColor = activeGreen
        case "waiting": dot = "\u{25CF} "; dotColor = waitingAmber
        default:        dot = "\u{25CB} "; dotColor = NSColor(white: 0.45, alpha: 1)
        }
        row.append(a("  \(dot)", sz: 12, wt: .bold, cl: dotColor))

        // Name + duration
        row.append(a(displayName, sz: 13, wt: .bold, cl: .white))
        row.append(a("  \(s.duration)", sz: 11, wt: .semibold, cl: NSColor(white: 0.5, alpha: 1), mono: true))

        // Metadata: context %
        var meta: [NSAttributedString] = []

        if s.contextPct > 0 {
            let ctxColor = s.contextPct >= 80 ? coral : s.contextPct >= 60 ? ctxWarn : NSColor(white: 0.45, alpha: 1)
            meta.append(a("ctx \(s.contextPct)%", sz: 10, wt: .semibold, cl: ctxColor, mono: true))
        }
        if !meta.isEmpty {
            row.append(a("  ", sz: 10, wt: .regular, cl: .clear))
            for (i, m) in meta.enumerated() {
                row.append(m)
                if i < meta.count - 1 { row.append(a(" \u{00B7} ", sz: 9, wt: .regular, cl: NSColor(white: 0.35, alpha: 1))) }
            }
        }

        // Line 2: Smart context (Haiku) or raw context
        let ctxText: String
        if !s.smartContext.isEmpty {
            ctxText = s.smartContext
        } else if !s.context.isEmpty {
            ctxText = s.context
        } else if s.state == "waiting" {
            ctxText = "Waiting for your input"
        } else {
            ctxText = "Starting up..."
        }
        row.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 3)]))
        row.append(a("     \(ctxText)", sz: 12, wt: .medium, cl: NSColor(white: 0.70, alpha: 1)))

        let mi = NSMenuItem(title: "", action: #selector(openTerm(_:)), keyEquivalent: "")
        mi.target = self; mi.representedObject = s.tty; mi.attributedTitle = row
        mi.isEnabled = true; menu.addItem(mi)

        // "Wrap Up" button -- only show for waiting/idle sessions
        if s.state == "waiting" || s.state.isEmpty {
            let wrap = NSMenuItem(title: "", action: #selector(wrapUpSession(_:)), keyEquivalent: "")
            wrap.target = self
            wrap.representedObject = ["tty": s.tty, "name": displayName]
            wrap.attributedTitle = a("     \u{23FB} Send command...", sz: 11, wt: .medium, cl: NSColor(white: 0.50, alpha: 1))
            menu.addItem(wrap)
        }
    }

    @objc private func wrapUpSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let tty = info["tty"], !tty.isEmpty else { return }
        let name = info["name"] ?? "this session"

        let alert = NSAlert()
        alert.messageText = "Send command to \"\(name)\""
        alert.informativeText = "Type a message or command to send to this session:"
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. summarize what you did, or /compact"
        alert.accessoryView = field
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty {
            typeInTerminal(tty: tty, text: field.stringValue)
        }
    }

    private func typeInTerminal(tty: String, text: String) {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        delay 0.3
        tell application "System Events"
            tell process "Terminal"
                keystroke "\(escapedText)"
                keystroke return
            end tell
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    @objc private func openTerm(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String, !tty.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: - Branch Splitting

    @objc private func splitBranches(_ sender: NSMenuItem) {
        guard let infos = sender.representedObject as? [[String: String]],
              infos.count > 1, let dir = infos.first?["dir"],
              let baseBranch = infos.first?["branch"], !baseBranch.isEmpty else { return }

        var commands = ["# Run in each terminal after exiting Claude:\n"]
        var created: [String] = []
        for (i, info) in infos.enumerated() {
            let raw = info["name"] ?? "session-\(i)"
            let slug = String(raw.lowercased().replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(30))
            let branch = "\(baseBranch)-\(slug)"
            if i == 0 { commands += ["# \(raw): stays on \(baseBranch)\n"]; continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", dir, "branch", branch, baseBranch]
            proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit()
            created.append(branch); commands += ["# \(raw)", "git checkout \(branch)\n"]
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"Created \(created.count) branches. Commands copied.\" with title \"Branches Split\" sound name \"Glass\""]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    // MARK: - Usage

    private func usage(_ menu: NSMenu) {
        guard let data = FileManager.default.contents(atPath: "\(home)/.claude/.usage_cache.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            txt("  Usage unavailable", sz: 11, wt: .regular, cl: NSColor(white: 0.5, alpha: 1), menu: menu); return
        }
        let fh = json["five_hour"] as? [String: Any]; let sd = json["seven_day"] as? [String: Any]
        let weeklyPct = Int(sd?["utilization"] as? Double ?? 0)
        bar("Session", pct: Int(fh?["utilization"] as? Double ?? 0), reset: fmtReset(fh?["resets_at"] as? String), menu: menu)
        bar("Weekly ", pct: weeklyPct, reset: fmtDay(sd?["resets_at"] as? String), menu: menu)

        // Show weekly delta (how much was added today)
        let startPath = "\(home)/.claude/.weekly_start_pct"
        var infoLine = ""
        if let startStr = try? String(contentsOfFile: startPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let startPct = Int(startStr) {
            let delta = weeklyPct - startPct
            if delta > 0 { infoLine += "+\(delta)% today" }
        }

        // Haiku monitor overhead
        if enableHaiku {
            let sep = infoLine.isEmpty ? "" : "  \u{00B7}  "
            infoLine += "\(sep)Monitor: \(haikuCallCount) Haiku calls, ~\(haikuTokensUsed) tok"
        }

        if !infoLine.isEmpty {
            txt("  \(infoLine)", sz: 10, wt: .medium, cl: NSColor(white: 0.45, alpha: 1), menu: menu)
        }
    }

    private func bar(_ label: String, pct: Int, reset: String?, menu: NSMenu) {
        let bc = pct >= 80 ? coral : pct >= 50 ? amber : green
        let f = min(pct * 16 / 100, 16)
        let b = String(repeating: "\u{2588}", count: f) + String(repeating: "\u{2591}", count: 16 - f)
        let r = NSMutableAttributedString()
        r.append(a("  \(label) ", sz: 11, wt: .semibold, cl: NSColor(white: 0.6, alpha: 1), mono: true))
        r.append(a(b, sz: 11, wt: .regular, cl: bc, mono: true))
        r.append(a(" \(pct)%", sz: 11, wt: .bold, cl: bc, mono: true))
        if let rs = reset { r.append(a("  \u{21BB} \(rs)", sz: 10, wt: .medium, cl: NSColor(white: 0.5, alpha: 1), mono: true)) }
        item(r, menu: menu)
    }

    private func footer(_ menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let r = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        r.target = self; menu.addItem(r)

        // Settings submenu
        let settingsMenu = NSMenu()

        let waitItem = NSMenuItem(title: notifyWaiting ? "\u{2713} Waiting Alerts" : "   Waiting Alerts", action: #selector(toggleWaiting), keyEquivalent: "")
        waitItem.target = self; settingsMenu.addItem(waitItem)

        let ctxItem = NSMenuItem(title: notifyContext ? "\u{2713} Context Warnings" : "   Context Warnings", action: #selector(toggleContext), keyEquivalent: "")
        ctxItem.target = self; settingsMenu.addItem(ctxItem)

        let soundItem = NSMenuItem(title: notifySound ? "\u{2713} Notification Sounds" : "   Notification Sounds", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self; settingsMenu.addItem(soundItem)

        let haikuItem = NSMenuItem(title: enableHaiku ? "\u{2713} AI Session Names" : "   AI Session Names", action: #selector(toggleHaiku), keyEquivalent: "")
        haikuItem.target = self; settingsMenu.addItem(haikuItem)

        settingsMenu.addItem(NSMenuItem.separator())

        let launchAgentPath = "\(home)/Library/LaunchAgents/com.claude.monitor.plist"
        let isInstalled = FileManager.default.fileExists(atPath: launchAgentPath)
        let launchItem = NSMenuItem(title: isInstalled ? "\u{2713} Launch at Login" : "   Launch at Login", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        launchItem.target = self; settingsMenu.addItem(launchItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleWaiting() { notifyWaiting.toggle(); build() }
    @objc private func toggleContext() { notifyContext.toggle(); build() }
    @objc private func toggleSound() { notifySound.toggle(); build() }
    @objc private func toggleHaiku() { enableHaiku.toggle(); build() }

    @objc private func toggleAutoLaunch() {
        let launchAgentDir = "\(home)/Library/LaunchAgents"
        let plistPath = "\(launchAgentDir)/com.claude.monitor.plist"
        let fm = FileManager.default

        if fm.fileExists(atPath: plistPath) {
            // Uninstall
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["unload", plistPath]; p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            try? fm.removeItem(atPath: plistPath)
            notify(title: "Claude Monitor", body: "Removed from Login Items", sound: "Tink")
        } else {
            // Install
            try? fm.createDirectory(atPath: launchAgentDir, withIntermediateDirectories: true)
            let appPath = "\(home)/.claude/ClaudeMonitor.app"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
                <key>Label</key><string>com.claude.monitor</string>
                <key>ProgramArguments</key><array>
                    <string>/usr/bin/open</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key><true/>
                <key>StandardOutPath</key><string>/dev/null</string>
                <key>StandardErrorPath</key><string>/dev/null</string>
            </dict></plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["load", plistPath]; p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            notify(title: "Claude Monitor", body: "Will launch at login", sound: "Glass")
        }
        build()
    }

    // Helpers
    private func a(_ s: String, sz: CGFloat, wt: NSFont.Weight, cl: NSColor, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: sz, weight: wt) : NSFont.systemFont(ofSize: sz, weight: wt),
            .foregroundColor: cl])
    }
    private func txt(_ s: String, sz: CGFloat, wt: NSFont.Weight, cl: NSColor, menu: NSMenu) {
        item(a(s, sz: sz, wt: wt, cl: cl), menu: menu)
    }
    private func item(_ attr: NSAttributedString, menu: NSMenu) {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        i.attributedTitle = attr; i.isEnabled = false; menu.addItem(i)
    }
    private func fmtReset(_ s: String?) -> String? {
        guard let s, let d = iso(s) else { return nil }
        let r = d.timeIntervalSinceNow; guard r > 0 else { return nil }
        return "\(Int(r)/3600)h\((Int(r)%3600)/60)m"
    }
    private func fmtDay(_ s: String?) -> String? {
        guard let s, let d = iso(s) else { return nil }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }
    private func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
    }
    @objc private func refresh() { scan(); build() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Monitor(); app.delegate = d; app.run()
