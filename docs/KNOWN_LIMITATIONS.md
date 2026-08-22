# Known Limitations

- Input Monitoring changes are rechecked whenever Keyer becomes active; macOS may still require one relaunch after the user enables Keyer in System Settings
- Parakeet TDT 0.6B v3 is the only transcription model; a representative human multilingual corpus is still required before release claims about WER or accent coverage
- Synthetic English, Spanish, Portuguese, and code-switch fixtures pass, but synthetic voices are not a substitute for real microphones, accents, noise, or conversational speech
- MacBook Neo hardware performance has not been measured directly; the production ANE configuration and approximately 100 MB long-form active footprint are designed to remain viable on lower-memory Apple Silicon
- Bluetooth/USB hot-swap, sleep/wake, broad application insertion compatibility, and propagation to a second Mac require release certification coverage
- Local STT runs after key release rather than showing partial live text
- Cleanup is deterministic and conservative, so complex semantic self-corrections may be preserved instead of rewritten
- Developer ID archive, notarization, and distribution signing require release credentials
