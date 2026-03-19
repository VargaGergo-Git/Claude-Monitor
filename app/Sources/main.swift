import AppKit
import Foundation

struct Session {
    var pid, project, branch, dir, duration, tty, lastCommit, context, name, sid: String
    var modifiedFiles: Int
    var state: String
    var contextPct: Int
    var smartContext: String
    var agentCount: Int
    var agentDescs: [String]     // what each agent is doing
    var editedFiles: [String]    // files this session has touched
}

// MARK: - Velocity Tracker

class VelocityTracker {
    private let path: String
    private var readings: [(ts: TimeInterval, pct: Int)] = []

    init(home: String) {
        path = "\(home)/.claude/.usage_velocity.json"
        load()
    }

    func record(pct: Int) {
        let now = Date().timeIntervalSince1970
        // Don't record if same value within 60 seconds
        if let last = readings.last, last.pct == pct && (now - last.ts) < 60 { return }
        readings.append((now, pct))
        // Keep last 100 readings (plenty for velocity calculation)
        if readings.count > 100 { readings = Array(readings.suffix(100)) }
        save()
    }

    /// Returns estimated minutes until target % is reached, or nil if pace is too slow/declining
    func etaMinutes(current: Int, target: Int) -> Int? {
        guard current < target else { return nil }
        let now = Date().timeIntervalSince1970
        // Use readings from the last 2 hours
        let recent = readings.filter { now - $0.ts < 7200 && now - $0.ts > 60 }
        guard recent.count >= 2 else { return nil }
        let oldest = recent.first!
        let elapsed = now - oldest.ts
        let gained = current - oldest.pct
        guard gained > 0, elapsed > 0 else { return nil }
        let pctPerSec = Double(gained) / elapsed
        let remaining = Double(target - current) / pctPerSec
        return Int(remaining / 60)
    }

    /// Returns % gained per hour
    func velocityPerHour(current: Int) -> Double? {
        let now = Date().timeIntervalSince1970
        let recent = readings.filter { now - $0.ts < 3600 && now - $0.ts > 60 }
        guard recent.count >= 2 else { return nil }
        let oldest = recent.first!
        let elapsed = now - oldest.ts
        let gained = current - oldest.pct
        guard elapsed > 120 else { return nil }
        return Double(gained) / (elapsed / 3600.0)
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        readings = arr.compactMap { r in
            guard let ts = r["t"] as? Double, let pct = r["p"] as? Int else { return nil }
            return (ts, pct)
        }
    }

    private func save() {
        let arr = readings.map { ["t": $0.ts, "p": $0.pct] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Overlay Panel

class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 48),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        self.setFrameOrigin(NSPoint(x: screen.maxX - 356, y: screen.maxY - 64))
    }
}

class OverlayView: NSView {
    var sessions: [Session] = []
    var sessPct = 0, weekPct = 0, opusPct = 0, sonnetPct = 0
    var sessReset = "", weekReset = "", weeklyDelta = ""
    var velocityStr = ""
    var etaStr = ""
    var conflicts: [String] = []
    var compact = false
    var cardRects: [NSRect] = []
    var hoverIndex = -1
    var closeHover = false
    var compactAllHover = false
    var exportHover = false
    var trackingArea: NSTrackingArea?
    var compactAllRect = NSRect.zero
    var exportRect = NSRect.zero

    var onSessionClick: ((Session) -> Void)?
    var onClose: (() -> Void)?
    var onToggleCompact: (() -> Void)?
    var onCompactAll: (() -> Void)?
    var onExport: (() -> Void)?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    func recalcHeight() {
        if compact {
            frame.size = NSSize(width: 340, height: 52)
        } else {
            var h: CGFloat = 38 // header
            h += CGFloat(sessions.count) * 58 // cards
            if !conflicts.isEmpty { h += 22 } // conflict warning
            h += 52 // usage section (session + weekly + model breakdown)
            if !velocityStr.isEmpty { h += 16 } // velocity line
            h += 34 // action buttons
            h += 8  // bottom pad
            frame.size = NSSize(width: 340, height: min(max(h, 52), 500))
        }
        window?.setContentSize(frame.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)

        // Background gradient
        NSColor(white: 0.05, alpha: 0.90).setFill()
        path.fill()

        // Subtle top highlight
        let topLine = NSBezierPath()
        topLine.move(to: NSPoint(x: 20, y: 1))
        topLine.line(to: NSPoint(x: w - 20, y: 1))
        NSColor(white: 0.3, alpha: 0.3).setStroke()
        topLine.lineWidth = 0.5
        topLine.stroke()

        // Border
        NSColor(white: 0.18, alpha: 0.5).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Close button
        let closeRect = NSRect(x: w - 28, y: 8, width: 18, height: 18)
        let closeFg: NSColor = closeHover ? NSColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 1) : NSColor(white: 0.3, alpha: 1)
        draw("\u{00D7}", at: NSPoint(x: closeRect.minX + 4, y: closeRect.minY + 1), font: .systemFont(ofSize: 12, weight: .bold), color: closeFg)

        var y: CGFloat = 0

        // == HEADER ==
        let anyActive = sessions.contains { $0.state == "active" }
        let anyWaiting = sessions.contains { $0.state == "waiting" }
        let diamondColor: NSColor = anyActive ? NSColor(red: 0.3, green: 0.78, blue: 0.5, alpha: 1) :
            anyWaiting ? NSColor(red: 0.9, green: 0.7, blue: 0.15, alpha: 1) :
            NSColor(white: 0.35, alpha: 1)

        // Diamond
        let dp = NSBezierPath()
        dp.move(to: NSPoint(x: 16, y: y + 10)); dp.line(to: NSPoint(x: 22, y: y + 19))
        dp.line(to: NSPoint(x: 16, y: y + 28)); dp.line(to: NSPoint(x: 10, y: y + 19)); dp.close()
        diamondColor.setFill(); dp.fill()
        // Diamond glow
        diamondColor.withAlphaComponent(0.15).setFill()
        let glowDp = NSBezierPath()
        glowDp.move(to: NSPoint(x: 16, y: y + 7)); glowDp.line(to: NSPoint(x: 25, y: y + 19))
        glowDp.line(to: NSPoint(x: 16, y: y + 31)); glowDp.line(to: NSPoint(x: 7, y: y + 19)); glowDp.close()
        glowDp.fill()

        let headerText = sessions.isEmpty ? "Claude Monitor" : "\(sessions.count) session\(sessions.count != 1 ? "s" : "")"
        let headerPt = NSPoint(x: 30, y: y + 10)
        draw(headerText, at: headerPt, font: .systemFont(ofSize: 13, weight: .bold), color: NSColor(white: 0.88, alpha: 1))

        // Total agents
        let totalAgents = sessions.reduce(0) { $0 + $1.agentCount }
        if totalAgents > 0 {
            let agentStr = "+\(totalAgents) agent\(totalAgents != 1 ? "s" : "")"
            let headerWidth = (headerText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]).width
            draw(agentStr, at: NSPoint(x: 30 + headerWidth + 8, y: y + 12), font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: NSColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 1))
        }

        // State dots
        if !sessions.isEmpty {
            var dotX: CGFloat = w - 36 - CGFloat(sessions.count) * 12
            for s in sessions {
                let dc: NSColor = s.state == "active" ? NSColor(red: 0.3, green: 0.78, blue: 0.5, alpha: 1) :
                    s.state == "waiting" ? NSColor(red: 0.9, green: 0.7, blue: 0.15, alpha: 1) :
                    NSColor(white: 0.2, alpha: 1)
                dc.setFill()
                NSBezierPath(ovalIn: NSRect(x: dotX, y: y + 15, width: 7, height: 7)).fill()
                dotX += 12
            }
        }
        y += 38

        if compact {
            if sessPct > 0 || weekPct > 0 {
                let cl = "S:\(sessPct)%  W:\(weekPct)%"
                draw(cl, at: NSPoint(x: 30, y: y - 6), font: .monospacedSystemFont(ofSize: 10, weight: .medium), color: barColor(sessPct))
                if !etaStr.isEmpty {
                    let clWidth = (cl as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]).width
                    draw(etaStr, at: NSPoint(x: 30 + clWidth + 10, y: y - 6), font: .systemFont(ofSize: 9, weight: .medium), color: NSColor(white: 0.4, alpha: 1))
                }
            }
            return
        }

        // == CONFLICT WARNING ==
        if !conflicts.isEmpty {
            let warnRect = NSRect(x: 8, y: y, width: w - 16, height: 18)
            NSColor(red: 0.4, green: 0.15, blue: 0.1, alpha: 0.4).setFill()
            NSBezierPath(roundedRect: warnRect, xRadius: 4, yRadius: 4).fill()
            let conflictStr = "\u{26A0} File conflict: \(conflicts.first ?? "")\(conflicts.count > 1 ? " +\(conflicts.count - 1) more" : "")"
            draw(conflictStr, at: NSPoint(x: 14, y: y + 2), font: .systemFont(ofSize: 9, weight: .bold), color: NSColor(red: 1, green: 0.7, blue: 0.3, alpha: 1))
            y += 22
        }

        // == SESSION CARDS ==
        cardRects = []
        for (i, s) in sessions.enumerated() {
            let cardRect = NSRect(x: 6, y: y, width: w - 12, height: 56)
            cardRects.append(cardRect)

            let isHover = hoverIndex == i
            let cardBg: NSColor = isHover ? NSColor(white: 0.12, alpha: 0.8) : NSColor(white: 0.07, alpha: 0.5)
            let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8)
            cardBg.setFill(); cardPath.fill()

            // Hover border
            if isHover {
                NSColor(white: 0.25, alpha: 0.5).setStroke()
                cardPath.lineWidth = 0.5; cardPath.stroke()
            }

            let cx = cardRect.minX + 10, cy = cardRect.minY + 5

            // State dot with glow
            let dotColor: NSColor = s.state == "active" ? NSColor(red: 0.3, green: 0.78, blue: 0.5, alpha: 1) :
                s.state == "waiting" ? NSColor(red: 0.9, green: 0.7, blue: 0.15, alpha: 1) :
                NSColor(white: 0.2, alpha: 1)
            if s.state == "active" || s.state == "waiting" {
                dotColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 2, y: cy + 1, width: 12, height: 12)).fill()
            }
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx, y: cy + 3, width: 8, height: 8)).fill()

            // Name
            let name = s.name.isEmpty ? "Session" : (s.name.count > 24 ? String(s.name.prefix(21)) + "..." : s.name)
            draw(name, at: NSPoint(x: cx + 14, y: cy), font: .systemFont(ofSize: 11, weight: .bold), color: .white)

            // Agent badge (if agents running)
            if s.agentCount > 0 {
                let nameWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]).width
                let agentBadge = "+\(s.agentCount)"
                let badgeX = cx + 14 + nameWidth + 4
                NSColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 0.6).setFill()
                NSBezierPath(roundedRect: NSRect(x: badgeX, y: cy + 1, width: 20, height: 12), xRadius: 3, yRadius: 3).fill()
                draw(agentBadge, at: NSPoint(x: badgeX + 3, y: cy + 1), font: .monospacedSystemFont(ofSize: 8, weight: .bold), color: NSColor(red: 0.55, green: 0.7, blue: 0.95, alpha: 1))
            }

            // Right: ctx% + duration
            var rightParts: [String] = []
            if s.contextPct > 0 { rightParts.append("ctx \(s.contextPct)%") }
            if !s.duration.isEmpty { rightParts.append(s.duration) }
            let rightStr = rightParts.joined(separator: " \u{00B7} ")
            if !rightStr.isEmpty {
                let rightSize = (rightStr as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)])
                let ctxColor = s.contextPct >= 80 ? NSColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 1) :
                    s.contextPct >= 60 ? NSColor(red: 0.9, green: 0.55, blue: 0.15, alpha: 1) :
                    NSColor(white: 0.4, alpha: 1)
                draw(rightStr, at: NSPoint(x: cardRect.maxX - rightSize.width - 8, y: cy + 2), font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: ctxColor)
            }

            // Smart context (line 2)
            var ctxLine = s.smartContext.isEmpty ? s.context : s.smartContext
            if ctxLine.isEmpty { ctxLine = s.state == "waiting" ? "Waiting for your input" : "Working..." }
            if ctxLine.count > 42 { ctxLine = String(ctxLine.prefix(39)) + "..." }
            let ctxColor: NSColor = s.smartContext.isEmpty ? NSColor(white: 0.35, alpha: 1) : NSColor(red: 0.5, green: 0.55, blue: 0.78, alpha: 1)
            draw(ctxLine, at: NSPoint(x: cx + 14, y: cy + 17), font: .systemFont(ofSize: 10, weight: .medium), color: ctxColor)

            // Agent description (line 2.5 — only if agents active)
            if !s.agentDescs.isEmpty {
                let agentLine = s.agentDescs.prefix(2).joined(separator: ", ")
                let truncAgent = agentLine.count > 40 ? String(agentLine.prefix(37)) + "..." : agentLine
                draw(truncAgent, at: NSPoint(x: cx + 14, y: cy + 30), font: .systemFont(ofSize: 8, weight: .medium), color: NSColor(red: 0.45, green: 0.55, blue: 0.8, alpha: 0.7))
            }

            // Mini progress bar
            let barX = cx + 14, barY = cy + (s.agentDescs.isEmpty ? 34 : 42), barW: CGFloat = 90, barH: CGFloat = 3
            NSColor(white: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH), xRadius: 1.5, yRadius: 1.5).fill()
            let fillW = barW * CGFloat(min(s.contextPct, 100)) / 100
            if fillW > 0 {
                barColor(s.contextPct).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: fillW, height: barH), xRadius: 1.5, yRadius: 1.5).fill()
            }

            // "click to jump" badge for all sessions
            if isHover {
                draw("click \u{2192} jump", at: NSPoint(x: cardRect.maxX - 62, y: barY - 1), font: .systemFont(ofSize: 7, weight: .bold), color: NSColor(white: 0.45, alpha: 0.8))
            }

            y += 58
        }

        // == USAGE SECTION ==
        let uy = y + 4
        if sessPct > 0 || weekPct > 0 {
            drawUsageBar(label: "Session", pct: sessPct, reset: sessReset, delta: "", x: 10, y: uy)
            drawUsageBar(label: "Weekly ", pct: weekPct, reset: weekReset, delta: weeklyDelta, x: 10, y: uy + 16)

            // Model breakdown (compact)
            var modelLine = ""
            if opusPct > 0 { modelLine += "Opus \(opusPct)%" }
            if sonnetPct > 0 { modelLine += modelLine.isEmpty ? "" : "  "; modelLine += "Sonnet \(sonnetPct)%" }
            if !modelLine.isEmpty {
                draw(modelLine, at: NSPoint(x: 10, y: uy + 32), font: .monospacedSystemFont(ofSize: 8, weight: .medium), color: NSColor(white: 0.3, alpha: 1))
            }
        } else {
            draw("No usage data yet", at: NSPoint(x: 10, y: uy + 4), font: .systemFont(ofSize: 10, weight: .medium), color: NSColor(white: 0.2, alpha: 1))
        }

        // Velocity + ETA line
        if !velocityStr.isEmpty {
            let velY = uy + 46
            draw(velocityStr, at: NSPoint(x: 10, y: velY), font: .systemFont(ofSize: 9, weight: .medium), color: NSColor(white: 0.38, alpha: 1))
            if !etaStr.isEmpty {
                let velWidth = (velocityStr as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width
                let etaColor = etaStr.contains("< 1h") ? NSColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1) :
                    etaStr.contains("< 2h") ? NSColor(red: 0.9, green: 0.6, blue: 0.15, alpha: 1) :
                    NSColor(white: 0.38, alpha: 1)
                draw(etaStr, at: NSPoint(x: 10 + velWidth + 8, y: velY), font: .systemFont(ofSize: 9, weight: .bold), color: etaColor)
            }
            y = velY + 16
        } else {
            y = uy + 52
        }

        // == ACTION BUTTONS ==
        let actY = y + 2
        NSColor(white: 0.15, alpha: 0.4).setStroke()
        let sepLine = NSBezierPath()
        sepLine.move(to: NSPoint(x: 10, y: actY)); sepLine.line(to: NSPoint(x: w - 10, y: actY))
        sepLine.lineWidth = 0.5; sepLine.stroke()

        let btnY = actY + 6
        let btnH: CGFloat = 22
        let hasWaiting = sessions.contains { $0.state == "waiting" }
        let waitCount = sessions.filter { $0.state == "waiting" }.count

        // Compact All button
        let compactText = hasWaiting ? "/compact all (\(waitCount))" : "/compact all"
        let compactW: CGFloat = 130
        compactAllRect = NSRect(x: 10, y: btnY, width: compactW, height: btnH)
        if compactAllHover && hasWaiting {
            NSColor(white: 0.12, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: compactAllRect, xRadius: 6, yRadius: 6).fill()
        }
        draw(compactText, at: NSPoint(x: 16, y: btnY + 4), font: .systemFont(ofSize: 9, weight: .bold),
             color: hasWaiting ? NSColor(red: 0.9, green: 0.7, blue: 0.15, alpha: 1) : NSColor(white: 0.18, alpha: 1))

        // Export button
        let exportText = "\u{2398} Export summary"
        let exportW: CGFloat = 110
        exportRect = NSRect(x: w - exportW - 10, y: btnY, width: exportW, height: btnH)
        if exportHover {
            NSColor(white: 0.12, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: exportRect, xRadius: 6, yRadius: 6).fill()
        }
        draw(exportText, at: NSPoint(x: w - exportW - 4, y: btnY + 4), font: .systemFont(ofSize: 9, weight: .bold), color: NSColor(red: 0.45, green: 0.6, blue: 0.8, alpha: 1))
    }

    func drawUsageBar(label: String, pct: Int, reset: String, delta: String, x: CGFloat, y: CGFloat) {
        draw(label, at: NSPoint(x: x, y: y), font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: NSColor(white: 0.32, alpha: 1))
        let bx = x + 52, bw: CGFloat = 100, bh: CGFloat = 7
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bx, y: y + 3, width: bw, height: bh), xRadius: 3, yRadius: 3).fill()
        let fw = bw * CGFloat(min(pct, 100)) / 100
        if fw > 0 {
            barColor(pct).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: y + 3, width: fw, height: bh), xRadius: 3, yRadius: 3).fill()
        }
        var extra = "\(pct)%"
        if !reset.isEmpty { extra += " \u{21BB}\(reset)" }
        if !delta.isEmpty { extra += " \(delta)" }
        draw(extra, at: NSPoint(x: bx + bw + 4, y: y + 1), font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: barColor(pct))
    }

    func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    func barColor(_ pct: Int) -> NSColor {
        if pct >= 80 { return NSColor(red: 0.82, green: 0.27, blue: 0.23, alpha: 1) }
        if pct >= 50 { return NSColor(red: 0.78, green: 0.63, blue: 0.15, alpha: 1) }
        return NSColor(red: 0.22, green: 0.62, blue: 0.39, alpha: 1)
    }

    // -- Mouse --

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if NSRect(x: bounds.width - 28, y: 8, width: 18, height: 18).contains(loc) { onClose?(); return }
        if event.clickCount == 2 && loc.y < 38 { onToggleCompact?(); return }
        if !compact {
            if compactAllRect.contains(loc) { onCompactAll?(); return }
            if exportRect.contains(loc) { onExport?(); return }
            for (i, rect) in cardRects.enumerated() where rect.contains(loc) {
                if i < sessions.count { onSessionClick?(sessions[i]) }
                return
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        var changed = false
        let newClose = NSRect(x: bounds.width - 28, y: 8, width: 18, height: 18).contains(loc)
        if newClose != closeHover { closeHover = newClose; changed = true }
        var newHover = -1
        if !compact { for (i, rect) in cardRects.enumerated() where rect.contains(loc) { newHover = i; break } }
        if newHover != hoverIndex { hoverIndex = newHover; changed = true }
        let newCompactAll = !compact && compactAllRect.contains(loc)
        if newCompactAll != compactAllHover { compactAllHover = newCompactAll; changed = true }
        let newExport = !compact && exportRect.contains(loc)
        if newExport != exportHover { exportHover = newExport; changed = true }
        if changed { needsDisplay = true }
        NSCursor.pointingHand.set()
        if newHover < 0 && !newClose && !newCompactAll && !newExport { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        var changed = false
        if hoverIndex >= 0 { hoverIndex = -1; changed = true }
        if closeHover { closeHover = false; changed = true }
        if compactAllHover { compactAllHover = false; changed = true }
        if exportHover { exportHover = false; changed = true }
        if changed { NSCursor.arrow.set(); needsDisplay = true }
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

    private var overlayPanel: OverlayPanel!
    private var overlayView: OverlayView!
    private var velocityTracker: VelocityTracker!

    private var showOverlay: Bool {
        get { ud.object(forKey: "showOverlay") as? Bool ?? true }
        set { ud.set(newValue, forKey: "showOverlay") }
    }
    private var overlayCompact: Bool {
        get { ud.object(forKey: "overlayCompact") as? Bool ?? false }
        set { ud.set(newValue, forKey: "overlayCompact") }
    }

    private let ud = UserDefaults.standard
    private var notifyWaiting: Bool { get { ud.object(forKey: "notifyWaiting") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyWaiting") } }
    private var notifyContext: Bool { get { ud.object(forKey: "notifyContext") as? Bool ?? true } set { ud.set(newValue, forKey: "notifyContext") } }
    private var notifySound: Bool { get { ud.object(forKey: "notifySound") as? Bool ?? true } set { ud.set(newValue, forKey: "notifySound") } }
    private var enableHaiku: Bool { get { ud.object(forKey: "enableHaiku") as? Bool ?? true } set { ud.set(newValue, forKey: "enableHaiku") } }

    let teal = NSColor(red: 0.0, green: 0.55, blue: 0.48, alpha: 1.0)
    let amber = NSColor(red: 0.75, green: 0.50, blue: 0.0, alpha: 1.0)
    let green = NSColor(red: 0.22, green: 0.72, blue: 0.42, alpha: 1.0)
    let coral = NSColor(red: 0.82, green: 0.22, blue: 0.18, alpha: 1.0)
    let activeGreen = NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1.0)
    let waitingAmber = NSColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1.0)
    let ctxWarn = NSColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1.0)

    private var haikuCallCount: Int { get { ud.integer(forKey: "haikuCalls") } set { ud.set(newValue, forKey: "haikuCalls") } }
    private var haikuTokensUsed: Int { get { ud.integer(forKey: "haikuTokens") } set { ud.set(newValue, forKey: "haikuTokens") } }
    private var cachedToken: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        try? FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        cleanupStaleFiles()
        loadNameCache()
        velocityTracker = VelocityTracker(home: home)

        // Notification click handler — jump to session terminal
        NSUserNotificationCenter.default.delegate = self

        overlayPanel = OverlayPanel()
        overlayView = OverlayView(frame: NSRect(x: 0, y: 0, width: 340, height: 48))
        overlayView.compact = overlayCompact
        overlayView.onSessionClick = { [weak self] s in self?.jumpToSession(s) }
        overlayView.onClose = { [weak self] in self?.showOverlay = false; self?.overlayPanel.orderOut(nil) }
        overlayView.onToggleCompact = { [weak self] in
            guard let self else { return }
            self.overlayCompact.toggle(); self.overlayView.compact = self.overlayCompact; self.updateOverlay()
        }
        overlayView.onCompactAll = { [weak self] in self?.compactAllWaiting() }
        overlayView.onExport = { [weak self] in self?.exportSummary() }
        overlayPanel.contentView = overlayView
        if showOverlay { overlayPanel.orderFront(nil) }

        scan(); build()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.build() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(); self?.build() }
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard self?.enableHaiku == true else { return }
            self?.resolveSmartContexts()
        }
    }

    // MARK: - Actions

    private func jumpToSession(_ session: Session) {
        guard !session.tty.isEmpty else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(session.tty)" then
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

    private func compactAllWaiting() {
        let waiting = sessions.filter { $0.state == "waiting" && !$0.tty.isEmpty }
        guard !waiting.isEmpty else { return }
        for s in waiting { typeInTerminal(tty: s.tty, text: "/compact") }
        sendNotification(title: "Claude Monitor", body: "Sent /compact to \(waiting.count) session\(waiting.count != 1 ? "s" : "")", sound: "Tink")
    }

    private func exportSummary() {
        var lines: [String] = ["## Claude Session Summary \u{2014} \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"]
        for s in sessions {
            let name = s.name.isEmpty ? "Session" : s.name
            let state = s.state == "active" ? "\u{1F7E2}" : s.state == "waiting" ? "\u{1F7E1}" : "\u{26AA}"
            lines.append("\(state) **\(name)** (\(s.project)/\(s.branch))")
            lines.append("   Duration: \(s.duration) | Context: \(s.contextPct)%")
            if !s.smartContext.isEmpty { lines.append("   Doing: \(s.smartContext)") }
            if s.agentCount > 0 { lines.append("   Agents: \(s.agentCount) running") }
            lines.append("")
        }
        if sessPct > 0 { lines.append("Session usage: \(sessPct)% | Weekly: \(weekPct)%") }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        sendNotification(title: "Claude Monitor", body: "Session summary copied to clipboard", sound: "Tink")
    }

    // MARK: - File Conflict Detection

    private func detectConflicts() -> [String] {
        guard sessions.count > 1 else { return [] }
        var fileMap: [String: [String]] = [:] // file -> [session names]
        for s in sessions where !s.dir.isEmpty {
            let pipe = Pipe(); let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", s.dir, "diff", "--name-only", "HEAD"]
            proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let name = s.name.isEmpty ? s.project : s.name
            for file in out.split(separator: "\n") where !file.isEmpty {
                let f = String(file)
                fileMap[f, default: []].append(name)
            }
        }
        return fileMap.filter { $0.value.count > 1 }.map { "\($0.key.split(separator: "/").last ?? Substring($0.key)) (\($0.value.joined(separator: " & ")))" }
    }

    // MARK: - Agent Activity

    private func readAgentActivity() -> (count: Int, descs: [String]) {
        let countPath = "\(home)/.claude/.active_agents"
        let actPath = "\(home)/.claude/.agent_activity"
        var count = 0
        if let str = try? String(contentsOfFile: countPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let c = Int(str) { count = max(0, c) }

        var descs: [String] = []
        if let data = try? String(contentsOfFile: actPath, encoding: .utf8) {
            let now = Date().timeIntervalSince1970
            for line in data.split(separator: "\n").suffix(10) {
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let ts = Double(parts[0]), now - ts < 300 else { continue }
                descs.append(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (count, descs)
    }

    // MARK: - Overlay

    private var sessPct = 0, weekPct = 0

    private func updateOverlay() {
        guard showOverlay else { overlayPanel.orderOut(nil); return }

        overlayView.sessions = sessions
        overlayView.compact = overlayCompact

        // Usage
        if let data = FileManager.default.contents(atPath: "\(home)/.claude/.usage_cache.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let fh = json["five_hour"] as? [String: Any]; let sd = json["seven_day"] as? [String: Any]
            sessPct = Int(fh?["utilization"] as? Double ?? 0)
            weekPct = Int(sd?["utilization"] as? Double ?? 0)
            overlayView.sessPct = sessPct
            overlayView.weekPct = weekPct
            overlayView.sessReset = fmtReset(fh?["resets_at"] as? String) ?? ""
            overlayView.weekReset = fmtDay(sd?["resets_at"] as? String) ?? ""

            // Per-model
            if let opus = json["seven_day_opus"] as? [String: Any] {
                overlayView.opusPct = Int(opus["utilization"] as? Double ?? 0)
            }
            if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
                overlayView.sonnetPct = Int(sonnet["utilization"] as? Double ?? 0)
            }

            // Velocity tracking
            velocityTracker.record(pct: weekPct)
            if let vel = velocityTracker.velocityPerHour(current: weekPct) {
                overlayView.velocityStr = String(format: "%.1f%%/hr pace", vel)
            } else { overlayView.velocityStr = "" }
            if let eta = velocityTracker.etaMinutes(current: weekPct, target: 80) {
                if eta < 60 { overlayView.etaStr = "80% in < 1h \u{26A0}" }
                else { overlayView.etaStr = "80% in ~\(eta/60)h\(eta%60)m" }
            } else { overlayView.etaStr = weekPct >= 80 ? "over 80% \u{26A0}" : "" }
        }

        // Weekly delta
        let startPath = "\(home)/.claude/.weekly_start_pct"
        if let startStr = try? String(contentsOfFile: startPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let startPct = Int(startStr) {
            let delta = weekPct - startPct
            overlayView.weeklyDelta = delta > 0 ? "+\(delta)%" : ""
        }

        // Conflicts
        overlayView.conflicts = detectConflicts()

        overlayView.recalcHeight()
        overlayView.needsDisplay = true
        if !overlayPanel.isVisible { overlayPanel.orderFront(nil) }
    }

    // MARK: - Cleanup + Notifications + Name Cache (unchanged)

    private func cleanupStaleFiles() {
        let fm = FileManager.default; let cd = "\(home)/.claude"
        let px = [".ctx_", ".state_", ".ctxlog_", ".tty_map_", ".tty_resolved_", ".name_tried_", ".activity_", ".files_", ".ctx_pct_"]
        let cutoff = Date().addingTimeInterval(-86400)
        guard let files = try? fm.contentsOfDirectory(atPath: cd) else { return }
        for f in files { guard px.contains(where: { f.hasPrefix($0) }) else { continue }
            if let a = try? fm.attributesOfItem(atPath: "\(cd)/\(f)"), let m = a[.modificationDate] as? Date, m < cutoff { try? fm.removeItem(atPath: "\(cd)/\(f)") } }
    }

    private func checkNotifications() {
        for s in sessions where !s.sid.isEmpty {
            let prev = prevStates[s.sid] ?? ""
            if notifyWaiting && prev == "active" && s.state == "waiting" {
                let name = s.name.isEmpty ? s.project : s.name
                sendNotification(title: name, body: "Ready for your input \u{2014} click to jump",
                                 sound: notifySound ? "Tink" : nil, tty: s.tty)
            }
            if notifyContext && s.contextPct >= 80 && !ctxWarned.contains(s.sid) {
                ctxWarned.insert(s.sid)
                let name = s.name.isEmpty ? s.project : s.name
                sendNotification(title: "\(name) \u{2014} Context \(s.contextPct)%",
                                 body: "Consider running /compact \u{2014} click to jump",
                                 sound: notifySound ? "Submarine" : nil, tty: s.tty)
            }
            prevStates[s.sid] = s.state
        }
    }

    private func sendNotification(title: String, body: String, sound: String? = "Tink", tty: String = "") {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        if let soundName = sound { n.soundName = soundName }
        // Store tty so we can jump to it when clicked
        n.userInfo = ["tty": tty]
        NSUserNotificationCenter.default.deliver(n)
    }

    // Clicking a notification jumps to the session's terminal tab
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if let tty = notification.userInfo?["tty"] as? String, !tty.isEmpty {
            jumpToSession(Session(pid: "", project: "", branch: "", dir: "", duration: "", tty: tty,
                lastCommit: "", context: "", name: "", sid: "", modifiedFiles: 0, state: "",
                contextPct: 0, smartContext: "", agentCount: 0, agentDescs: [], editedFiles: []))
        }
    }

    // Always show notifications even when app is frontmost
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    private func loadNameCache() {
        guard let data = try? String(contentsOfFile: "\(home)/.claude/.session_names", encoding: .utf8) else { return }
        for line in data.split(separator: "\n") { let p = line.split(separator: "|", maxSplits: 1)
            guard p.count == 2 else { continue }; nameCache[String(p[0])] = String(p[1]) }
    }

    private func saveNameToCache(_ sid: String, _ name: String) {
        nameCache[sid] = name; let path = "\(home)/.claude/.session_names"; let line = "\(sid)|\(name)\n"
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8) ?? Data()); fh.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    // MARK: - Haiku

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
                    if let usage = json["usage"] as? [String: Any] { let inp = usage["input_tokens"] as? Int ?? 0; let out = usage["output_tokens"] as? Int ?? 0
                        DispatchQueue.main.async { self?.haikuCallCount += 1; self?.haikuTokensUsed += inp + out } }
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
        let pipe = Pipe(); let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }; proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let agentInfo = readAgentActivity()
        var result: [Session] = []
        for line in output.split(separator: "\n") where !line.isEmpty {
            let p = line.split(separator: "|", maxSplits: 10, omittingEmptySubsequences: false)
            guard p.count >= 5 else { continue }
            let sid = p.count > 8 ? String(p[8]) : ""
            result.append(Session(pid: String(p[0]).trimmingCharacters(in: .whitespaces),
                project: (String(p[1]) as NSString).lastPathComponent, branch: p.count > 2 ? String(p[2]) : "",
                dir: String(p[1]), duration: p.count > 3 ? fmtElapsed(String(p[3])) : "", tty: String(p[4]),
                lastCommit: p.count > 6 ? String(p[6]) : "", context: p.count > 7 ? String(p[7]) : "",
                name: nameCache[sid] ?? "", sid: sid,
                modifiedFiles: p.count > 5 ? Int(String(p[5]).trimmingCharacters(in: .whitespaces)) ?? 0 : 0,
                state: p.count > 9 ? String(p[9]) : "",
                contextPct: p.count > 10 ? Int(String(p[10]).trimmingCharacters(in: .whitespaces).split(separator: ".").first ?? "") ?? 0 : 0,
                smartContext: smartCtxCache[sid] ?? "",
                agentCount: agentInfo.count, agentDescs: agentInfo.descs, editedFiles: []))
        }
        sessions = result; resolveNames(); checkNotifications()
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
        let script = "tell application \"Terminal\"\nactivate\nrepeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/\(tty)\" then\nset selected tab of w to t\nset index of w to 1\nend if\nend repeat\nend repeat\nend tell\ndelay 0.3\ntell application \"System Events\"\ntell process \"Terminal\"\nkeystroke \"\(escaped)\"\nkeystroke return\nend tell\nend tell"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run()
    }

    // MARK: - Build Menu

    private func build() {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.appearance = NSAppearance(named: .darkAqua)
        let n = sessions.count; let wc = sessions.filter { $0.state == "waiting" }.count
        let ts = (sessions.first { $0.state == "active" } ?? sessions.first)?.duration ?? ""

        if let b = statusItem.button {
            let str = NSMutableAttributedString()
            if n == 0 { str.append(a(" \u{25C6} ", sz: 13, wt: .bold, cl: .tertiaryLabelColor)) }
            else {
                str.append(a(" \u{25C6} \(n)", sz: 13, wt: .bold, cl: .labelColor))
                if wc > 0 { str.append(a(" \u{00B7} \(wc)\u{23F3}", sz: 11, wt: .medium, cl: waitingAmber)) }
                if !ts.isEmpty { str.append(a(" \u{00B7} \(ts) ", sz: 11, wt: .medium, cl: NSColor(white: 0.55, alpha: 1))) }
            }
            b.attributedTitle = str
        }

        guard !sessions.isEmpty else {
            txt("  No active sessions", sz: 13, wt: .medium, cl: .white, menu: menu)
            footer(menu); statusItem.menu = menu; updateOverlay(); return
        }

        let byDir = Dictionary(grouping: sessions, by: \.dir)
        for (_, group) in byDir.sorted(by: { $0.key < $1.key }) {
            let f = group[0]
            let h = NSMutableAttributedString()
            h.append(a("  \(f.project) ", sz: 14, wt: .bold, cl: .white))
            if !f.branch.isEmpty { h.append(a(f.branch, sz: 12, wt: .bold, cl: teal, mono: true)) }
            item(h, menu: menu)

            if group.count > 1 {
                txt("  \u{26A0} \(group.count) sessions sharing one branch", sz: 12, wt: .bold, cl: amber, menu: menu)
                let si = NSMenuItem(title: "", action: #selector(splitBranches(_:)), keyEquivalent: "")
                si.target = self; si.attributedTitle = a("  \u{2192} Split into separate branches", sz: 11, wt: .medium, cl: teal)
                si.representedObject = group.map { ["name": $0.name.isEmpty ? $0.tty : $0.name, "dir": $0.dir, "branch": $0.branch, "tty": $0.tty] }
                menu.addItem(si)
            }

            if f.modifiedFiles > 0 || !f.lastCommit.isEmpty {
                var info = f.modifiedFiles > 0 ? "  \(f.modifiedFiles) changed" : ""
                if !f.lastCommit.isEmpty { info += info.isEmpty ? "  \(f.lastCommit)" : " \u{00B7} \(f.lastCommit)" }
                txt(info, sz: 11, wt: .medium, cl: NSColor(white: 0.65, alpha: 1), menu: menu)
            }

            menu.addItem(NSMenuItem.separator())
            for s in group { sessionRow(s, menu: menu) }
            menu.addItem(NSMenuItem.separator())
        }

        usage(menu); footer(menu); statusItem.menu = menu; updateOverlay()
    }

    private func sessionRow(_ s: Session, menu: NSMenu) {
        let dn = s.name.isEmpty ? (pendingNames.contains(s.sid) ? "Naming..." : "Session") : s.name
        let row = NSMutableAttributedString()
        let (dot, dc): (String, NSColor) = s.state == "active" ? ("\u{25CF} ", activeGreen) : s.state == "waiting" ? ("\u{25CF} ", waitingAmber) : ("\u{25CB} ", NSColor(white: 0.45, alpha: 1))
        row.append(a("  \(dot)", sz: 12, wt: .bold, cl: dc))
        row.append(a(dn, sz: 13, wt: .bold, cl: .white))
        if s.agentCount > 0 { row.append(a(" +\(s.agentCount)", sz: 10, wt: .bold, cl: NSColor(red: 0.45, green: 0.6, blue: 0.9, alpha: 1))) }
        row.append(a("  \(s.duration)", sz: 11, wt: .semibold, cl: NSColor(white: 0.5, alpha: 1), mono: true))
        if s.contextPct > 0 {
            let cc = s.contextPct >= 80 ? coral : s.contextPct >= 60 ? ctxWarn : NSColor(white: 0.45, alpha: 1)
            row.append(a("  ctx \(s.contextPct)%", sz: 10, wt: .semibold, cl: cc, mono: true))
        }
        let ctx = !s.smartContext.isEmpty ? s.smartContext : !s.context.isEmpty ? s.context : s.state == "waiting" ? "Waiting for your input" : "Starting up..."
        let ctxC: NSColor = s.smartContext.isEmpty ? NSColor(white: 0.55, alpha: 1) : NSColor(red: 0.55, green: 0.6, blue: 0.85, alpha: 1)
        row.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 3)]))
        row.append(a("     \(ctx)", sz: 12, wt: .medium, cl: ctxC))

        let mi = NSMenuItem(title: "", action: #selector(openTerm(_:)), keyEquivalent: "")
        mi.target = self; mi.representedObject = s.tty; mi.attributedTitle = row; mi.isEnabled = true; menu.addItem(mi)

        if s.state == "waiting" || s.state.isEmpty {
            let wrap = NSMenuItem(title: "", action: #selector(wrapUpSession(_:)), keyEquivalent: "")
            wrap.target = self; wrap.representedObject = ["tty": s.tty, "name": dn]
            wrap.attributedTitle = a("     \u{23FB} Send command...", sz: 11, wt: .medium, cl: NSColor(white: 0.50, alpha: 1))
            menu.addItem(wrap)
        }
    }

    @objc private func wrapUpSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let tty = info["tty"], !tty.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Send command to \"\(info["name"] ?? "session")\""
        alert.informativeText = "Type a message or command:"; alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.placeholderString = "/compact, /done, or custom"
        alert.accessoryView = field; NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty { typeInTerminal(tty: tty, text: field.stringValue) }
    }

    @objc private func openTerm(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String, !tty.isEmpty else { return }
        jumpToSession(Session(pid: "", project: "", branch: "", dir: "", duration: "", tty: tty, lastCommit: "", context: "", name: "", sid: "", modifiedFiles: 0, state: "", contextPct: 0, smartContext: "", agentCount: 0, agentDescs: [], editedFiles: []))
    }

    @objc private func splitBranches(_ sender: NSMenuItem) {
        guard let infos = sender.representedObject as? [[String: String]], infos.count > 1, let dir = infos.first?["dir"], let bb = infos.first?["branch"], !bb.isEmpty else { return }
        var cmds = ["# Branch split commands:\n"]; var created: [String] = []
        for (i, info) in infos.enumerated() {
            let raw = info["name"] ?? "session-\(i)"
            let slug = String(raw.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(30))
            let branch = "\(bb)-\(slug)"
            if i == 0 { cmds += ["# \(raw): stays on \(bb)\n"]; continue }
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", dir, "branch", branch, bb]; proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit(); created.append(branch); cmds += ["git checkout \(branch)"]
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmds.joined(separator: "\n"), forType: .string)
        sendNotification(title: "Branches Split", body: "Created \(created.count) branches. Commands copied.", sound: "Glass")
    }

    // MARK: - Usage + Footer

    private func usage(_ menu: NSMenu) {
        guard let data = FileManager.default.contents(atPath: "\(home)/.claude/.usage_cache.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            txt("  Usage unavailable", sz: 11, wt: .regular, cl: NSColor(white: 0.5, alpha: 1), menu: menu); return }
        let fh = json["five_hour"] as? [String: Any]; let sd = json["seven_day"] as? [String: Any]
        let wp = Int(sd?["utilization"] as? Double ?? 0)
        bar("Session", pct: Int(fh?["utilization"] as? Double ?? 0), reset: fmtReset(fh?["resets_at"] as? String), menu: menu)
        bar("Weekly ", pct: wp, reset: fmtDay(sd?["resets_at"] as? String), menu: menu)

        // Model breakdown in menu too
        var modelLine = "  "
        if let opus = json["seven_day_opus"] as? [String: Any], let u = opus["utilization"] as? Double, u > 0 { modelLine += "Opus \(Int(u))%" }
        if let sonnet = json["seven_day_sonnet"] as? [String: Any], let u = sonnet["utilization"] as? Double, u > 0 {
            modelLine += modelLine.count > 2 ? "  \u{00B7}  " : ""; modelLine += "Sonnet \(Int(u))%" }
        if modelLine.count > 2 { txt(modelLine, sz: 10, wt: .medium, cl: NSColor(white: 0.4, alpha: 1), menu: menu) }

        var infoLine = ""
        if let startStr = try? String(contentsOfFile: "\(home)/.claude/.weekly_start_pct", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let sp = Int(startStr) { let d = wp - sp; if d > 0 { infoLine += "+\(d)% today" } }
        if let vel = velocityTracker.velocityPerHour(current: wp) {
            infoLine += infoLine.isEmpty ? "" : "  \u{00B7}  "; infoLine += String(format: "%.1f%%/hr", vel) }
        if enableHaiku && haikuCallCount > 0 {
            let sep = infoLine.isEmpty ? "" : "  \u{00B7}  "
            infoLine += "\(sep)Monitor: \(haikuCallCount) calls" }
        if !infoLine.isEmpty { txt("  \(infoLine)", sz: 10, wt: .medium, cl: NSColor(white: 0.45, alpha: 1), menu: menu) }
    }

    private func bar(_ label: String, pct: Int, reset: String?, menu: NSMenu) {
        let bc = pct >= 80 ? coral : pct >= 50 ? amber : green; let f = min(pct * 16 / 100, 16)
        let b = String(repeating: "\u{2588}", count: f) + String(repeating: "\u{2591}", count: 16 - f)
        let r = NSMutableAttributedString()
        r.append(a("  \(label) ", sz: 11, wt: .semibold, cl: NSColor(white: 0.6, alpha: 1), mono: true))
        r.append(a(b, sz: 11, wt: .regular, cl: bc, mono: true)); r.append(a(" \(pct)%", sz: 11, wt: .bold, cl: bc, mono: true))
        if let rs = reset { r.append(a("  \u{21BB} \(rs)", sz: 10, wt: .medium, cl: NSColor(white: 0.5, alpha: 1), mono: true)) }
        item(r, menu: menu)
    }

    private func footer(_ menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        // Bulk compact
        let wc = sessions.filter { $0.state == "waiting" }.count
        if wc > 0 {
            let ca = NSMenuItem(title: "", action: #selector(compactAllAction), keyEquivalent: "")
            ca.target = self; ca.attributedTitle = a("  /compact all (\(wc) waiting)", sz: 12, wt: .bold, cl: waitingAmber)
            menu.addItem(ca)
        }

        // Export
        if !sessions.isEmpty {
            let ex = NSMenuItem(title: "", action: #selector(exportAction), keyEquivalent: "e")
            ex.target = self; ex.attributedTitle = a("  Export session summary", sz: 12, wt: .medium, cl: NSColor(white: 0.6, alpha: 1))
            menu.addItem(ex)
        }

        let r = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"); r.target = self; menu.addItem(r)

        let sm = NSMenu()
        addToggle(sm, "Waiting Alerts", notifyWaiting, #selector(toggleWaiting))
        addToggle(sm, "Context Warnings", notifyContext, #selector(toggleContext))
        addToggle(sm, "Notification Sounds", notifySound, #selector(toggleSound))
        addToggle(sm, "AI Names + Smart Context", enableHaiku, #selector(toggleHaiku))
        sm.addItem(NSMenuItem.separator())
        addToggle(sm, "Show Overlay Widget", showOverlay, #selector(toggleOverlay))
        addToggle(sm, "Compact Overlay", overlayCompact, #selector(toggleCompactOverlay))
        sm.addItem(NSMenuItem.separator())
        let isInstalled = FileManager.default.fileExists(atPath: "\(home)/Library/LaunchAgents/com.claude.monitor.plist")
        addToggle(sm, "Launch at Login", isInstalled, #selector(toggleAutoLaunch))
        let si = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""); si.submenu = sm; menu.addItem(si)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addToggle(_ menu: NSMenu, _ label: String, _ on: Bool, _ sel: Selector) {
        let i = NSMenuItem(title: on ? "\u{2713} \(label)" : "   \(label)", action: sel, keyEquivalent: "")
        i.target = self; menu.addItem(i)
    }

    @objc private func compactAllAction() { compactAllWaiting() }
    @objc private func exportAction() { exportSummary() }
    @objc private func toggleWaiting() { notifyWaiting.toggle(); build() }
    @objc private func toggleContext() { notifyContext.toggle(); build() }
    @objc private func toggleSound() { notifySound.toggle(); build() }
    @objc private func toggleHaiku() { enableHaiku.toggle(); build() }
    @objc private func toggleOverlay() { showOverlay.toggle(); updateOverlay(); build() }
    @objc private func toggleCompactOverlay() { overlayCompact.toggle(); overlayView.compact = overlayCompact; updateOverlay(); build() }

    @objc private func toggleAutoLaunch() {
        let pp = "\(home)/Library/LaunchAgents/com.claude.monitor.plist"; let fm = FileManager.default
        if fm.fileExists(atPath: pp) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["unload", pp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            try? fm.removeItem(atPath: pp); sendNotification(title: "Claude Monitor", body: "Removed from Login Items")
        } else {
            try? fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>com.claude.monitor</string><key>ProgramArguments</key><array><string>/usr/bin/open</string><string>\(home)/.claude/ClaudeMonitor.app</string></array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>"
            try? plist.write(toFile: pp, atomically: true, encoding: .utf8)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["load", pp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
            sendNotification(title: "Claude Monitor", body: "Will launch at login", sound: "Glass")
        }
        build()
    }

    private func a(_ s: String, sz: CGFloat, wt: NSFont.Weight, cl: NSColor, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: sz, weight: wt) : NSFont.systemFont(ofSize: sz, weight: wt), .foregroundColor: cl])
    }
    private func txt(_ s: String, sz: CGFloat, wt: NSFont.Weight, cl: NSColor, menu: NSMenu) { item(a(s, sz: sz, wt: wt, cl: cl), menu: menu) }
    private func item(_ attr: NSAttributedString, menu: NSMenu) {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: ""); i.attributedTitle = attr; i.isEnabled = false; menu.addItem(i) }
    private func fmtReset(_ s: String?) -> String? {
        guard let s, let d = iso(s) else { return nil }; let r = d.timeIntervalSinceNow; guard r > 0 else { return nil }
        return "\(Int(r)/3600)h\((Int(r)%3600)/60)m" }
    private func fmtDay(_ s: String?) -> String? { guard let s, let d = iso(s) else { return nil }; let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d) }
    private func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }() }
    @objc private func refresh() { scan(); build() }
}

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let d = Monitor(); app.delegate = d; app.run()
