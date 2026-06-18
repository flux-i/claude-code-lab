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

final class AppDelegate: NSObject, NSApplicationDelegate, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, URLSessionDataDelegate {

    // Config
    private let triggerKeyCode: UInt16 = 54 // Right Command
    private let agentPath = ("~/.claude/voice/voice-agent.sh" as NSString).expandingTildeInPath
    private let sessionPath = ("~/.claude/voice/session.json" as NSString).expandingTildeInPath
    private let logDir = ("~/.claude/voice/logs" as NSString).expandingTildeInPath

    // Text-to-speech
    //  Primary: neural Chatterbox voice from a local server (see tts-server/).
    //  Fallback: Apple's AVSpeechSynthesizer if the server isn't up yet.
    private let synth = AVSpeechSynthesizer()
    private let ttsPort = 8765
    private let ttsRunScript = ("~/.claude/voice/tts-server/run.sh" as NSString).expandingTildeInPath
    private var ttsURL: URL { URL(string: "http://127.0.0.1:\(ttsPort)/tts")! }
    private var ttsStreamURL: URL { URL(string: "http://127.0.0.1:\(ttsPort)/tts_stream")! }
    private var ttsHealthURL: URL { URL(string: "http://127.0.0.1:\(ttsPort)/health")! }
    private var audioPlayer: AVAudioPlayer?
    private var karaokeTimer: Timer?

    // Speech-to-text
    //  Primary: Whisper (whisper.cpp large-v3-turbo) from a local server (see stt-server/) —
    //  accent-robust, English, offline. Fallback: Apple's on-device SFSpeechRecognizer,
    //  which also drives the live partial-word HUD while you speak.
    private let sttPort = 8766
    private let sttRunScript = ("~/.claude/voice/stt-server/run.sh" as NSString).expandingTildeInPath
    private var sttInferenceURL: URL { URL(string: "http://127.0.0.1:\(sttPort)/inference")! }
    private var sttRootURL: URL { URL(string: "http://127.0.0.1:\(sttPort)/")! } // liveness (no /health)
    private var sttUp = false                  // cached liveness, refreshed by pollSTTHealth()

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
    private var transcript = ""             // final text → runClaude; SFSpeech sets it live,
                                            // Whisper overwrites it on release when available
    private var usingWhisper = false        // this turn routes through the Whisper server
    private var recordWriter: AVAudioFile?  // 16 kHz mono WAV captured for Whisper
    private var recordURL: URL?
    private var recordConverter: AVAudioConverter?  // input HW format → 16 kHz mono (held across taps)

    // Streaming response state
    private var agentProc: Process?           // in-flight voice-agent.sh (killed on barge-in)
    private var speechQueue: [String] = []    // segments waiting to be spoken, in order
    private var isSpeaking = false            // a segment is currently playing
    private var agentRunning = false          // the agent process is still producing output
    private var gotResult = false             // a RESULT line arrived this turn
    private var runID = 0                     // bumped each turn; stale callbacks are dropped
    private var lastEnqueued = ""             // de-dupe: skip a segment identical to the previous

    // Streamed RESULT playback. The final reply is fetched from /tts_stream as
    // length-framed WAV chunks ([4-byte big-endian length][WAV]) and played gaplessly
    // the instant each arrives — first word in ~a few seconds regardless of length,
    // then continuous (the server keeps a synthesis lead so playback never underruns).
    // Short narration (SAY/TOOL/ALERT, the "On it…" ack) still uses the batch queue
    // above; only the long final answer streams. The next chunk's player is prepared
    // while the current one plays so chunk-to-chunk transitions are seamless.
    private var streaming = false             // a /tts_stream RESULT is in flight
    private var streamPlaying = false         // a streamed chunk is currently playing
    private var streamEOF = false             // the server has sent every frame
    private var gotStreamAudio = false        // at least one frame arrived (else → fallback)
    private var streamChunks: [Data] = []     // received-but-not-yet-prepared WAV frames
    private var streamNextPlayer: AVAudioPlayer?  // the following chunk, prepared ahead
    private var streamBuffer = Data()         // raw bytes awaiting frame parsing
    private var streamText = ""               // full reply text (HUD + system-voice fallback)
    private var pendingResult: String?        // RESULT waiting for the batch queue to drain
    private var streamTask: URLSessionDataTask?
    private var streamSession: URLSession?

    // Deferred ack: break the silence only when Claude takes a while. A short cue is
    // spoken if nothing real has been said within `ackDelay`; cancelled the instant
    // narration/answer arrives, so fast replies stay silent (no per-reply spam).
    private var ackTimer: Timer?
    private var ackIndex = 0
    private let ackDelay: TimeInterval = 2.5
    private let ackCues = [
        "One sec…", "Working on it…", "On it…", "Just a moment…",
        "Give me a sec…", "Hang tight…", "Let me check…", "Looking into it…",
        "Right away…", "Let me see…", "Checking…", "Pulling that up…",
        "One moment…", "Almost there…", "Let me dig in…", "Working through it…",
        "Getting that for you…", "Let me take a look…", "Hold on a sec…", "Just a second…",
        "Sorting that out…", "Let me figure this out…", "Diving in…", "Let me handle that…",
        "Getting to it…", "Bear with me…", "Let me pull that together…", "Thinking it through…",
        "Looking that up…", "On the case…", "Give me a moment…", "Let me sort this…",
        "Working on that now…", "Checking on that…", "Let me get that…", "Pulling it together…",
        "Let me run that down…", "Hang on a moment…", "Getting that sorted…", "On it, one moment…",
        "Let me track that down…", "Working it out…", "Just a tick…", "Let me have a look…",
        "Coming right up…", "Give me just a second…", "Let me piece this together…", "Still on it…",
        "Let me dig into that…", "Just a moment more…", "Crunching on that…", "Let me look that over…",
        "Almost got it…", "Working away…",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hud = HUDController(state: state)
        synth.delegate = self

        buildStatusItem()
        requestPermissions()
        installHotkeyMonitors()
        refreshAccessibilityState()
        ensureTTSServer()
        ensureSTTServer()
        pollSTTHealth()

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
        // Barge-in: pressing the key mid-response (thinking or speaking) cancels it and
        // starts a fresh listen. The new command runs once you release the key.
        if agentRunning || isSpeaking || streaming || !speechQueue.isEmpty { cancelCurrentOperation() }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            flash(.error, error: "Speech recognition isn't ready yet."); return
        }
        transcript = ""
        didRun = false
        // Route this whole turn through Whisper if the server is up; otherwise Apple-only.
        // (Read off the cached flag so there's no per-keypress health-check latency.)
        usingWhisper = sttUp

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            flash(.error, error: "No audio input. Check microphone permission."); return
        }

        // In Whisper mode, also capture the mic to a 16 kHz mono WAV to POST on release.
        // SFSpeech still runs underneath for the live HUD + as a fallback.
        recordWriter = nil; recordConverter = nil; recordURL = nil
        if usingWhisper {
            if !beginWavCapture(from: format) { usingWhisper = false }  // capture setup failed → Apple-only
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.request?.append(buffer)
            if self.usingWhisper { self.appendWav(buffer) }
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
                // In Whisper mode the Whisper response decides when to run, not SFSpeech.
                if result.isFinal && !self.usingWhisper { self.finishAndRun() }
            }
            if error != nil && !self.usingWhisper { self.finishAndRun() }
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
        recordWriter = nil   // close + flush the WAV header
        DispatchQueue.main.async {
            self.setBarSymbol("hourglass", tint: .systemOrange)
        }
        if usingWhisper, let url = recordURL {
            // Release fires the POST immediately — no silence timeout needed.
            transcribeWithWhisper(url)
        } else {
            // Apple path: SFSpeech finalizes on its own; 2 s is the safety net.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.finishAndRun()
            }
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

    // MARK: Whisper capture + transcription
    /// Open a 16 kHz mono Int16 WAV and a converter from the mic's hardware format.
    /// Returns false if setup fails (caller then falls back to Apple-only for this turn).
    private func beginWavCapture(from inputFormat: AVAudioFormat) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudevoice-\(runID).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat)
        else { return false }
        recordWriter = file
        recordConverter = converter
        recordURL = url
        return true
    }

    /// Convert one mic buffer to 16 kHz mono and append it to the WAV (called on the audio thread).
    private func appendWav(_ buffer: AVAudioPCMBuffer) {
        guard let conv = recordConverter, let file = recordWriter else { return }
        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil && out.frameLength > 0 { try? file.write(from: out) }
    }

    /// POST the recorded WAV to the Whisper server; use its text, else the Apple transcript.
    private func transcribeWithWhisper(_ wavURL: URL) {
        let myID = runID
        let appleFallback = transcript      // whatever SFSpeech captured live this turn
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let whisper = self.postWhisper(wavURL)
            try? FileManager.default.removeItem(at: wavURL)
            DispatchQueue.main.async {
                guard myID == self.runID else { return }   // superseded by a barge-in
                let final = (whisper?.isEmpty == false) ? whisper! : appleFallback
                self.transcript = final
                self.finishAndRun()
            }
        }
    }

    /// Synchronous multipart POST to whisper-server /inference; nil on any failure.
    private func postWhisper(_ wavURL: URL) -> String? {
        guard let wav = try? Data(contentsOf: wavURL) else { return nil }
        let boundary = "claudevoice-boundary-\(runID)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (name, value) in [("response_format", "json"), ("temperature", "0"), ("language", "en")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: sttInferenceURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = obj["text"] as? String {
                // whisper-server emits a newline per segment — collapse to a clean one-liner.
                result = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                    .joined(separator: " ")
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 31)
        return result
    }

    // MARK: Execution (session-aware shell agent, STREAMING)
    //
    // Runs voice-agent.sh with VOICE_STREAM=1 and reads its tab-delimited line
    // protocol (SAY/TOOL/ALERT/RESULT) AS IT STREAMS, queuing each piece to speak —
    // so Claude talks you through long tasks instead of leaving you in silence.
    private func runClaude(_ text: String) {
        runID &+= 1
        let myID = runID
        agentRunning = true
        gotResult = false
        speechQueue.removeAll()
        isSpeaking = false
        lastEnqueued = ""
        // Deferred ack: if Claude produces nothing to say within `ackDelay`, speak one
        // short cue so the wait doesn't feel broken. It's cancelled the moment real
        // narration or the answer arrives (see dispatchProtocolLine), so quick replies
        // never hear it — the violet "thinking" orb covers the gap until then.
        ackTimer?.invalidate()
        // Pick a random cue (not sequential), avoiding an immediate repeat of the last one.
        var cueIndex = Int.random(in: 0..<ackCues.count)
        if ackCues.count > 1 && cueIndex == ackIndex { cueIndex = (cueIndex + 1) % ackCues.count }
        ackIndex = cueIndex
        let cue = ackCues[cueIndex]
        ackTimer = Timer.scheduledTimer(withTimeInterval: ackDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.ackTimer = nil
            guard myID == self.runID, self.agentRunning, !self.gotResult,
                  self.speechQueue.isEmpty, !self.isSpeaking else { return }
            self.enqueueSpeech(cue)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: self.agentPath)
            proc.arguments = [text]
            var env = ProcessInfo.processInfo.environment
            env["VOICE_STREAM"] = "1"
            proc.environment = env
            let out = Pipe(); proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice   // agent logs its own errors to agent.err
            DispatchQueue.main.async { if myID == self.runID { self.agentProc = proc } }

            do { try proc.run() }
            catch {
                DispatchQueue.main.async {
                    guard myID == self.runID else { return }
                    self.agentRunning = false
                    self.flash(.error, error: error.localizedDescription)
                }
                return
            }

            // Read line by line (newline-delimited) so we act on each event immediately.
            let handle = out.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }                  // EOF
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[buffer.startIndex..<nl])
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    self.dispatchProtocolLine(lineData, runID: myID)
                }
            }
            if !buffer.isEmpty { self.dispatchProtocolLine(buffer, runID: myID) }

            proc.waitUntilExit()
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard myID == self.runID else { return }    // a newer turn superseded this one
                self.agentProc = nil
                self.agentRunning = false
                self.onAgentFinished(code: code)
            }
        }
    }

    /// Parse one `TAG\ttext` protocol line and queue speech for it (on the main thread,
    /// dropping anything from a superseded turn).
    private func dispatchProtocolLine(_ data: Data, runID myID: Int) {
        guard let raw = String(data: data, encoding: .utf8) else { return }
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard let tab = line.firstIndex(of: "\t") else { return }
        let tag = String(line[..<tab])
        let text = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            guard myID == self.runID else { return }
            switch tag {
            case "ALERT", "SAY", "TOOL":
                self.ackTimer?.invalidate(); self.ackTimer = nil   // real output — skip the deferred cue
                self.enqueueSpeech(text)
            case "RESULT":
                self.ackTimer?.invalidate(); self.ackTimer = nil
                self.gotResult = true
                // Stream the final reply gaplessly via /tts_stream. If the ack or some
                // narration is still playing, hold it and start the stream the moment
                // the batch queue drains (see playNextInQueue).
                if self.isSpeaking || !self.speechQueue.isEmpty {
                    self.pendingResult = text
                } else {
                    self.startResultStream(text)
                }
            default:
                break                                        // SID and anything else: ignore
            }
        }
    }

    /// Agent process exited. Surface an error if nothing useful came back; otherwise let
    /// the speech queue finish and wrap up when it drains.
    private func onAgentFinished(code: Int32) {
        if code != 0 && !gotResult {
            cancelCurrentOperation()
            flash(.error, error: "No response from Claude.")
            return
        }
        // Don't wrap up if a streamed reply is still playing or queued to start.
        if !isSpeaking && speechQueue.isEmpty && !streaming && pendingResult == nil { finishResponse() }
    }

    private func finishResponse() {
        ackTimer?.invalidate(); ackTimer = nil
        setMenuState("Idle")
        setBarSymbol("mic", tint: nil)
        hud.hide(after: 1.2)
    }

    /// Barge-in / interrupt: kill any in-flight agent + audio, drop the queue, and
    /// invalidate pending callbacks (via runID) so nothing from the old turn leaks in.
    private func cancelCurrentOperation() {
        runID &+= 1
        ackTimer?.invalidate(); ackTimer = nil
        agentProc?.terminate()
        agentProc = nil
        agentRunning = false
        speechQueue.removeAll()
        lastEnqueued = ""
        isSpeaking = false
        // Tear down any in-flight streamed reply.
        streaming = false
        streamPlaying = false
        streamEOF = false
        gotStreamAudio = false
        streamChunks.removeAll()
        streamBuffer.removeAll()
        streamText = ""
        pendingResult = nil
        streamNextPlayer?.stop(); streamNextPlayer = nil
        streamTask?.cancel(); streamTask = nil
        streamSession?.invalidateAndCancel(); streamSession = nil
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        karaokeTimer?.invalidate()
        state.stream = ""
    }

    // MARK: Text-to-speech (Claude speaks its reply back, words streamed to the HUD)
    //
    // Primary path is the neural Chatterbox server: POST the text, play the returned
    // WAV, and drive the karaoke window off the clip's duration. If the server isn't
    // reachable (still loading, not installed), fall back to the system synthesizer.
    /// One-off speak (menu actions, demo): replace anything in flight with this.
    private func speak(_ text: String) {
        cancelCurrentOperation()
        hud.show()
        enqueueSpeech(text)
    }

    /// Queue a segment; start playing if nothing is currently speaking.
    private func enqueueSpeech(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != lastEnqueued else { return }   // skip empties + consecutive repeats
        lastEnqueued = t
        speechQueue.append(t)
        if !isSpeaking { playNextInQueue() }
    }

    private func playNextInQueue() {
        guard !speechQueue.isEmpty else {
            isSpeaking = false
            if let r = pendingResult {                         // narration done → stream the answer
                pendingResult = nil
                startResultStream(r)
                return
            }
            if !agentRunning { finishResponse() }             // all said and agent done
            return                                            // else keep the orb green, await more
        }
        isSpeaking = true
        state.phase = .done                                   // green "speaking" orb — stays green
        speakSegment(speechQueue.removeFirst())
    }

    /// Synthesize + play ONE segment via the neural server; advance the queue on finish.
    private func speakSegment(_ text: String) {
        let myID = runID
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.stop(); audioPlayer = nil
        karaokeTimer?.invalidate()
        requestNeuralSpeech(text) { [weak self] data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard myID == self.runID else { return }   // turn superseded mid-synth
                if let data = data, self.playNeural(data, text: text) { return }
                self.speakSystem(text)                      // graceful fallback to Apple TTS
            }
        }
    }

    /// A segment finished playing — move to the next (or wrap up).
    private func segmentFinished() {
        karaokeTimer?.invalidate()
        playNextInQueue()
    }

    // MARK: Streamed reply (/tts_stream)
    //
    // Fetch the final answer as length-framed WAV chunks and play them gaplessly as
    // they arrive. The HUD karaoke runs off an estimated total duration (we don't know
    // the real one until every frame lands); the rolling 10-word window self-corrects.

    /// Begin streaming + playing the final reply. Falls back to the system voice if the
    /// server never sends any audio (down / errored).
    private func startResultStream(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.stop(); audioPlayer = nil
        karaokeTimer?.invalidate()
        streaming = true
        streamPlaying = false
        streamEOF = false
        gotStreamAudio = false
        streamChunks.removeAll()
        streamBuffer.removeAll()
        streamNextPlayer = nil
        streamText = text
        streamTask?.cancel()
        streamSession?.invalidateAndCancel(); streamSession = nil   // belt-and-suspenders
        state.phase = .done                                   // green "speaking" orb
        startKaraoke(text: text, duration: estimatedSpeechDuration(text))

        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
            streaming = false; speakSystem(text); return
        }
        var req = URLRequest(url: ttsStreamURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 300
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        streamSession = session
        let dataTask = session.dataTask(with: req)
        streamTask = dataTask
        dataTask.resume()
    }

    /// Pull complete `[4-byte length][WAV]` frames out of the receive buffer; start /
    /// keep playback fed as each one lands.
    private func drainStreamFrames() {
        while true {
            guard streamBuffer.count >= 4 else { break }
            let s = streamBuffer.startIndex
            let len = (Int(streamBuffer[s]) << 24) | (Int(streamBuffer[s + 1]) << 16)
                    | (Int(streamBuffer[s + 2]) << 8) | Int(streamBuffer[s + 3])
            if len <= 0 || len > 50_000_000 {                 // corrupt frame → stop parsing
                streamBuffer.removeAll(); break
            }
            guard streamBuffer.count >= 4 + len else { break } // wait for the rest of the frame
            let wav = streamBuffer.subdata(in: (s + 4)..<(s + 4 + len))
            streamBuffer.removeSubrange(s..<(s + 4 + len))
            streamChunks.append(wav)
            gotStreamAudio = true
            if !streamPlaying { playNextStreamChunk() } else { prepareNextStreamChunk() }
        }
    }

    /// Play the next streamed chunk (using the pre-prepared player when available so the
    /// transition is seamless), and prepare the one after it.
    private func playNextStreamChunk() {
        guard streaming else { return }
        var player = streamNextPlayer
        streamNextPlayer = nil
        while player == nil, !streamChunks.isEmpty {           // build from the raw queue, skipping bad frames
            player = makeStreamPlayer(streamChunks.removeFirst())
        }
        guard let p = player else {                            // nothing ready right now
            streamPlaying = false
            if streamEOF { finishStreamResult() }              // genuinely done
            return                                             // else underrun: wait for the next frame
        }
        streamPlaying = true
        audioPlayer = p
        p.play()
        prepareNextStreamChunk()
    }

    /// Pre-build the following chunk's player so it can start the instant this one ends.
    private func prepareNextStreamChunk() {
        guard streamNextPlayer == nil else { return }
        while !streamChunks.isEmpty {
            if let p = makeStreamPlayer(streamChunks.removeFirst()) { streamNextPlayer = p; return }
        }
    }

    private func makeStreamPlayer(_ data: Data) -> AVAudioPlayer? {
        guard let p = try? AVAudioPlayer(data: data) else { return nil }
        p.delegate = self
        p.prepareToPlay()
        return p
    }

    /// The streamed reply finished playing — tear down and wrap up.
    private func finishStreamResult() {
        streaming = false
        streamPlaying = false
        streamNextPlayer = nil
        streamChunks.removeAll()
        streamBuffer.removeAll()
        streamTask = nil
        streamSession?.finishTasksAndInvalidate(); streamSession = nil
        karaokeTimer?.invalidate()
        state.stream = ""
        if !agentRunning { finishResponse() }
    }

    /// Rough spoken-duration estimate (~0.072 s/char on this voice) to pace the HUD
    /// before the true total is known.
    private func estimatedSpeechDuration(_ text: String) -> TimeInterval {
        max(1.0, Double(text.count) * 0.072 + 0.3)
    }

    // URLSession streaming callbacks (delegateQueue is a background queue → hop to main).
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        DispatchQueue.main.async {
            guard self.streaming, dataTask === self.streamTask else { return }
            self.streamBuffer.append(data)
            self.drainStreamFrames()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            guard self.streaming, task === self.streamTask else { return }
            self.drainStreamFrames()
            self.streamEOF = true
            if !self.gotStreamAudio {                          // server unreachable / empty → Apple voice
                self.streaming = false
                self.streamTask = nil
                self.streamSession?.finishTasksAndInvalidate(); self.streamSession = nil
                self.speakSystem(self.streamText)
                return
            }
            if !self.streamPlaying && self.streamChunks.isEmpty { self.finishStreamResult() }
        }
    }

    /// Ask the Chatterbox server for speech audio; nil on any failure (→ fallback).
    private func requestNeuralSpeech(_ text: String, completion: @escaping (Data?) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
            completion(nil); return
        }
        var req = URLRequest(url: ttsURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120          // synthesis of a long reply can take a few seconds
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data, !data.isEmpty,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                completion(nil); return
            }
            completion(data)
        }.resume()
    }

    /// Play neural WAV data and start the karaoke window. Returns false if it can't play.
    private func playNeural(_ data: Data, text: String) -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            guard player.prepareToPlay() else { return false }
            audioPlayer = player
            player.play()
            startKaraoke(text: text, duration: player.duration)
            return true
        } catch {
            return false
        }
    }

    /// Approximate the AVSpeech "karaoke" sync: reveal words proportional to elapsed
    /// playback so the HUD shows the last ~10 spoken words, then clears at the end.
    private func startKaraoke(text: String, duration: TimeInterval) {
        karaokeTimer?.invalidate()
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !words.isEmpty, duration > 0 else { return }
        let start = Date()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let frac = min(1.0, Date().timeIntervalSince(start) / duration)
            let count = max(1, Int((frac * Double(words.count)).rounded(.up)))
            let window = words.prefix(count).suffix(10).joined(separator: " ")
            self.state.stream = window
            if frac >= 1.0 { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        karaokeTimer = timer
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if streaming { playNextStreamChunk() } else { segmentFinished() }
    }

    /// Apple's on-device synthesizer — fallback when the neural server isn't ready.
    private func speakSystem(_ text: String) {
        state.stream = ""
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    // MARK: Chatterbox server lifecycle
    /// Launch the local TTS server at startup if it isn't already listening.
    private func ensureTTSServer() {
        guard FileManager.default.fileExists(atPath: ttsRunScript) else { return }  // not installed yet
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, !self.isTTSUp() else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [self.ttsRunScript]
            let logPath = (self.logDir as NSString).appendingPathComponent("tts-server.log")
            FileManager.default.createFile(atPath: logPath, contents: nil)
            if let fh = FileHandle(forWritingAtPath: logPath) {
                p.standardOutput = fh
                p.standardError = fh
            }
            try? p.run()   // detached; first launch loads the model (~10-20s)
        }
    }

    /// Synchronous health check (called off the main thread).
    private func isTTSUp() -> Bool {
        var req = URLRequest(url: ttsHealthURL)
        req.timeoutInterval = 0.6
        let sem = DispatchSemaphore(value: 0)
        var up = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200 { up = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return up
    }

    // MARK: Whisper STT server lifecycle
    /// Launch the local whisper.cpp server at startup if it isn't already listening.
    private func ensureSTTServer() {
        guard FileManager.default.fileExists(atPath: sttRunScript) else { return }  // not installed yet
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, !self.isSTTUp() else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [self.sttRunScript]
            let logPath = (self.logDir as NSString).appendingPathComponent("stt-server.log")
            FileManager.default.createFile(atPath: logPath, contents: nil)
            if let fh = FileHandle(forWritingAtPath: logPath) {
                p.standardOutput = fh
                p.standardError = fh
            }
            try? p.run()   // detached; first launch loads the model (~10-20s)
        }
    }

    /// whisper-server has no /health — once the port answers, the model is already loaded.
    private func isSTTUp() -> Bool {
        var req = URLRequest(url: sttRootURL)
        req.timeoutInterval = 0.6
        let sem = DispatchSemaphore(value: 0)
        var up = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode < 500 { up = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return up
    }

    /// Poll liveness every few seconds so startRecording reads a cached flag (no per-keypress latency).
    private func pollSTTHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let up = self.isSTTUp()
            DispatchQueue.main.async {
                self.sttUp = up
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.pollSTTHealth() }
            }
        }
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
        segmentFinished()
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Deliberate stop (next segment / barge-in) — do NOT advance the queue here.
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
