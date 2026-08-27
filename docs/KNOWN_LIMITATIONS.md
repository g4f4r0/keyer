# Known Limitations

- An OpenRouter API key and network connection are required for transcription and meeting intelligence
- Provider latency, availability, retention, and billing depend on the selected OpenRouter model and upstream provider
- The current model list is a curated benchmark set; defaults remain provisional until multilingual human-audio quality, p50, p95, and cost testing is complete
- Large recordings are split to stay below provider upload limits; representative meeting-boundary quality testing remains required
- Meeting capture currently records the selected microphone; system-audio capture remains a separate production gate
- Input Monitoring changes may require one relaunch after enabling Keyer in System Settings
- Bluetooth and USB hot-swap, sleep and wake, broad insertion compatibility, notarization, and share-server deployment still require release certification
