# Architecture

Keyer separates macOS capture and UI from two provider-neutral capabilities:

```text
microphone → SpeechTranscriptionProvider → transcript → clipboard + focused input
                                                   ↘ TextGenerationProvider → cleanup
meeting audio → SpeechTranscriptionProvider → TextGenerationProvider → local Markdown
```

`DictationCoordinator` owns the session state machine and starts `AudioCaptureService` before any network work. `MeetingCoordinator` owns pause, resume, retry, and archival state. Both use the same OpenRouter connection pool, but they depend only on `WaveCore` protocols.

## Cloud providers

OpenRouter is the first BYOK adapter. `OpenRouterSpeechTranscriptionProvider` uses the dedicated transcription endpoint. `OpenRouterLanguageModelProvider` implements the generic text-generation contract, spoken cleanup, and structured meeting summaries. A future provider supplies the same capability protocol and its own optimized transport.

The OpenRouter API key is stored in the local Keychain, and preferences use local UserDefaults. Speech and text models are selected independently.

## Performance and delivery

- PCM16, 16 kHz, mono capture starts immediately
- authorization is prewarmed while recording
- one ephemeral `URLSession` reuses connections with a bounded per-host pool
- transient network, rate-limit, and server failures retry once
- short dictations use one multipart upload
- large WAV files are split below the provider limit and processed three at a time
- cleanup is skipped unless the transcript contains a likely correction, repetition, filler, or dictated list
- meeting audio remains available for retry until transcription, summary, and local history writing succeed

## Storage

Every successful dictation or meeting becomes one Markdown file under `Documents/Keyer` with YAML front matter. Dictation audio is not archived. Failed meeting audio remains temporary only while retry is available. The optional server stores explicitly shared transcript text in SQLite and renders public share pages.

## macOS

The app uses Swift 6 complete concurrency, native SwiftUI Settings and menu-bar scenes, AVFoundation capture, a global event tap, Accessibility insertion, Hardened Runtime, and macOS 26 as the deployment target.
