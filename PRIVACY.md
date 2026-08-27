# Privacy

Keyer records microphone audio only while dictation or meeting recording is active. Audio is sent to OpenRouter and the upstream provider selected for the configured model so it can be transcribed. If spoken-text cleanup or meeting summaries are enabled, the relevant transcript is also sent for text generation.

The OpenRouter API key is stored as a synchronizable password in Keychain and can sync between the user's devices through iCloud Keychain. It is never stored in app preferences or iCloud Drive. Portable preferences use iCloud key-value storage. Hardware-specific preferences, including the selected microphone and login item, remain local to each Mac.

Completed dictations and meetings are saved as Markdown in the user's iCloud Drive. If iCloud is unavailable, Keyer keeps a local pending copy until synchronization succeeds. Dictation audio is not archived. Meeting audio is retained temporarily only while processing can be retried, then removed after success or discard.

OpenRouter and upstream provider handling, retention, and billing are governed by their policies and the user's routing choices.
