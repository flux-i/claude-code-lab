// teams — one Swift binary that drives Microsoft Teams on macOS via the
// Accessibility API + deep links + NSPasteboard. No bash, no osascript.
//
// Usage:
//   teams read                          read the currently-open chat (no focus change)
//   teams read "<name-or-email>"         navigate to that chat, read it, restore focus
//   teams send "<recips>" "<message>"    text send (Teams briefly foregrounds, focus returns)
//   teams send --each "<recips>" "<m>"   broadcast a separate 1:1 to each
//   teams send "<recips>" "<m>" --attach <imagePath>   image attachment
//   teams send ... --dry                 prepare but do NOT press Send
//
// NOT headless. Any msteams: deep-link open makes Teams activate ITSELF (Chromium
// pulls its own window forward), so a send/navigate always brings Teams briefly to
// the front — `activates=false` only stops *us* from activating it, not Teams. We
// accept that and restore focus to the previously-active app afterwards (see
// restoreFocus). Text is injected via the deep-link &message= prefill when
// navigating (atomic, no per-key failures); if the target chat is already open the
// prefill is ignored, so we fall back to ⌘R + typed keystrokes. Send is AXPress on
// the Send button (falls back to Return). Attachments need the typed/paste path.
import AppKit
import ApplicationServices
import Foundation

// MARK: - AX
func axAttr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func axStr(_ el: AXUIElement, _ n: String) -> String { (axAttr(el, n) as? String) ?? "" }
func axPoint(_ el: AXUIElement) -> CGPoint { var p = CGPoint.zero
    if let v = axAttr(el, kAXPositionAttribute as String) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }; return p }
func axSize(_ el: AXUIElement) -> CGSize { var z = CGSize.zero
    if let v = axAttr(el, kAXSizeAttribute as String) { AXValueGetValue(v as! AXValue, .cgSize, &z) }; return z }
func axKids(_ el: AXUIElement) -> [AXUIElement] { (axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func collect(_ el: AXUIElement, max: Int = 80_000, _ pred: (AXUIElement, String) -> Bool, _ out: inout [AXUIElement], _ d: Int = 0) {
    if d > 60 || out.count > max { return }
    if pred(el, axStr(el, kAXRoleAttribute as String)) { out.append(el) }
    for k in axKids(el) { collect(k, max: max, pred, &out, d + 1) }
}

// MARK: - CGEvent keyboard (used only on the attachment / fallback path)
let VK_R: CGKeyCode = 15, VK_A: CGKeyCode = 0, VK_V: CGKeyCode = 9, VK_DEL: CGKeyCode = 51, VK_RET: CGKeyCode = 36
func tapKey(_ vk: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true); d?.flags = flags; d?.post(tap: .cghidEventTap)
    let u = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false); u?.flags = flags; u?.post(tap: .cghidEventTap)
    usleep(60_000)
}
func typeUnicode(_ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    var u16 = Array(text.utf16)
    let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
    d?.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16); d?.post(tap: .cghidEventTap)
    let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
    u?.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16); u?.post(tap: .cghidEventTap)
    usleep(80_000)
}

// MARK: - Teams app/window
func teamsApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").hasPrefix("Microsoft Teams") }
}
func waitForWindow(_ tries: Int = 28) -> (NSRunningApplication, AXUIElement, AXUIElement)? {
    for _ in 0..<tries {
        if let app = teamsApp() {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let wins = axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement], let w = wins.first {
                return (app, appEl, w)
            }
        }
        usleep(250_000)
    }
    return nil
}
func firstWindow(_ appEl: AXUIElement) -> AXUIElement? {
    (axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement])?.first
}
func composeValue(_ win: AXUIElement) -> String {
    var f: [AXUIElement] = []
    collect(win, { _, r in r == "AXTextArea" }, &f)
    return (f.first.map { axStr($0, kAXValueAttribute as String) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// Bring the user's previously-active app back to the front. Teams activates itself
// ASYNCHRONOUSLY (and repeatedly) after a deep-link open, and on modern macOS a bare
// activate() from a background CLI loses that race — so the user gets stranded in
// Teams. Fix: after a gentle first try, HIDE Teams, which forces the OS to yield the
// front to the previously-active app; then assert activation on it. Retry until it
// sticks. If the user was already in Teams, leave it alone.
func restoreFocus(_ app: NSRunningApplication?) {
    guard let app = app else { return }
    let teams = teamsApp()
    if let t = teams, t.processIdentifier == app.processIdentifier { return }
    usleep(450_000)                         // let Teams finish its own async self-activation
    for attempt in 0..<14 {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        if attempt >= 1 { teams?.hide() }   // hiding Teams reliably yields the front
        app.activate()
        usleep(160_000)
    }
}

// MARK: - Contacts
struct StrError: Error { let message: String }
func contactsPath() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("teams_contacts.txt").path
}
func allContactEmails() -> [String] {
    guard let data = try? String(contentsOfFile: contactsPath(), encoding: .utf8) else { return [] }
    var out: [String] = []
    for raw in data.split(separator: "\n") {
        var line = String(raw); if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let email = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if email.contains("@") { out.append(email) }
    }
    return out
}
func resolveEmail(_ input: String) -> Result<String, StrError> {
    let t = input.trimmingCharacters(in: .whitespaces)
    if t.contains("@") && t.contains(".") { return .success(t) }
    guard let data = try? String(contentsOfFile: contactsPath(), encoding: .utf8) else {
        return .failure(StrError(message: "No contacts file — pass a full email for \"\(input)\"."))
    }
    var hits: [(String, String)] = []
    for raw in data.split(separator: "\n") {
        var line = String(raw); if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let name = line[..<eq].trimmingCharacters(in: .whitespaces)
        let email = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if name.isEmpty || email.isEmpty { continue }
        if name.lowercased().contains(t.lowercased()) { hits.append((name, email)) }
    }
    if hits.isEmpty { return .failure(StrError(message: "No contact matching \"\(input)\".")) }
    if hits.count > 1 { return .failure(StrError(message: "\"\(input)\" is ambiguous: \(hits.map { $0.0 }.joined(separator: ", "))")) }
    return .success(hits[0].1)
}
func parseRecipients(_ s: String) -> [String] {
    s.replacingOccurrences(of: " and ", with: ",")
     .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - Navigation (background, no focus steal)
func openChat(_ emails: [String], message: String? = nil) {
    var u = "msteams:/l/chat/0/0?users=\(emails.joined(separator: ","))"
    if let m = message, let enc = m.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { u += "&message=\(enc)" }
    guard let url = URL(string: u) else { return }
    let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.open(url, configuration: cfg) { _, _ in sem.signal() }
    sem.wait()
}

// MARK: - Read
func readChat(from win: AXUIElement) -> String {
    let wp = axPoint(win), wz = axSize(win); let rightX = wp.x + wz.width * 0.34
    var items: [(CGFloat, String)] = []
    var texts: [AXUIElement] = []
    collect(win, { _, r in r == "AXStaticText" }, &texts)
    for el in texts {
        let v = axStr(el, kAXValueAttribute as String)
        if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        if axPoint(el).x >= rightX { items.append((axPoint(el).y, v)) }
    }
    items.sort { $0.0 < $1.0 }
    return items.map { $0.1 }.joined(separator: "\n")
}

// MARK: - Send
func findButton(_ win: AXUIElement, prefix: String) -> AXUIElement? {
    var hits: [AXUIElement] = []
    collect(win, { el, r in r == "AXButton" && (axStr(el, "AXDescription").hasPrefix(prefix) || axStr(el, kAXTitleAttribute as String).hasPrefix(prefix)) }, &hits)
    return hits.first
}
func pressSend(_ appEl: AXUIElement) -> Bool {
    guard let win = firstWindow(appEl), let send = findButton(win, prefix: "Send") else { return false }
    return AXUIElementPerformAction(send, kAXPressAction as CFString) == .success
}
func prefilled(_ appEl: AXUIElement, _ message: String) -> Bool {
    guard let win = firstWindow(appEl) else { return false }
    let needle = String(message.prefix(18))
    return composeValue(win).contains(needle)
}

// pasteImage — put a PNG on the pasteboard and ⌘V it into the focused compose box.
func pasteImage(_ path: String) -> Bool {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return false }
    let pb = NSPasteboard.general; pb.clearContents(); pb.setData(png, forType: .png)
    tapKey(VK_V, .maskCommand); usleep(1_500_000); return true
}

// One send. Text-only takes the fast prefill-on-navigation path; if the chat is
// already open (prefill ignored) or there's an attachment, it types/pastes into the
// now-foreground compose box. Teams comes briefly to the front either way — the CLI
// restores focus afterwards (restoreFocus).
func sendOne(_ emails: [String], message: String, attach: String?, dry: Bool) -> String {
    let who = emails.joined(separator: ", ")
    guard let (app, appEl, _) = waitForWindow() else { return "Teams window not found." }

    if attach == nil {
        openChat(emails, message: message); usleep(2_200_000)         // navigate + prefill (Teams foregrounds)
        if prefilled(appEl, message) {
            if dry { return "DRY: prefilled for \(who) — NOT sent." }
            _ = pressSend(appEl); usleep(400_000)
            return "Sent to \(who)."
        }
        // prefill ignored (chat already open) → fall through to the typing path
    } else {
        openChat(emails); usleep(1_200_000)
    }

    app.activate(); usleep(450_000)
    tapKey(VK_R, .maskCommand); usleep(300_000)
    tapKey(VK_A, .maskCommand); tapKey(VK_DEL); usleep(150_000)
    if !message.isEmpty { typeUnicode(message); usleep(300_000) }     // type FIRST (paste steals focus)
    if let path = attach, !pasteImage(path) { return "Could not load image: \(path)" }
    if dry { return "DRY: typed\(attach != nil ? " + attached" : "") for \(who) — NOT sent." }
    if !pressSend(appEl) { tapKey(VK_RET) }
    usleep(400_000)
    return "Sent to \(who)\(attach != nil ? " (with attachment)" : "")."
}

// MARK: - CLI
let argv = Array(CommandLine.arguments.dropFirst())
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }
guard let cmd = argv.first else { fail("usage: teams read|send …") }
let rest = Array(argv.dropFirst())
let prevApp = NSWorkspace.shared.frontmostApplication

switch cmd {
case "read":
    if let who = rest.first(where: { !$0.hasPrefix("--") }) {
        switch resolveEmail(who) { case .success(let e): openChat([e]); usleep(1_600_000)
                                   case .failure(let err): fail(err.message) }
    }
    guard let (_, _, win) = waitForWindow() else { fail("Teams window not found.") }
    usleep(700_000)
    print("CHAT: \(axStr(win, kAXTitleAttribute as String))")
    print(readChat(from: win))
    restoreFocus(prevApp)          // navigating to a chat foregrounds Teams; bring the user's app back

case "send":
    var each = false, dry = false, attach: String? = nil
    var positionals: [String] = []
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--each", "--broadcast": each = true
        case "--dry", "--dry-run":    dry = true
        case "--attach":              i += 1; if i < rest.count { attach = (rest[i] as NSString).expandingTildeInPath }
        default:                      positionals.append(rest[i])
        }
        i += 1
    }
    guard positionals.count >= 2 else { fail("usage: teams send [--each] [--dry] [--attach PATH] \"recipients\" \"message\"") }
    if let a = attach, !FileManager.default.fileExists(atPath: a) { fail("attachment not found: \(a)") }
    var emails: [String] = []
    for r in parseRecipients(positionals[0]) {
        switch resolveEmail(r) { case .success(let e): emails.append(e)
                                 case .failure(let err): fail("\(err.message) — aborting, nothing sent.") }
    }
    if emails.isEmpty { fail("No valid recipients.") }
    var report: [String] = []
    if each { for e in emails { report.append(sendOne([e], message: positionals[1], attach: attach, dry: dry)) } }
    else    { report.append(sendOne(emails, message: positionals[1], attach: attach, dry: dry)) }
    restoreFocus(prevApp)      // Teams foregrounds itself on nav; bring the user's app back
    print(report.joined(separator: "\n"))

default:
    fail("unknown command \"\(cmd)\" — use read or send.")
}
