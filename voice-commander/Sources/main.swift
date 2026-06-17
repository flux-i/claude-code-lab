// ClaudeVoice — a serene, menu-bar push-to-talk launcher for headless Claude Code.
//
//   Hold Right ⌘  →  speak a command  →  release.
//
// A calm, space-black HUD fades in: a softly breathing orb, your words in thin
// white text, then Claude's answer — before fading away. Speech is transcribed
// on-device; the command runs via `claude -p`.

import AppKit
import AVFoundation
import Speech
import ApplicationServices
import SwiftUI
import Combine

// MARK: - Shared state ───────────────────────────────────────────────────────

enum Phase { case idle, listening, thinking, done, error }

final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var transcript: String = ""
    @Published var command: String = ""
    @Published var result: String = ""
    @Published var stream: String = ""      // rolling window of text currently being spoken
    @Published var errorText: String = ""
}

// MARK: - Visuals ─────────────────────────────────────────────────────────────

extension Color {
    static let spaceBlack = Color(red: 0.024, green: 0.027, blue: 0.043)
}

private func glow(for phase: Phase) -> Color {
    switch phase {
    case .listening: return Color(red: 0.62, green: 0.71, blue: 1.00) // cool moonlight
    case .thinking:  return Color(red: 0.74, green: 0.66, blue: 1.00) // soft violet
    case .done:      return Color(red: 0.66, green: 1.00, blue: 0.82) // pale aurora green
    case .error:     return Color(red: 1.00, green: 0.56, blue: 0.56) // muted rose
    case .idle:      return Color(red: 0.62, green: 0.71, blue: 1.00)
    }
}


/// A faint, static starfield — depth without distraction.
private struct Starfield: View {
    // Fixed positions (normalized) so it never flickers or feels busy.
    private let stars: [(x: CGFloat, y: CGFloat, s: CGFloat, o: Double)] = [
        (0.08, 0.12, 1.4, 0.18), (0.21, 0.30, 1.0, 0.10), (0.16, 0.62, 1.6, 0.14),
        (0.31, 0.80, 1.0, 0.08), (0.44, 0.18, 1.2, 0.12), (0.52, 0.66, 1.0, 0.09),
        (0.63, 0.34, 1.5, 0.15), (0.71, 0.78, 1.1, 0.10), (0.82, 0.22, 1.3, 0.13),
        (0.88, 0.55, 1.0, 0.08), (0.93, 0.83, 1.5, 0.12), (0.37, 0.46, 1.0, 0.07),
    ]
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<stars.count, id: \.self) { i in
                let st = stars[i]
                Circle()
                    .fill(Color.white.opacity(st.o))
                    .frame(width: st.s, height: st.s)
                    .position(x: st.x * geo.size.width, y: st.y * geo.size.height)
            }
        }
    }
}

/// The breathing orb — size-parameterised so it can be small in a compact card.
private struct Orb: View {
    let phase: Phase
    var diameter: CGFloat = 34
    @State private var breathe = false
    var body: some View {
        let c = glow(for: phase)
        let halo = diameter * 2.1
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [c.opacity(0.55), c.opacity(0.0)],
                                     center: .center, startRadius: 1, endRadius: halo / 2))
                .frame(width: halo, height: halo)
                .blur(radius: diameter * 0.16)
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.95), c.opacity(0.55), c.opacity(0.0)],
                                     center: .center, startRadius: 1, endRadius: diameter * 0.58))
                .frame(width: diameter, height: diameter)
        }
        .scaleEffect(breathe ? 1.06 : 0.92)
        .opacity(breathe ? 1.0 : 0.82)
        .animation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
    }
}

// Compact top-right card: small orb + a single rolling line of text.
private struct HUDView: View {
    @EnvironmentObject var state: AppState

    private var label: String {
        switch state.phase {
        case .idle, .listening: return "Listening"
        case .thinking:         return "Thinking"
        case .done:             return ""          // no "Done" — just the orb + spoken text
        case .error:            return "Error"
        }
    }
    private var caption: String {
        switch state.phase {
        case .idle, .listening: return state.transcript          // live transcript (may be empty)
        case .thinking:         return state.command
        case .done:             return state.stream              // rolling window, synced to speech
        case .error:            return state.errorText.isEmpty ? "Something went wrong." : state.errorText
        }
    }
    private var dim: Bool {
        (state.phase == .listening || state.phase == .idle) && state.transcript.isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            Orb(phase: state.phase, diameter: 32)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                if !label.isEmpty {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.32))
                }
                Text(caption.isEmpty ? "…" : caption)
                    .font(.system(size: 14, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(dim ? 0.30 : 0.90))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.18), value: caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 360, height: 92, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.spaceBlack)
                RadialGradient(colors: [glow(for: state.phase).opacity(0.16), .clear],
                               center: .leading, startRadius: 2, endRadius: 200)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - HUD window controller ───────────────────────────────────────────────

final class HUDController {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init(state: AppState) {
        let host = NSHostingView(rootView: HUDView().environmentObject(state))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        panel.alphaValue = 0
    }

    func show() {
        hideWork?.cancel(); hideWork = nil
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame              // excludes the menu bar
            let s = panel.frame.size
            let x = vf.maxX - s.width - 16            // 16pt from the right edge
            let y = vf.maxY - s.height - 10           // just below the menu bar
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
    }

    func hide(after seconds: TimeInterval = 0) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.orderOut(nil)
            })
        }
        hideWork?.cancel()
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - App delegate ────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, AVSpeechSynthesizerDelegate {

    // Config
    private let triggerKeyCode: UInt16 = 54 // Right Command
    private let agentPath = ("~/.claude/voice/voice-agent.sh" as NSString).expandingTildeInPath
    private let sessionPath = ("~/.claude/voice/session.json" as NSString).expandingTildeInPath
    private let logDir = ("~/.claude/voice/logs" as NSString).expandingTildeInPath

    // Text-to-speech
    private let synth = AVSpeechSynthesizer()

    // UI
    private var statusItem: NSStatusItem!
    private var stateMenuItem: NSMenuItem!
    private var axMenuItem: NSMenuItem!
    private let state = AppState()
    private var hud: HUDController!

    // Speech
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Hotkey
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Recording state
    private var isRecording = false
    private var didRun = false
    private var transcript = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hud = HUDController(state: state)
        synth.delegate = self

        buildStatusItem()
        requestPermissions()
        installHotkeyMonitors()
        refreshAccessibilityState()

        if CommandLine.arguments.contains("--demo") { runDemo() }
    }

    /// Visual smoke-test: listening → thinking → speaking (streamed), then fades.
    private func runDemo() {
        state.phase = .listening
        state.transcript = "create a branch called voice feature and run the tests"
        hud.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.state.command = "create a branch called voice feature and run the tests"
            self.state.phase = .thinking
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            self.state.phase = .done
            self.speak("All set. I created the branch voice feature and ran the tests. Forty eight passed and none failed.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    // MARK: Menu
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "ClaudeVoice")

        let menu = NSMenu()
        let hint = NSMenuItem(title: "Hold Right ⌘ and speak", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        stateMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)

        menu.addItem(.separator())

        axMenuItem = NSMenuItem(title: "Accessibility: checking…",
                                action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axMenuItem.target = self
        menu.addItem(axMenuItem)

        let inputMon = NSMenuItem(title: "Open Input Monitoring Settings…",
                                  action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMon.target = self
        menu.addItem(inputMon)

        let newConvo = NSMenuItem(title: "New Conversation", action: #selector(newConversation), keyEquivalent: "n")
        newConvo.target = self
        menu.addItem(newConvo)

        let logs = NSMenuItem(title: "Open Logs Folder…", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeVoice", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func setMenuState(_ s: String) { stateMenuItem.title = s }

    private func setBarSymbol(_ name: String, tint: NSColor?) {
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "ClaudeVoice")
        statusItem.button?.contentTintColor = tint
    }

    // MARK: Permissions
    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func refreshAccessibilityState() {
        axMenuItem.title = AXIsProcessTrusted()
            ? "Accessibility: granted ✓"
            : "Accessibility: NOT granted — click to fix"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshAccessibilityState()
        }
    }

    // MARK: Hotkey
    private func installHotkeyMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e); return e
        }
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == triggerKeyCode else { return }
        if event.modifierFlags.contains(.command) { startRecording() } else { stopRecording() }
    }

    // MARK: Recording
    private func startRecording() {
        guard !isRecording else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            flash(.error, error: "Speech recognition isn't ready yet."); return
        }
        transcript = ""
        didRun = false

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            flash(.error, error: "No audio input. Check microphone permission."); return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch { flash(.error, error: error.localizedDescription); return }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.state.transcript = self.transcript
                }
                if result.isFinal { self.finishAndRun() }
            }
            if error != nil { self.finishAndRun() }
        }

        isRecording = true
        DispatchQueue.main.async {
            self.state.phase = .listening
            self.state.transcript = ""
            self.setMenuState("● Listening…")
            self.setBarSymbol("mic.fill", tint: .systemRed)
            self.hud.show()
        }
        NSSound(named: "Tink")?.play()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        DispatchQueue.main.async {
            self.setBarSymbol("hourglass", tint: .systemOrange)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.finishAndRun()
        }
    }

    private func finishAndRun() {
        guard !didRun else { return }
        didRun = true
        task?.cancel(); task = nil; request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if text.isEmpty {
                self.setMenuState("Idle")
                self.setBarSymbol("mic", tint: nil)
                self.hud.hide(after: 0.2)
                return
            }
            self.state.command = text
            self.state.phase = .thinking
            self.setMenuState("⏳ Running…")
            self.runClaude(text)
        }
    }

    // MARK: Execution (delegates to the session-aware shell agent)
    private func runClaude(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: self.agentPath)
            proc.arguments = [text]
            let out = Pipe(); proc.standardOutput = out
            proc.standardError = Pipe()

            do { try proc.run() }
            catch {
                DispatchQueue.main.async { self.flash(.error, error: error.localizedDescription) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let reply = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let code = proc.terminationStatus

            DispatchQueue.main.async {
                if code == 0 && !reply.isEmpty {
                    self.state.phase = .done     // green orb, no label; text streams with speech
                    self.setMenuState("Idle")
                    self.setBarSymbol("mic", tint: nil)
                    self.speak(reply)            // HUD streams the words, then fades when speech ends
                    self.hud.hide(after: 90.0)   // safety, in case speech never finishes
                } else {
                    self.flash(.error, error: reply.isEmpty ? "No response from Claude." : reply)
                }
            }
        }
    }

    // MARK: Text-to-speech (Claude speaks its reply back, words streamed to the HUD)
    private func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        state.stream = ""
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    /// Karaoke sync: as each range is spoken, show only the last ~10 spoken words.
    func speechSynthesizer(_ s: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let full = utterance.speechString as NSString
        let end = min(characterRange.location + characterRange.length, full.length)
        let spokenSoFar = full.substring(to: end)
        let words = spokenSoFar.split(whereSeparator: { $0 == " " || $0 == "\n" })
        let window = words.suffix(10).joined(separator: " ")
        DispatchQueue.main.async { self.state.stream = window }
    }

    /// Pick the highest-quality English voice the system has installed.
    private func bestVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = (v.language == "en-US") ? 2 : 0
            switch v.quality {
            case .premium:  s += 6
            case .enhanced: s += 4
            default:        s += 1
            }
            return s
        }
        return voices.sorted { score($0) > score($1) }.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        hud.hide(after: 1.2)
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        hud.hide(after: 1.2)
    }

    private func flash(_ phase: Phase, error: String) {
        state.phase = .error
        state.errorText = error
        setMenuState("Idle")
        setBarSymbol("mic", tint: nil)
        NSSound(named: "Basso")?.play()
        hud.show()
        hud.hide(after: 6.0)
    }

    // MARK: Menu actions
    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logDir))
    }
    @objc private func newConversation() {
        try? FileManager.default.removeItem(atPath: sessionPath)
        speak("Starting a new conversation.")
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
