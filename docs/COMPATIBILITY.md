# Text Insertion Compatibility Matrix

The implemented order is direct AX selected-text replacement, clipboard plus Command-V when the original app is still frontmost, then clipboard-only recovery. The direct path preserves the original destination across app changes. If the original element no longer exists, the transcript remains on the clipboard and is never inserted twice.

| Destination | AX direct | Clipboard paste | Status |
|---|---|---|---|
| Safari fields/contenteditable | Unmeasured | Unmeasured | Test required |
| Chrome fields/contenteditable | Unmeasured | Unmeasured | Test required |
| Notes | Unmeasured | Unmeasured | Test required |
| Mail | Unmeasured | Unmeasured | Test required |
| Messages | Unmeasured | Unmeasured | Test required |
| Slack | Unmeasured | Unmeasured | Test required |
| Terminal | Unmeasured | Unmeasured | Test required |
| iTerm | Unmeasured | Unmeasured | Test required |
| Xcode | Unmeasured | Unmeasured | Test required |
| Visual Studio Code | Unmeasured | Unmeasured | Test required |
| Cursor | Unmeasured | Unmeasured | Test required |
| Native AppKit fields | Unmeasured | Unmeasured | Test required |
| Native SwiftUI fields | Unmeasured | Unmeasured | Test required |

For each cell, test replacement of a selection, insertion at start/middle/end, multiline input, destination app switch, cursor movement during transcription, destination closure, and concurrent clipboard change. Record OS/app versions and median dispatch-to-visible latency.
