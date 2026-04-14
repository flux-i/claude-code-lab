import Cocoa
import Foundation

// MARK: - Input Parsing

struct ToolInfo {
    let toolName: String
    let details: String
    let cwd: String
    let sessionId: String
    let rawInput: [String: Any]
}

func readInput() -> ToolInfo {
    // Read in chunks until we have valid JSON.
    // Cannot use readDataToEndOfFile() because Claude Code doesn't close stdin.
    var allData = Data()
    let handle = FileHandle.standardInput
    while true {
        let chunk = handle.readData(ofLength: 65536)
        if chunk.isEmpty { break }
        allData.append(chunk)
        if let _ = try? JSONSerialization.jsonObject(with: allData) as? [String: Any] {
            break
        }
    }
    guard !allData.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: allData) as? [String: Any] else {
        return ToolInfo(toolName: "Unknown", details: "", cwd: "", sessionId: "", rawInput: [:])
    }

    let toolName = json["tool_name"] as? String ?? "Unknown"
    let toolInput = json["tool_input"] as? [String: Any] ?? [:]
    let cwd = json["cwd"] as? String ?? ""
    let sessionId = json["session_id"] as? String ?? ""

    let details: String
    if let command = toolInput["command"] as? String {
        details = command
    } else if let filePath = toolInput["file_path"] as? String {
        var d = "File: \(filePath)"
        if let oldStr = toolInput["old_string"] as? String {
            let t = oldStr.count > 500 ? String(oldStr.prefix(500)) + "..." : oldStr
            d += "\n\nChanging:\n\(t)"
        }
        if let newStr = toolInput["new_string"] as? String {
            let t = newStr.count > 500 ? String(newStr.prefix(500)) + "..." : newStr
            d += "\n\nTo:\n\(t)"
        }
        if let content = toolInput["content"] as? String {
            let t = content.count > 500 ? String(content.prefix(500)) + "..." : content
            d += "\n\nContent:\n\(t)"
        }
        details = d
    } else if let jsonData = try? JSONSerialization.data(withJSONObject: toolInput, options: [.prettyPrinted]),
              let str = String(data: jsonData, encoding: .utf8) {
        details = str
    } else {
        details = ""
    }

    return ToolInfo(toolName: toolName, details: details, cwd: cwd, sessionId: sessionId, rawInput: toolInput)
}

// MARK: - Output

func writeAllow() {
    let json = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"# + "\n"
    let data = json.data(using: .utf8)!
    // Use POSIX write directly — FileHandle may buffer or interact oddly with NSApp
    data.withUnsafeBytes { buf in
        _ = Darwin.write(STDOUT_FILENO, buf.baseAddress!, buf.count)
    }
    close(STDOUT_FILENO)
    _exit(0)
}

func writeDeny(_ reason: String) {
    let escaped = reason.replacingOccurrences(of: "\"", with: "\\\"")
    let json = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":""# + escaped + #""}}}"# + "\n"
    let data = json.data(using: .utf8)!
    data.withUnsafeBytes { buf in
        _ = Darwin.write(STDOUT_FILENO, buf.baseAddress!, buf.count)
    }
    close(STDOUT_FILENO)
    _exit(0)
}

// MARK: - Always Allow

func updateSettingsForAlwaysAllow(info: ToolInfo) {
    let pattern: String
    if info.toolName == "Bash", let command = info.rawInput["command"] as? String {
        // Extract the base command (first word) and use wildcard, e.g. "ls *"
        let baseCommand = command.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? command
        pattern = "Bash(\(baseCommand) *)"
    } else if let filePath = info.rawInput["file_path"] as? String {
        // Use the directory as a wildcard pattern, e.g. "Edit(~/work/*)"
        let dir = (filePath as NSString).deletingLastPathComponent
        pattern = "\(info.toolName)(\(dir)/*)"
    } else {
        pattern = info.toolName
    }

    let settingsPath = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    let url = URL(fileURLWithPath: settingsPath)

    do {
        var settings: [String: Any]
        if FileManager.default.fileExists(atPath: settingsPath),
           let data = try? Data(contentsOf: url),
           let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        } else {
            settings = [:]
        }

        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allowList = permissions["allow"] as? [String] ?? []

        if !allowList.contains(pattern) {
            allowList.append(pattern)
            permissions["allow"] = allowList
            settings["permissions"] = permissions
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
        }
    } catch {}
}

// MARK: - iTerm2 color reading

struct Theme {
    let bg: NSColor
    let codeBg: NSColor
    let btnBg: NSColor
    let border: NSColor
    let text: NSColor
    let dimText: NSColor
    let codeText: NSColor
    let green: NSColor
    let blue: NSColor
    let red: NSColor

    static func fromITerm2() -> Theme {
        guard let defaults = UserDefaults(suiteName: "com.googlecode.iterm2"),
              let bookmarks = defaults.array(forKey: "New Bookmarks") as? [[String: Any]] else {
            return fallback()
        }

        // Find the default profile by Guid
        let defaultGuid = defaults.string(forKey: "Default Bookmark Guid")
        let profile: [String: Any]
        if let guid = defaultGuid,
           let found = bookmarks.first(where: { ($0["Guid"] as? String) == guid }) {
            profile = found
        } else if let first = bookmarks.first {
            profile = first
        } else {
            return fallback()
        }

        func extractColor(_ name: String) -> NSColor? {
            guard let dict = profile[name] as? [String: Any] else { return nil }
            func val(_ key: String) -> CGFloat? {
                if let n = dict[key] as? NSNumber { return CGFloat(n.doubleValue) }
                if let s = dict[key] as? String, let d = Double(s) { return CGFloat(d) }
                return nil
            }
            guard let r = val("Red Component"),
                  let g = val("Green Component"),
                  let b = val("Blue Component") else { return nil }
            let a = val("Alpha Component") ?? 1.0
            let space = dict["Color Space"] as? String ?? "sRGB"

            if space == "P3" {
                return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
            }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }

        let bg = extractColor("Background Color") ?? NSColor(srgbRed: 0.08, green: 0.10, blue: 0.12, alpha: 1)
        let fg = extractColor("Foreground Color") ?? NSColor(srgbRed: 0.94, green: 0.94, blue: 0.92, alpha: 1)
        let ansiRed = extractColor("Ansi 1 Color") ?? NSColor.systemRed
        let ansiGreen = extractColor("Ansi 2 Color") ?? NSColor.systemGreen
        let ansiBlue = extractColor("Ansi 4 Color") ?? NSColor.systemBlue

        return Theme(
            bg: bg,
            codeBg: blend(bg, with: fg, amount: 0.06),
            btnBg: blend(bg, with: fg, amount: 0.08),
            border: blend(bg, with: fg, amount: 0.15),
            text: fg,
            dimText: blend(bg, with: fg, amount: 0.40),
            codeText: blend(bg, with: fg, amount: 0.75),
            green: ansiGreen,
            blue: ansiBlue,
            red: ansiRed
        )
    }

    static func fallback() -> Theme {
        let bg  = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.12, alpha: 1)
        let fg  = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.92, alpha: 1)
        return Theme(
            bg: bg,
            codeBg: blend(bg, with: fg, amount: 0.06),
            btnBg: blend(bg, with: fg, amount: 0.08),
            border: blend(bg, with: fg, amount: 0.15),
            text: fg,
            dimText: blend(bg, with: fg, amount: 0.40),
            codeText: blend(bg, with: fg, amount: 0.75),
            green: NSColor(srgbRed: 0.35, green: 0.97, blue: 0.56, alpha: 1),
            blue: NSColor(srgbRed: 0.34, green: 0.78, blue: 1.0, alpha: 1),
            red: NSColor(srgbRed: 1.0, green: 0.36, blue: 0.34, alpha: 1)
        )
    }

    static func blend(_ c1: NSColor, with c2: NSColor, amount: CGFloat) -> NSColor {
        let a = c1.usingColorSpace(.sRGB) ?? c1
        let b = c2.usingColorSpace(.sRGB) ?? c2
        let r = a.redComponent + (b.redComponent - a.redComponent) * amount
        let g = a.greenComponent + (b.greenComponent - a.greenComponent) * amount
        let bl = a.blueComponent + (b.blueComponent - a.blueComponent) * amount
        return NSColor(srgbRed: r, green: g, blue: bl, alpha: 1.0)
    }
}

// MARK: - Custom Panel

class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Clickable view

class ClickableView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Popup Controller

class PopupController: NSObject, NSWindowDelegate {
    let info: ToolInfo
    let theme: Theme
    var panel: PermissionPanel!
    var buttonViews: [NSView] = []
    var buttonLabels: [NSTextField] = []
    var selectedIndex = 0
    var result = "deny"
    var resolved = false
    var timeoutTimer: Timer?
    var eventMonitor: Any?

    let actions = ["allow", "always_allow", "deny"]
    let buttonTitles = ["Allow", "Always Allow", "Deny"]

    init(info: ToolInfo, theme: Theme) {
        self.info = info
        self.theme = theme
        super.init()
    }

    func show() -> String {
        buildPanel()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        NSSound(named: "Purr")?.play()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleKey(event) { return nil }
            return event
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.finishWith("deny")
        }

        NSApp.runModal(for: panel)

        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        timeoutTimer?.invalidate()
        return result
    }

    func buildPanel() {
        let w: CGFloat = 620
        let h: CGFloat = 420

        panel = PermissionPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Claude Code"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = theme.bg
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let cv = panel.contentView!
        cv.wantsLayer = true
        cv.layer?.backgroundColor = theme.bg.cgColor

        let m: CGFloat = 16
        var y = h - 6

        // Project path
        if !info.cwd.isEmpty {
            y -= 16
            let pathLabel = NSTextField(labelWithString: info.cwd)
            pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            pathLabel.textColor = theme.dimText
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.frame = NSRect(x: m, y: y, width: w - m * 2, height: 14)
            cv.addSubview(pathLabel)
        }

        y -= 8

        // Command box - takes most of the space
        if !info.details.isEmpty {
            let btnArea: CGFloat = 52  // buttons + bottom margin
            let boxH: CGFloat = y - btnArea
            y -= boxH

            let boxView = NSView(frame: NSRect(x: m, y: y, width: w - m * 2, height: boxH))
            boxView.wantsLayer = true
            boxView.layer?.backgroundColor = theme.codeBg.cgColor
            boxView.layer?.cornerRadius = 8
            boxView.layer?.borderWidth = 1
            boxView.layer?.borderColor = theme.border.cgColor
            cv.addSubview(boxView)

            let scrollView = NSScrollView(frame: NSRect(x: 1, y: 1, width: boxView.frame.width - 2, height: boxView.frame.height - 2))
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.scrollerStyle = .overlay

            let cs = scrollView.contentSize
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: cs.width, height: cs.height))
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            tv.textColor = theme.codeText
            tv.string = info.details
            tv.textContainerInset = NSSize(width: 10, height: 10)
            tv.isVerticallyResizable = true
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.textContainer?.containerSize = NSSize(width: cs.width - 20, height: CGFloat.greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = true

            scrollView.documentView = tv
            boxView.addSubview(scrollView)

            y -= 8
        }

        // Buttons
        let btnW: CGFloat = 150
        let btnH: CGFloat = 34
        let spacing: CGFloat = 10
        let totalW = CGFloat(buttonTitles.count) * btnW + CGFloat(buttonTitles.count - 1) * spacing
        let startX = (w - totalW) / 2
        y -= btnH

        for (i, title) in buttonTitles.enumerated() {
            let x = startX + CGFloat(i) * (btnW + spacing)

            let btnView = NSView(frame: NSRect(x: x, y: y, width: btnW, height: btnH))
            btnView.wantsLayer = true
            btnView.layer?.cornerRadius = 8
            btnView.layer?.backgroundColor = theme.btnBg.cgColor
            btnView.layer?.borderWidth = 1.5
            btnView.layer?.borderColor = theme.border.cgColor
            cv.addSubview(btnView)
            buttonViews.append(btnView)

            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = theme.text
            label.alignment = .center
            label.frame = NSRect(x: 0, y: (btnH - 16) / 2, width: btnW, height: 16)
            btnView.addSubview(label)
            buttonLabels.append(label)

            let clickArea = ClickableView(frame: NSRect(x: 0, y: 0, width: btnW, height: btnH))
            clickArea.onClick = { [weak self] in self?.finishWith(self?.actions[i] ?? "deny") }
            btnView.addSubview(clickArea)
        }

        updateSelection()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "\r": finishWith(actions[selectedIndex]); return true
            case "\u{1b}": finishWith("deny"); return true
            default: break
            }
        }

        switch event.keyCode {
        case 123: // Left
            selectedIndex = (selectedIndex - 1 + buttonViews.count) % buttonViews.count
            updateSelection()
            return true
        case 124: // Right
            selectedIndex = (selectedIndex + 1) % buttonViews.count
            updateSelection()
            return true
        default: break
        }

        return false
    }

    func updateSelection() {
        let colors = [theme.green, theme.blue, theme.red]
        for (i, view) in buttonViews.enumerated() {
            if i == selectedIndex {
                view.layer?.borderColor = colors[i].cgColor
                view.layer?.borderWidth = 2
                view.layer?.backgroundColor = colors[i].withAlphaComponent(0.12).cgColor
                buttonLabels[i].textColor = colors[i]
            } else {
                view.layer?.borderColor = theme.border.cgColor
                view.layer?.borderWidth = 1.5
                view.layer?.backgroundColor = theme.btnBg.cgColor
                buttonLabels[i].textColor = theme.text
            }
        }
    }

    func finishWith(_ action: String) {
        resolved = true
        result = action
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !resolved {
            result = "deny"
            NSApp.stopModal()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let info: ToolInfo

    init(info: ToolInfo) {
        self.info = info
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let theme = Theme.fromITerm2()
        let controller = PopupController(info: info, theme: theme)
        let action = controller.show()

        switch action {
        case "allow":
            writeAllow()
        case "always_allow":
            updateSettingsForAlwaysAllow(info: info)
            writeAllow()  // _exit(0) - won't return
        case "deny":
            writeDeny("User denied via popup")
        default:
            writeDeny("Popup dismissed")
        }

        _exit(1)  // fallback - should never reach here
    }
}

// MARK: - Allow List Check

func isAlreadyAllowed(info: ToolInfo) -> Bool {
    // Read allow lists from both global and project settings
    let settingsPaths = [
        NSString(string: "~/.claude/settings.json").expandingTildeInPath,
        NSString(string: "~/.claude/settings.local.json").expandingTildeInPath,
        (info.cwd as NSString).appendingPathComponent(".claude/settings.json"),
        (info.cwd as NSString).appendingPathComponent(".claude/settings.local.json")
    ]

    var allowPatterns: [String] = []
    for path in settingsPaths {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any],
              let allow = permissions["allow"] as? [String] else { continue }
        allowPatterns.append(contentsOf: allow)
    }

    let toolName = info.toolName
    let command = info.rawInput["command"] as? String
    let filePath = info.rawInput["file_path"] as? String

    for pattern in allowPatterns {
        // Exact tool name match (e.g. "Bash", "Edit", "Write")
        if pattern == toolName { return true }

        // Pattern with argument, e.g. "Bash(ls *)" or "Edit(/some/path/*)"
        guard pattern.hasPrefix("\(toolName)(") && pattern.hasSuffix(")") else { continue }
        let inner = String(pattern.dropFirst(toolName.count + 1).dropLast())

        if toolName == "Bash", let command = command {
            if matchesWildcard(string: command, pattern: inner) { return true }
            // Claude Code uses colon format: "command:*" means "command <anything>"
            // Convert "git:*" → "git *" and retry
            if inner.contains(":") {
                let converted = inner.replacingOccurrences(of: ":", with: " ")
                if matchesWildcard(string: command, pattern: converted) { return true }
            }
        } else if let filePath = filePath {
            if matchesWildcard(string: filePath, pattern: inner) { return true }
        }
    }

    return false
}

func matchesWildcard(string: String, pattern: String) -> Bool {
    // Simple wildcard matching: * matches any sequence of characters
    // Split pattern by * and check if parts appear in order
    let parts = pattern.components(separatedBy: "*")
    if parts.count == 1 { return string == pattern }

    var remaining = string[string.startIndex...]
    for (i, part) in parts.enumerated() {
        if part.isEmpty { continue }
        if i == 0 {
            // First part must be a prefix
            guard remaining.hasPrefix(part) else { return false }
            remaining = remaining.dropFirst(part.count)
        } else if i == parts.count - 1 {
            // Last part must be a suffix
            guard remaining.hasSuffix(part) else { return false }
            remaining = remaining[remaining.endIndex...]
        } else {
            guard let range = remaining.range(of: part) else { return false }
            remaining = remaining[range.upperBound...]
        }
    }
    return true
}

// MARK: - Main

let info = readInput()

// Skip popup if already allowed by settings
if isAlreadyAllowed(info: info) {
    writeAllow()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(info: info)
app.delegate = delegate
app.run()
