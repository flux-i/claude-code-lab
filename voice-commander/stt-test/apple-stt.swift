// apple-stt — transcribe audio files through Apple's SFSpeechRecognizer using the
// SAME config as ClaudeVoice (main.swift): locale en-US, on-device forced when supported.
// Usage: apple-stt <file1> [file2 ...]   → prints a JSON array, one object per file.
//
// This is the "current" side of the Apple-vs-Spokenly STT bake-off. It reads each
// file via SFSpeechURLRecognitionRequest (file-based variant of the live mic path the
// app uses), so the underlying recognition model is identical to what the app invokes.
import Foundation
import Speech
import AVFoundation

struct Out: Codable {
    let file: String
    let transcript: String
    let onDevice: Bool
    let elapsedMs: Int
    let error: String?
}

func jsonEscape(_ s: String) -> String {
    let d = try! JSONEncoder().encode([s])
    return String(data: d, encoding: .utf8)!  // ["..."]
}

let files = Array(CommandLine.arguments.dropFirst())
guard !files.isEmpty else {
    FileHandle.standardError.write("usage: apple-stt <file> [file ...]\n".data(using: .utf8)!)
    exit(2)
}

// --- Authorization (attributed to the controlling terminal app) ---
let authSem = DispatchSemaphore(value: 0)
var auth: SFSpeechRecognizerAuthorizationStatus = .notDetermined
SFSpeechRecognizer.requestAuthorization { status in auth = status; authSem.signal() }
authSem.wait()
guard auth == .authorized else {
    let msg = "Speech recognition not authorized (status=\(auth.rawValue)). " +
        "Grant it to your terminal in System Settings → Privacy & Security → Speech Recognition, then re-run.\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(3)
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
    FileHandle.standardError.write("no recognizer for en-US\n".data(using: .utf8)!)
    exit(4)
}
// Wait briefly for availability.
var waited = 0
while !recognizer.isAvailable && waited < 50 { usleep(100_000); waited += 1 }

func transcribe(_ path: String) -> Out {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
        return Out(file: path, transcript: "", onDevice: false, elapsedMs: 0, error: "file not found")
    }
    let req = SFSpeechURLRecognitionRequest(url: url)
    req.shouldReportPartialResults = false
    let onDevice = recognizer.supportsOnDeviceRecognition
    if onDevice { req.requiresOnDeviceRecognition = true }   // mirror main.swift:394

    let sem = DispatchSemaphore(value: 0)
    var best = ""
    var err: String?
    let start = Date()
    let task = recognizer.recognitionTask(with: req) { result, error in
        if let result = result {
            best = result.bestTranscription.formattedString
            if result.isFinal { sem.signal() }
        }
        if let error = error {
            err = error.localizedDescription
            sem.signal()
        }
    }
    // Generous ceiling: some clips are ~47s; on-device runs faster than realtime.
    let timedOut = sem.wait(timeout: .now() + 120) == .timedOut
    task.cancel()
    if timedOut && err == nil && best.isEmpty { err = "timeout" }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    return Out(file: path, transcript: best, onDevice: onDevice, elapsedMs: ms, error: err)
}

// Speech delivers its recognitionTask callbacks on the MAIN queue, so the work
// can't block the main thread (that deadlocks). Run the file loop on a background
// queue and keep the main run loop spinning to service those callbacks.
DispatchQueue.global().async {
    var results: [Out] = []
    for f in files { results.append(transcribe(f)) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let data = (try? enc.encode(results)) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(0)
}
CFRunLoopRun()
