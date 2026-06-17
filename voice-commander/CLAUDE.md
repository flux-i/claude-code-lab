# CLAUDE.md — voice-commander (ClaudeVoice)

Push-to-talk macOS menu-bar app that runs spoken commands through headless Claude Code and speaks the reply back. Read this before changing things — there are a few non-obvious traps.

## Architecture (deliberate split)

```
ClaudeVoice.app  →  ~/.claude/voice/voice-agent.sh  →  claude -p
 (Swift/SwiftUI)       (shell: session logic)
```

- **`Sources/main.swift`** — the entire app, single file. Hotkey + Apple `Speech` (on-device STT) + SwiftUI HUD + `AVSpeechSynthesizer` TTS.
- **`~/.claude/voice/voice-agent.sh`** — ALL Claude/session logic lives here, on purpose. The app just shells out to it with the transcript and reads stdout.

**Why the split matters:** the app is ad-hoc signed, so every rebuild changes its code identity and macOS drops the Accessibility grant (forcing a re-grant). Keeping Claude/session behavior in the shell script means you can change the rules, prompt, or model **without rebuilding** — no permission churn. Prefer editing `voice-agent.sh` over `main.swift` whenever possible.

## Build / run

```bash
./build.sh                                  # swiftc + ad-hoc codesign → build/ClaudeVoice.app
open build/ClaudeVoice.app                  # run
open build/ClaudeVoice.app --args --demo    # cycle the HUD (no mic/permissions needed)
pkill -9 -f ClaudeVoice                     # stop
```

Always `pkill` before relaunching. Build target is `arm64-apple-macos26.0`, language mode `-swift-version 5` (avoids Swift 6 strict-concurrency errors). The `synth` non-Sendable warning is expected/harmless.

## Install for real use

```bash
cp -R build/ClaudeVoice.app /Applications/
xattr -dr com.apple.quarantine /Applications/ClaudeVoice.app
tccutil reset Accessibility com.furqan.claudevoice
open /Applications/ClaudeVoice.app
```

Run from `/Applications` (stable path → no app-translocation breaking TCC). Bundle id: `com.furqan.claudevoice`.

## Traps (these have all bitten us)

1. **Accessibility + ad-hoc signing.** The grant is honored only for the exact binary that was granted. Rebuild → re-grant. macOS activates Accessibility **at launch**, so after toggling it you must relaunch. If "granted" shows ON but isn't honored, `tccutil reset Accessibility com.furqan.claudevoice` and re-grant from `/Applications`.
2. **Sessions are keyed by working directory.** `voice-agent.sh` MUST `cd "$HOME"` before calling `claude`, or `--resume <id>` fails with "No conversation found" when the app spawns it from `/`. It also falls back to a fresh session if a resume returns empty — keep that fallback.
3. **Hotkey is a bare modifier** (Right ⌘, keyCode 54) → detected via `NSEvent` global `.flagsChanged` monitor, which *requires* Accessibility. A bare modifier cannot be a Carbon hotkey; don't "simplify" it to `RegisterEventHotKey`.
4. **Don't block the main thread** on `claude` (it takes seconds). Execution runs on a background queue; UI/state updates dispatch back to main.

## HUD / UX invariants (per user)

- Compact card, **top-right under the menu bar** (`visibleFrame`, 360×92). Not centered, not large.
- **No "Done" state** — the reply phase shows only the orb + streamed text.
- Reply is **streamed in a rolling ~10-word window synced to TTS** (`willSpeakRangeOfSpeechString`), never dumped in full. Card fades when speech ends.
- Orb colors: blue=listening, violet=thinking, green=speaking, rose=error.

## Conversation rule

Resume the stored session if `last_used < 1h` **and** `context_tokens < 300k`, else start fresh. State: `~/.claude/voice/session.json`. Token proxy = input + cache_read + cache_creation + output from the JSON `usage`.

## Related

`~/.claude/voice/run-voice-command.sh` is a separate, notification-based runner for a Spokenly-dictation path (not used by the app).
