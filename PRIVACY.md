# Privacy

Keyer records microphone audio only while dictation or meeting recording is active. Audio is sent to OpenRouter and the upstream provider selected for the configured model so it can be transcribed. If spoken-text cleanup or meeting summaries are enabled, the relevant transcript is also sent for text generation.

The OpenRouter API key is stored in this Mac's Keychain. It is never stored in app preferences or transcript files. Preferences remain local to this Mac.

Completed dictations and meetings are saved as Markdown under the user's `Documents/Keyer` folder. Dictation audio is not archived. Meeting audio is retained temporarily only while processing can be retried, then removed after success or discard. A transcript is sent to a Keyer sharing server only when the user explicitly creates a share link.

OpenRouter and upstream provider handling, retention, and billing are governed by their policies and the user's routing choices.
