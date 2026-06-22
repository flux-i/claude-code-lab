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
let VK_A: CGKeyCode = 0, VK_V: CGKeyCode = 9, VK_DEL: CGKeyCode = 51, VK_RET: CGKeyCode = 36
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
// True for ANY Teams process — the main app AND its helpers (WebView, Notification
// Center). New Teams runs ~5 of them, all named "Microsoft Teams …"; whichever owns the
// front window varies, so focus logic must treat them all as "Teams is up front".
func isTeamsApp(_ a: NSRunningApplication?) -> Bool {
    guard let a = a else { return false }
    return (a.bundleIdentifier ?? "").hasPrefix("com.microsoft.teams")
        || (a.localizedName ?? "").hasPrefix("Microsoft Teams")
}
// The MAIN Teams app (the one that owns the chat window). Must NOT return a helper —
// helpers have no windows, which would break waitForWindow. Pick the exact main bundle
// id; fall back to the first non-helper, then anything Teams-ish.
func teamsApp() -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications
    if let main = apps.first(where: { $0.bundleIdentifier == "com.microsoft.teams2" || $0.bundleIdentifier == "com.microsoft.teams" }) { return main }
    if let nonHelper = apps.first(where: { a in
        guard isTeamsApp(a) else { return false }
        let b = a.bundleIdentifier ?? ""
        return !b.contains("helper") && !b.contains("notificationcenter") && !b.contains("webview")
    }) { return nonHelper }
    return apps.first(where: isTeamsApp)
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
// Current text in the compose box. When the box is empty the AXTextArea reports its
// PLACEHOLDER ("Type a message") as its value, not "" — treat that as empty, otherwise
// prefill-detection and clear/sent verification all misfire.
let COMPOSE_PLACEHOLDER = "Type a message"
func composeValue(_ win: AXUIElement) -> String {
    var f: [AXUIElement] = []
    collect(win, { _, r in r == "AXTextArea" }, &f)
    let v = (f.first.map { axStr($0, kAXValueAttribute as String) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return v == COMPOSE_PLACEHOLDER ? "" : v
}
func composeEmpty(_ appEl: AXUIElement) -> Bool { firstWindow(appEl).map { composeValue($0).isEmpty } ?? false }

// Bring the user's previously-active app back to the front. On macOS 26 a background
// CLI tool CANNOT foreground another app via NSRunningApplication.activate() OR .hide()
// — both are silently ignored (the OS only lets the frontmost / user-driven process
// reorder apps, and Teams' Electron shell self-activates after a deep-link open). Even
// AXUIElementSetAttributeValue(kAXFrontmost) returns success but does nothing. What DOES
// work, with NO extra TCC permission (no Accessibility, no Automation), is asking
// LaunchServices to (re)open the already-running app: `/usr/bin/open` foregrounds it as
// a user-semantic open, which isn't subject to the cooperative-activation block. We
// retry a few times in case Teams is still mid-way through its own async self-activation.
// If the user was already in Teams, leave it alone.
let FOCUS_DEBUG = ProcessInfo.processInfo.environment["TEAMS_FOCUS_DEBUG"] == "1"
func fdbg(_ s: String) { if FOCUS_DEBUG { FileHandle.standardError.write(("[focus] " + s + "\n").data(using: .utf8)!) } }

// Return focus to the user's previously-active app. THE HARD PART (macOS 26): Teams'
// Electron shell self-activates ASYNCHRONOUSLY after a deep-link nav — empirically it
// jumps to the front ~right as this CLI would normally exit (measured: the user's app is
// still frontmost throughout our run, then Teams grabs the front <0.3s after we exit).
// Fixing focus inline is therefore futile. On top of that, a background CLI cannot
// reorder apps via NSRunningApplication.activate()/.hide() (both silently ignored on 26)
// nor via AXUIElementSetAttributeValue(kAXFrontmost) (returns success, does nothing) —
// the ONLY thing that works, with no extra TCC permission, is LaunchServices opening the
// already-running app (`/usr/bin/open`). So: spawn a DETACHED helper (`__refocus`) that
// OUTLIVES us, waits for Teams' late self-activation, and `open`s the previous app back.
// The read/send result is already on stdout, so the caller answers immediately while
// focus is corrected in the background (no added latency).
func restoreFocus(_ app: NSRunningApplication?) {
    guard let app = app else { return }
    if isTeamsApp(app) { return }                                  // user was already in Teams — leave it
    var openArgs: [String] = []
    if let url = app.bundleURL { openArgs = [url.path] }            // most robust
    else if let bid = app.bundleIdentifier { openArgs = ["-b", bid] }
    else { return }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["__refocus", String(app.processIdentifier)] + openArgs
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FOCUS_DEBUG ? FileHandle.standardError : FileHandle.nullDevice
    try? child.run()
    // intentionally NOT waitUntilExit() — detach so it fixes focus after we're gone
}

// Detached helper (run as `teams __refocus <prevPid> <open-args…>`): watch for Teams'
// late self-activation and bring the previous app back via `/usr/bin/open`. Claws focus
// back ONLY from Teams (never from a third app the user may have deliberately switched
// to), stops once that app is stably front, and gives up after a while.
//
// Teams is identified by IDENTITY (isTeamsApp), NOT by pid-equality with teamsApp():
// new Teams runs ~5 processes ("Microsoft Teams", "… WebView", "… Notification Center")
// and any of them can own the front window. The old pid check matched only one of them,
// so when a different Teams process was frontmost the daemon mistook it for a third app
// and quit, stranding the user in Teams. A genuine third-app switch is only honored after
// it stays front a beat (so a transient frontmost during the `open` doesn't end it early).
func refocusDaemon(prevPid: Int32, openArgs: [String]) {
    setsid()                                        // detach from the parent's session/group
    guard prevPid > 0, !openArgs.isEmpty else { return }
    let deadline = Date().addingTimeInterval(12)
    var sawTeams = false, prevStable = 0, otherStable = 0
    while Date() < deadline {
        let front = NSWorkspace.shared.frontmostApplication
        if isTeamsApp(front) {                                      // any Teams process grabbed → claw back
            sawTeams = true; prevStable = 0; otherStable = 0
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/open"); t.arguments = openArgs
            try? t.run(); t.waitUntilExit()
            fdbg("daemon: clawed back from Teams")
        } else if front?.processIdentifier == prevPid {            // sitting on the previous app
            prevStable += 1; otherStable = 0
            if sawTeams && prevStable >= 5 { fdbg("daemon: prev stable, done"); return }     // ~1s after claw-back
            if !sawTeams && prevStable >= 12 { fdbg("daemon: teams never fronted, done"); return } // ~2.4s, no steal
        } else {                                                   // some third app is front
            otherStable += 1; prevStable = 0
            if otherStable >= 8 { fdbg("daemon: user switched elsewhere, stop"); return }   // ~1.6s stable → don't fight
        }
        usleep(200_000)
    }
    fdbg("daemon: deadline reached")
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
func needleOf(_ message: String) -> String { String(message.prefix(18)) }
func prefilled(_ appEl: AXUIElement, _ message: String) -> Bool {
    guard let win = firstWindow(appEl) else { return false }
    return composeValue(win).contains(needleOf(message))
}
// Poll for the deep-link &message= prefill to actually land. The prefill is async and a
// slow one used to arrive AFTER a fixed sleep, so the code fell through to the typing
// path and the late prefill then duplicated the message. Polling removes that race.
func waitPrefilled(_ appEl: AXUIElement, _ message: String, _ maxMs: Int = 4000) -> Bool {
    let needle = needleOf(message)
    var waited = 0
    while waited < maxMs {
        if let win = firstWindow(appEl), composeValue(win).contains(needle) { return true }
        usleep(200_000); waited += 200
    }
    return false
}
// The compose AXTextArea (first text area in the window).
func composeArea(_ appEl: AXUIElement) -> AXUIElement? {
    guard let win = firstWindow(appEl) else { return nil }
    var f: [AXUIElement] = []
    collect(win, { _, r in r == "AXTextArea" }, &f)
    return f.first
}
// Focus the compose box for keystroke entry. After a deep-link nav Teams is already the
// frontmost app (it self-activates), but the compose box itself may not hold keyboard
// focus — so we assert AX focus on the text area (this DOES work; setting kAXValue does
// not). activate() is a best-effort nudge in case Teams isn't quite front yet.
func focusCompose(_ app: NSRunningApplication, _ appEl: AXUIElement) {
    app.activate(); usleep(200_000)
    if let ta = composeArea(appEl) {
        AXUIElementSetAttributeValue(ta, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(150_000)
    }
}
// Clear the compose box and confirm it's actually empty (⌘A+Delete can no-op if the box
// isn't focused yet). Verified-empty before typing is what prevents the double-paste.
func clearCompose(_ appEl: AXUIElement) {
    for _ in 0..<6 {
        if composeEmpty(appEl) { return }
        tapKey(VK_A, .maskCommand); tapKey(VK_DEL); usleep(180_000)
    }
}
// Type the message so it lands EXACTLY once: focus, clear, type, verify a single
// occurrence; if it's missing (focus failed) or doubled, retry. Returns false if it
// never lands cleanly — so the caller reports an honest failure instead of "Sent".
func typeMessageVerified(_ app: NSRunningApplication, _ appEl: AXUIElement, _ message: String) -> Bool {
    guard !message.isEmpty else { return true }
    let needle = needleOf(message)
    for _ in 0..<3 {
        focusCompose(app, appEl)
        clearCompose(appEl)
        typeUnicode(message); usleep(300_000)
        if let win = firstWindow(appEl), composeValue(win).components(separatedBy: needle).count - 1 == 1 { return true }
    }
    return false
}
// Press Send and CONFIRM the box emptied — the only reliable signal the message left the
// compose box. Returns false if it never empties, so we can report honestly instead of
// claiming "Sent" while the text just sits there.
func sendVerified(_ appEl: AXUIElement) -> Bool {
    for _ in 0..<4 {
        if composeEmpty(appEl) { return true }      // already gone → sent
        if !pressSend(appEl) { tapKey(VK_RET) }     // AXPress Send, else Enter
        usleep(550_000)
    }
    return composeEmpty(appEl)
}

// pasteImage — put a PNG on the pasteboard and ⌘V it into the focused compose box.
func pasteImage(_ path: String) -> Bool {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return false }
    let pb = NSPasteboard.general; pb.clearContents(); pb.setData(png, forType: .png)
    tapKey(VK_V, .maskCommand); usleep(1_500_000); return true
}

// One send. Text-only takes the fast prefill-on-navigation path; if the chat is already
// open (prefill ignored) the prefill silently does nothing, so we type the message in.
// Either way Teams foregrounds itself on the nav, so the keystrokes land in its compose
// box — no activate()/⌘R needed (⌘R reloads the Teams renderer and corrupts the draft).
// Every path verifies: typed exactly once (no double-paste) and the box emptied on send
// (so we never report "Sent" while the text just sits there). Focus is restored by the
// caller afterwards (restoreFocus).
func sendOne(_ emails: [String], message: String, attach: String?, dry: Bool) -> String {
    let who = emails.joined(separator: ", ")
    guard let (app, appEl, _) = waitForWindow() else { return "Teams window not found." }

    func sentReport(_ ok: Bool, _ suffix: String = "") -> String {
        ok ? "Sent to \(who)\(suffix)."
           : "Prepared for \(who)\(suffix) but Send didn't register — message left in compose, NOT sent."
    }

    if attach == nil {
        openChat(emails, message: message)                            // navigate + prefill (Teams foregrounds)
        if waitPrefilled(appEl, message) {                            // prefill landed (chat wasn't already open)
            if dry { return "DRY: prefilled for \(who) — NOT sent." }
            return sentReport(sendVerified(appEl))
        }
        // Prefill ignored (chat already open) → type it in, verified single occurrence.
        if !typeMessageVerified(app, appEl, message) {
            return "Couldn't enter the message into Teams for \(who) — NOT sent."
        }
        if dry { return "DRY: typed for \(who) — NOT sent." }
        return sentReport(sendVerified(appEl))
    }

    // Attachment path: open the chat, then type the caption and paste the image into the
    // now-foreground compose box (the ⌘V paste needs the compose box focused).
    openChat(emails); usleep(1_200_000)
    focusCompose(app, appEl)
    clearCompose(appEl)                                               // start clean even with an empty caption
    if !typeMessageVerified(app, appEl, message) {                    // no-op (true) when caption is empty
        return "Couldn't enter the caption into Teams for \(who) — NOT sent."
    }
    focusCompose(app, appEl)                                          // re-assert focus before the paste
    if let path = attach, !pasteImage(path) { return "Could not load image: \(path)" }
    if dry { return "DRY: typed + attached for \(who) — NOT sent." }
    return sentReport(sendVerified(appEl), " (with attachment)")
}

// MARK: - CLI
let argv = Array(CommandLine.arguments.dropFirst())
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }
guard let cmd = argv.first else { fail("usage: teams read|send …") }
let rest = Array(argv.dropFirst())

// Internal: detached focus-restore helper spawned by restoreFocus (not user-facing).
if cmd == "__refocus" {
    refocusDaemon(prevPid: Int32(rest.first ?? "") ?? -1, openArgs: Array(rest.dropFirst()))
    exit(0)
}

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
