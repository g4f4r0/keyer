<p align="center">
  <img src="Resources/KeyerIcon.png" width="128" height="128" alt="Keyer icon">
</p>

<h1 align="center">Keyer</h1>

<p align="center">Fast BYOK dictation with local Markdown history</p>

Hold Fn, speak, and release. Keyer transcribes through your provider key, copies the text to the clipboard, and pastes it into the focused field when macOS allows it.

Keyer is built around two provider-neutral capabilities: speech transcription and text generation. OpenRouter is the first BYOK adapter, with independent model selection for speech and text work. Language detection is automatic, including mixed-language speech.

## Local history

Each completed dictation or meeting is stored under `Documents/Keyer` as a Markdown file with YAML front matter. The files remain readable without Keyer.

The optional [`server`](server/) is a minimal TanStack Start, Bun, and SQLite app for public share links.

## Performance

Recording starts locally without waiting for the network. Keyer reuses one connection pool, prewarms authorization while you speak, retries one transient delivery failure, and sends long recordings in bounded concurrent chunks. Model candidates will be benchmarked for p50, p95, accuracy, and cost before defaults are finalized.

## Requirements

- Apple Silicon Mac
- macOS 26 or newer
- Xcode 26.6 or newer for local builds
- OpenRouter API key
- Microphone, Accessibility, and Input Monitoring permissions

## Build

```sh
swift test
./scripts/build.sh
open "build/Release.noindex/Keyer.app"
```

You can also open `Keyer.xcodeproj` and run the `Keyer` scheme.

## Behavior

- Fn is the default shortcut and can be changed in Settings
- Escape cancels the current recording
- A dictation finalizes automatically at 15 minutes
- Speech and writing models can be selected independently in Settings

## License

[MIT](LICENSE). Third-party icons keep their original licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
