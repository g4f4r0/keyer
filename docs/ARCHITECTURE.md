# Architecture

## Ownership

- SwiftUI owns the menu-bar and system Settings scenes
- `DictationCoordinator` is main-actor isolated and owns pipeline lifecycle
- `DictationStateMachine` scopes every asynchronous event to one session UUID and rejects stale completions
- `AudioCaptureService` owns a device-stable `AVAudioEngine`, preallocated ring, reusable converter, and bounded PCM accumulator
- `LocalTranscriptionService` is an actor that downloads, loads, and serializes FluidAudio’s Parakeet TDT 0.6B v3 pipeline
- `TextNormalizer` performs conservative deterministic cleanup without a language model
- `TextInsertionService` captures only the original editable Accessibility element, always writes the clipboard, and attempts guarded native paste
- `TranscriptArchiveService` atomically stages Markdown locally and coordinates the visible iCloud Drive write

## State machine

```text
launching → missingPermissions → ready
ready → preparing(session) → recording(session) → finalizingAudio(session)
→ preparingTranscription(session) → transcribing(session) → inserting(session) → ready
                                              ↘ recovering(session) → ready
any active session → cancelled / failed → ready after prerequisites are rechecked
```

Only one session can be active. Fn release, the 15-minute limit, Escape, and asynchronous completions all compete through the same state guard, so only one terminal path wins.

## Audio and performance

- capture format: PCM16, 16 kHz, mono, WAV
- dictation maximum: 15 minutes; reaching it finalizes and transcribes instead of cancelling
- warning: amber HUD treatment during the final minute
- real-time ring: 128,000 samples, about 256 KB
- recording begins before model preparation completes
- short WAVs decode directly to normalized samples
- longer WAVs use FluidAudio’s disk-backed streaming path, with temporary files removed after inference
- Parakeet encoder: int8 on CPU + Neural Engine
- long-form concurrency: 4
- streaming threshold: 30 seconds
- mel chunk context: off
- dual decode: off
- seam-gap repair: on
- a single transient inference retry resets decoder state before retrying

The approximately 461 MB downloaded model lives under `~/Library/Application Support/com.keyer.app/Models`. It remains warm for low latency, consumes no inference CPU while idle, unloads under memory pressure, and can be removed in Settings. Successful migration removes the obsolete Whisper cache only after Parakeet is loaded.

## Language behavior

Language selection is always automatic. Keyer does not provide a language picker, language hint, screen context, work context, or vocabulary injection. This avoids biasing mixed-language speech toward a selected language. The transcript’s language metadata is derived in spoken order for the iCloud document.

## Storage

Every successful dictation becomes one Markdown file in iCloud Drive. YAML front matter contains stable metadata such as kind, creation time, languages, duration, and model; the body contains the transcript. A private pending copy survives iCloud outages and is removed after coordinated synchronization succeeds. Audio is never archived.

## Security and packaging

The app enables Hardened Runtime, microphone access, macOS 26 deployment, and Swift 6 complete concurrency checks. It publishes an iCloud Drive Documents scope. The app is intentionally not sandboxed because global event taps and cross-app Accessibility insertion are core behavior.

## macOS 26 appearance

Settings use the system `Settings` scene, toolbar-style `Tab`, grouped `Form`, `Section`, `LabeledContent`, and standard controls. The bespoke recording HUD uses native SwiftUI animation and a constrained glass treatment; the near-limit warning is drawn inside the capsule to avoid square clipping artifacts.
