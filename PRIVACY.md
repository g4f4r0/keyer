# Keyer Privacy Policy

Last updated: August 22, 2026

Keyer transcribes speech locally. On first use, it downloads an approximately 461 MB Core ML speech model from FluidInference’s repository on Hugging Face. Recording audio is not sent with that download and is never sent to a speech or AI provider.

Keyer itself:

- captures audio only while dictation is active
- keeps short recordings in memory; long recordings may use a private temporary WAV that is deleted immediately after transcription
- never archives recording audio
- stores the downloaded model under Keyer’s Application Support directory and provides a Settings action to remove it
- saves each successful original and cleaned transcript to the user’s private iCloud Drive as a human-readable Markdown document with YAML front matter
- stages transcripts in a private local pending queue and retries automatically when iCloud Drive is unavailable
- captures only the original editable destination needed for guarded paste; it does not capture screen, window, document, or nearby-text context
- performs optional spoken-text cleanup locally
- always writes the result to the clipboard, but does not maintain clipboard history
- has no OpenRouter, hosted speech, analytics, telemetry, advertising, or crash-reporting integration
- does not log audio, transcript text, clipboard contents, or model output

Optional local diagnostics contain timings, model ID, audio duration and size, buffer counts, insertion strategy, error category, and iCloud archive state. Transcript text is printed only by an explicit developer diagnostic flag.

After the model download, dictation and cleanup work offline. iCloud transcript history follows the user’s Apple Account, iCloud Drive availability, and settings.

Removing Keyer removes its app-owned model and local support data when the normal uninstall cleanup is performed, but does not automatically delete user documents in iCloud Drive. Users control those documents through iCloud Drive.
