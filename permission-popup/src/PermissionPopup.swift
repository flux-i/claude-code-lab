import Cocoa
import Foundation

// MARK: - Input Parsing

enum ClientKind {
    case claude
    case codex

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

struct ToolInfo {
    let client: ClientKind
    let toolName: String
    let details: String
    let cwd: String
    let sessionId: String
    let rawInput: [String: Any]
}

func readInput() -> ToolInfo {
    // Read in chunks until we have valid JSON.
    // Cannot use readDataToEndOfFile() because some hook runners don't close stdin.
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
        return ToolInfo(client: detectClient(from: [:]), toolName: "Unknown", details: "", cwd: "", sessionId: "", rawInput: [:])
    }

    let client = detectClient(from: json)
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

    return ToolInfo(client: client, toolName: toolName, details: details, cwd: cwd, sessionId: sessionId, rawInput: toolInput)
}

func detectClient(from json: [String: Any]) -> ClientKind {
    let forced = ProcessInfo.processInfo.environment["PERMISSION_POPUP_CLIENT"]?.lowercased()
    if forced == "codex" { return .codex }
    if forced == "claude" { return .claude }

    if json["hook_event_name"] != nil || json["turn_id"] != nil || json["transcript_path"] != nil {
        return .codex
    }

    return .claude
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    if path == "~" { return home }
    return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
}

// MARK: - AskUserQuestion model

struct QOption {
    let label: String
    let description: String
}

struct Question {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [QOption]
}

func parseQuestions(from toolInput: [String: Any]) -> [Question] {
    guard let raw = toolInput["questions"] as? [[String: Any]] else { return [] }
    return raw.map { q in
        let opts = (q["options"] as? [[String: Any]] ?? []).map { o in
            QOption(label: o["label"] as? String ?? "",
                    description: o["description"] as? String ?? "")
        }
        return Question(
            question: q["question"] as? String ?? "",
            header: q["header"] as? String ?? "",
            multiSelect: q["multiSelect"] as? Bool ?? false,
            options: opts
        )
    }
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

// Deny with an arbitrary message. Built via JSONSerialization so multi-line
// messages (e.g. answers to AskUserQuestion) are escaped correctly.
func writeDenyMessage(_ message: String) {
    let payload: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny", "message": message]
        ]
    ]
    if var data = try? JSONSerialization.data(withJSONObject: payload) {
        data.append(0x0A)
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress { _ = Darwin.write(STDOUT_FILENO, base, buf.count) }
        }
    }
    close(STDOUT_FILENO)
    _exit(0)
}

// MARK: - Always Allow

func updateAlwaysAllow(info: ToolInfo) {
    switch info.client {
    case .claude:
        updateClaudeSettingsForAlwaysAllow(info: info)
    case .codex:
        updateCodexAllowListForAlwaysAllow(info: info)
    }
}

func updateClaudeSettingsForAlwaysAllow(info: ToolInfo) {
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

    let settingsPath = expandHome("~/.claude/settings.json")
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

func updateCodexAllowListForAlwaysAllow(info: ToolInfo) {
    let pattern = allowPattern(for: info)
    let allowPath = expandHome("~/.codex/permission-popup-allow.json")
    let allowURL = URL(fileURLWithPath: allowPath)

    do {
        let dir = (allowPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var allowList: [String] = []
        if FileManager.default.fileExists(atPath: allowPath),
           let data = try? Data(contentsOf: allowURL),
           let existing = try JSONSerialization.jsonObject(with: data) as? [String] {
            allowList = existing
        }

        if !allowList.contains(pattern) {
            allowList.append(pattern)
            let data = try JSONSerialization.data(withJSONObject: allowList, options: [.prettyPrinted])
            try data.write(to: allowURL, options: .atomic)
        }

        updateCodexRulesForAlwaysAllow(info: info)
    } catch {}
}

func updateCodexRulesForAlwaysAllow(info: ToolInfo) {
    guard info.toolName == "Bash",
          let command = info.rawInput["command"] as? String,
          let baseCommand = shellCommandPrefix(command).first else {
        return
    }

    let rulesPath = expandHome("~/.codex/rules/default.rules")
    let rulesURL = URL(fileURLWithPath: rulesPath)

    do {
        let dir = (rulesPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let patternJSON = jsonString(["\(baseCommand)"])
        let rule = #"prefix_rule(pattern=\#(patternJSON), decision="allow")"#
        let existing = (try? String(contentsOf: rulesURL, encoding: .utf8)) ?? ""

        if !existing.contains(rule) {
            let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try (existing + prefix + rule + "\n").write(to: rulesURL, atomically: true, encoding: .utf8)
        }
    } catch {}
}

func allowPattern(for info: ToolInfo) -> String {
    if info.toolName == "Bash",
       let command = info.rawInput["command"] as? String,
       let baseCommand = shellCommandPrefix(command).first {
        return "Bash(\(baseCommand) *)"
    } else if let filePath = info.rawInput["file_path"] as? String {
        let dir = (filePath as NSString).deletingLastPathComponent
        return "\(info.toolName)(\(dir)/*)"
    } else {
        return info.toolName
    }
}

func shellCommandPrefix(_ command: String) -> [String] {
    let tokens = shellTokens(command)
    let skippedAssignments = tokens.drop(while: { token in
        token.contains("=") && !token.hasPrefix("/") && !token.hasPrefix("./") && !token.hasPrefix("../")
    })
    return Array(skippedAssignments.prefix(1))
}

func shellTokens(_ command: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false

    for char in command {
        if escaping {
            current.append(char)
            escaping = false
            continue
        }

        if char == "\\" {
            escaping = true
            continue
        }

        if let q = quote {
            if char == q {
                quote = nil
            } else {
                current.append(char)
            }
            continue
        }

        if char == "'" || char == "\"" {
            quote = char
        } else if char.isWhitespace {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        } else if char == ";" || char == "|" || char == "&" {
            break
        } else {
            current.append(char)
        }
    }

    if !current.isEmpty {
        tokens.append(current)
    }

    return tokens
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return string
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

        focusPanel()
        DispatchQueue.main.async { [weak self] in
            self?.focusPanel()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusPanel()
        }
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

    func focusPanel() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
        panel.makeFirstResponder(panel.contentView)
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
        panel.title = info.client.title
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

        let btnW: CGFloat = 150
        let btnH: CGFloat = 34

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
            updateAlwaysAllow(info: info)
            writeAllow()  // _exit(0) - won't return
        case "deny":
            writeDeny("User denied via popup")
        default:
            writeDeny("Popup dismissed")
        }

        _exit(1)  // fallback - should never reach here
    }
}

// MARK: - Question Popup (AskUserQuestion)

enum QuestionOutcome {
    case answered(String)   // deny + message carrying the user's choices
    case terminal           // allow -> let Claude Code show its native question UI
    case dismissed          // deny + "no answer" message
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// A selectable option row. Flipped so its subviews lay out top-down.
class QuestionRowView: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

class QuestionPopupController: NSObject, NSWindowDelegate {
    let info: ToolInfo
    let questions: [Question]
    let theme: Theme

    var panel: PermissionPanel!
    var scrollView: NSScrollView!

    // Flat list of option rows across all questions, for keyboard navigation.
    var rowViews: [QuestionRowView] = []
    var rowMarkers: [NSTextField] = []
    var rowLabels: [NSTextField] = []
    var rowMap: [(q: Int, o: Int)] = []
    var selections: [Set<Int>] = []   // selected option indices, per question
    var focusedRow = 0

    var outcome: QuestionOutcome = .dismissed
    var resolved = false
    var timeoutTimer: Timer?
    var eventMonitor: Any?

    init(info: ToolInfo, questions: [Question], theme: Theme) {
        self.info = info
        self.questions = questions
        self.theme = theme
        self.selections = Array(repeating: Set<Int>(), count: questions.count)
        super.init()
    }

    func show() -> QuestionOutcome {
        buildPanel()

        focusPanel()
        DispatchQueue.main.async { [weak self] in self?.focusPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.focusPanel() }
        NSSound(named: "Purr")?.play()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleKey(event) { return nil }
            return event
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.finish(.dismissed)
        }

        NSApp.runModal(for: panel)

        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        timeoutTimer?.invalidate()
        return outcome
    }

    func focusPanel() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
        panel.makeFirstResponder(panel.contentView)
    }

    func makeWrap(_ s: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = font
        f.textColor = color
        f.isSelectable = false
        f.drawsBackground = false
        f.isBezeled = false
        f.preferredMaxLayoutWidth = width
        var fr = f.frame
        fr.size.width = width
        fr.size.height = f.fittingSize.height
        f.frame = fr
        return f
    }

    func buildPanel() {
        let w: CGFloat = 640
        let sideMargin: CGFloat = 16
        let innerWidth = w - sideMargin * 2     // documentView width
        let textLeft: CGFloat = 8
        let textWidth = innerWidth - textLeft * 2
        let markerW: CGFloat = 18
        let optTextLeft: CGFloat = 34
        let optTextWidth = innerWidth - optTextLeft - 12

        // --- Build the (flipped) document view, measuring as we stack ---
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: innerWidth, height: 10))
        var y: CGFloat = 14

        for (qi, q) in questions.enumerated() {
            if !q.header.isEmpty {
                let hl = NSTextField(labelWithString: q.header.uppercased())
                hl.font = .systemFont(ofSize: 10, weight: .semibold)
                hl.textColor = theme.blue
                hl.frame = NSRect(x: textLeft, y: y, width: textWidth, height: 13)
                doc.addSubview(hl)
                y += 16
            }

            let ql = makeWrap(q.question, font: .systemFont(ofSize: 15, weight: .semibold),
                              color: theme.text, width: textWidth)
            ql.frame.origin = CGPoint(x: textLeft, y: y)
            doc.addSubview(ql)
            y += ql.frame.height + 8

            for (oi, opt) in q.options.enumerated() {
                let labelField = makeWrap(opt.label, font: .systemFont(ofSize: 13, weight: .medium),
                                          color: theme.text, width: optTextWidth)
                let descField = opt.description.isEmpty ? nil
                    : makeWrap(opt.description, font: .systemFont(ofSize: 11.5, weight: .regular),
                               color: theme.dimText, width: optTextWidth)

                let rowTop: CGFloat = 8
                let lh = labelField.frame.height
                let dh = descField?.frame.height ?? 0
                let gap: CGFloat = descField == nil ? 0 : 3
                let rowH = rowTop + lh + gap + dh + 8

                let row = QuestionRowView(frame: NSRect(x: textLeft, y: y, width: textWidth, height: rowH))
                row.wantsLayer = true
                row.layer?.cornerRadius = 7
                row.layer?.borderWidth = 1.5
                row.layer?.borderColor = theme.border.cgColor
                row.layer?.backgroundColor = theme.btnBg.cgColor

                let marker = NSTextField(labelWithString: "")
                marker.font = .systemFont(ofSize: 13, weight: .regular)
                marker.alignment = .center
                marker.frame = NSRect(x: 8, y: rowTop, width: markerW, height: 16)
                row.addSubview(marker)

                labelField.frame.origin = CGPoint(x: optTextLeft, y: rowTop)
                row.addSubview(labelField)
                if let descField = descField {
                    descField.frame.origin = CGPoint(x: optTextLeft, y: rowTop + lh + gap)
                    row.addSubview(descField)
                }

                let flat = rowViews.count
                row.onClick = { [weak self] in self?.clickRow(flat) }
                doc.addSubview(row)

                rowViews.append(row)
                rowMarkers.append(marker)
                rowLabels.append(labelField)
                rowMap.append((qi, oi))

                y += rowH + 6
            }

            y += 12  // gap between questions
        }

        let contentHeight = y

        // --- Window geometry ---
        let pathH: CGFloat = info.cwd.isEmpty ? 10 : 30
        let footerBottom: CGFloat = 14
        let buttonH: CGFloat = 34
        let footerH: CGFloat = 82
        let maxScroll: CGFloat = 520
        let scrollH = max(min(contentHeight, maxScroll), 80)
        let h = pathH + scrollH + footerH

        panel = PermissionPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = info.client.title
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

        // Project path
        if !info.cwd.isEmpty {
            let pathLabel = NSTextField(labelWithString: info.cwd)
            pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            pathLabel.textColor = theme.dimText
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.frame = NSRect(x: sideMargin, y: h - 24, width: w - sideMargin * 2, height: 14)
            cv.addSubview(pathLabel)
        }

        // Scrollable questions
        scrollView = NSScrollView(frame: NSRect(x: sideMargin, y: footerH, width: innerWidth, height: h - pathH - footerH))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        doc.frame = NSRect(x: 0, y: 0, width: innerWidth, height: contentHeight)
        scrollView.documentView = doc
        cv.addSubview(scrollView)
        doc.scroll(NSPoint(x: 0, y: 0))

        // Footer buttons
        let footerTitles = ["Submit", "Answer in terminal"]
        let footerColors = [theme.green, theme.blue]
        let footerWidths: [CGFloat] = [150, 200]
        let spacing: CGFloat = 12
        let totalFW = footerWidths.reduce(0, +) + spacing * CGFloat(footerWidths.count - 1)
        var fx = (w - totalFW) / 2

        for i in 0..<footerTitles.count {
            let bw = footerWidths[i]
            let bv = NSView(frame: NSRect(x: fx, y: footerBottom, width: bw, height: buttonH))
            bv.wantsLayer = true
            bv.layer?.cornerRadius = 8
            bv.layer?.backgroundColor = footerColors[i].withAlphaComponent(0.12).cgColor
            bv.layer?.borderWidth = 1.5
            bv.layer?.borderColor = footerColors[i].cgColor
            cv.addSubview(bv)

            let lbl = NSTextField(labelWithString: footerTitles[i])
            lbl.font = .systemFont(ofSize: 13, weight: .semibold)
            lbl.textColor = footerColors[i]
            lbl.alignment = .center
            lbl.frame = NSRect(x: 0, y: (buttonH - 16) / 2, width: bw, height: 16)
            bv.addSubview(lbl)

            let click = ClickableView(frame: NSRect(x: 0, y: 0, width: bw, height: buttonH))
            if i == 0 {
                click.onClick = { [weak self] in self?.submit() }
            } else {
                click.onClick = { [weak self] in self?.finish(.terminal) }
            }
            bv.addSubview(click)

            fx += bw + spacing
        }

        // Keyboard hint
        let hint = NSTextField(labelWithString: "↑↓ navigate · space select · ⏎ submit · ⌘⏎ terminal · esc cancel")
        hint.font = .systemFont(ofSize: 10.5, weight: .regular)
        hint.textColor = theme.dimText
        hint.alignment = .center
        hint.frame = NSRect(x: sideMargin, y: footerBottom + buttonH + 6, width: w - sideMargin * 2, height: 14)
        cv.addSubview(hint)

        refresh()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        if let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "\r":
                if cmd { finish(.terminal) } else { submit() }
                return true
            case "\u{1b}": finish(.dismissed); return true
            case " ": toggleSelection(focusedRow); refresh(); return true
            case "j": move(1); return true
            case "k": move(-1); return true
            default: break
            }
        }

        switch event.keyCode {
        case 125: move(1); return true   // Down
        case 126: move(-1); return true  // Up
        default: break
        }

        return false
    }

    func move(_ delta: Int) {
        guard !rowViews.isEmpty else { return }
        focusedRow = (focusedRow + delta + rowViews.count) % rowViews.count
        refresh()
        let r = rowViews[focusedRow]
        r.scrollToVisible(r.bounds)
    }

    func clickRow(_ i: Int) {
        focusedRow = i
        toggleSelection(i)
        refresh()
    }

    func toggleSelection(_ i: Int) {
        guard i >= 0 && i < rowMap.count else { return }
        let (qi, oi) = rowMap[i]
        if questions[qi].multiSelect {
            if selections[qi].contains(oi) { selections[qi].remove(oi) }
            else { selections[qi].insert(oi) }
        } else {
            selections[qi] = [oi]
        }
    }

    func refresh() {
        let accent = theme.green
        for (i, row) in rowViews.enumerated() {
            let (qi, oi) = rowMap[i]
            let selected = selections[qi].contains(oi)
            let multi = questions[qi].multiSelect
            rowMarkers[i].stringValue = selected ? (multi ? "☑" : "●") : (multi ? "☐" : "○")
            rowMarkers[i].textColor = selected ? accent : theme.dimText
            rowLabels[i].textColor = selected ? accent : theme.text

            if i == focusedRow {
                row.layer?.borderColor = accent.cgColor
                row.layer?.borderWidth = 2
                row.layer?.backgroundColor = accent.withAlphaComponent(selected ? 0.16 : 0.08).cgColor
            } else if selected {
                row.layer?.borderColor = accent.withAlphaComponent(0.6).cgColor
                row.layer?.borderWidth = 1.5
                row.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
            } else {
                row.layer?.borderColor = theme.border.cgColor
                row.layer?.borderWidth = 1.5
                row.layer?.backgroundColor = theme.btnBg.cgColor
            }
        }
    }

    func buildAnswerMessage() -> String {
        var lines: [String] = ["The user answered the following via the popup dialog. Use these as their responses:"]
        for (qi, q) in questions.enumerated() {
            let chosen = selections[qi].sorted().map { q.options[$0].label }
            lines.append("")
            let head = q.header.isEmpty ? "" : "[\(q.header)] "
            lines.append("Q: \(head)\(q.question)")
            lines.append("A: " + (chosen.isEmpty ? "(no selection)" : chosen.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    func submit() {
        finish(.answered(buildAnswerMessage()))
    }

    func finish(_ o: QuestionOutcome) {
        resolved = true
        outcome = o
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !resolved {
            outcome = .dismissed
            NSApp.stopModal()
        }
    }
}

class QuestionAppDelegate: NSObject, NSApplicationDelegate {
    let info: ToolInfo
    let questions: [Question]

    init(info: ToolInfo, questions: [Question]) {
        self.info = info
        self.questions = questions
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let theme = Theme.fromITerm2()
        let controller = QuestionPopupController(info: info, questions: questions, theme: theme)
        let outcome = controller.show()

        switch outcome {
        case .answered(let message):
            writeDenyMessage(message)        // _exit(0) - won't return
        case .terminal:
            writeAllow()                     // let Claude Code show its native question UI
        case .dismissed:
            writeDenyMessage("The user closed the popup without answering the question.")
        }

        _exit(1)  // fallback - should never reach here
    }
}

// MARK: - Allow List Check

func isAlreadyAllowed(info: ToolInfo) -> Bool {
    switch info.client {
    case .claude:
        return isAlreadyAllowedByClaudeSettings(info: info)
    case .codex:
        return isAlreadyAllowedByCodexSettings(info: info)
    }
}

func isAlreadyAllowedByClaudeSettings(info: ToolInfo) -> Bool {
    // Read allow lists from both global and project settings
    let settingsPaths = [
        expandHome("~/.claude/settings.json"),
        expandHome("~/.claude/settings.local.json"),
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

func isAlreadyAllowedByCodexSettings(info: ToolInfo) -> Bool {
    let allowPath = expandHome("~/.codex/permission-popup-allow.json")
    guard FileManager.default.fileExists(atPath: allowPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: allowPath)),
          let allowPatterns = try? JSONSerialization.jsonObject(with: data) as? [String] else {
        return false
    }

    return allowPatterns.contains { pattern in
        matchesPermissionPattern(info: info, pattern: pattern)
    }
}

func matchesPermissionPattern(info: ToolInfo, pattern: String) -> Bool {
    let toolName = info.toolName
    let command = info.rawInput["command"] as? String
    let filePath = info.rawInput["file_path"] as? String

    if pattern == toolName { return true }

    guard pattern.hasPrefix("\(toolName)(") && pattern.hasSuffix(")") else { return false }
    let inner = String(pattern.dropFirst(toolName.count + 1).dropLast())

    if toolName == "Bash", let command = command {
        return matchesWildcard(string: command, pattern: inner)
    } else if let filePath = filePath {
        return matchesWildcard(string: filePath, pattern: inner)
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

// AskUserQuestion is rendered as an interactive question popup instead of an
// allow/deny prompt. The chosen answers are returned to Claude via deny+message.
let parsedQuestions = parseQuestions(from: info.rawInput)
let isQuestion = info.toolName == "AskUserQuestion" && !parsedQuestions.isEmpty

// Skip popup if already allowed by settings (never auto-skip a question).
if !isQuestion && isAlreadyAllowed(info: info) {
    writeAllow()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate: NSApplicationDelegate = isQuestion
    ? QuestionAppDelegate(info: info, questions: parsedQuestions)
    : AppDelegate(info: info)
app.delegate = delegate
app.run()
