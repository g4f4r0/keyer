# Phase Report

Status: local-first dictation pipeline implemented and installed for local testing

## Current production path

Keyer is a Swift 6/macOS 26 menu-bar app with immediate hold-to-talk capture, configurable shortcut and microphone, Escape cancellation, automatic 15-minute finalization, native HUD animation, deterministic local cleanup, guarded paste plus clipboard fallback, and Markdown/YAML iCloud history.

Hosted transcription and OpenRouter have been removed. Work Context and all screen/nearby-text capture have been removed. Language handling is automatic.

## Local transcription

FluidAudio 0.15.6 and Parakeet TDT 0.6B v3 int8 now provide the only speech path. The approximately 461 MB model downloads on first use into Keyer’s Application Support directory. Audio recording starts while model preparation continues. The model stays warm, unloads under memory pressure, and the obsolete Whisper cache is removed only after the replacement loads successfully.

The production configuration uses CPU + Neural Engine, four parallel long-form chunks, disk-backed streaming above 30 seconds, no mel history, no dual decoding, and seam-gap repair. A bounded retry resets transient decoder state once without risking duplicate insertion.

## Verification

- Swift Release build: passed
- Swift test suite: 27/27 passed
- automatic language smoke: English, Spanish, Portuguese, and English/Spanish code switch passed
- 1-hour stress: 10/10 passed, 17.25 s p50 and 17.76 s p95
- 2-hour stress: 5/5 passed, 29.35 s p50 and 29.54 s p95
- active long-form footprint: approximately 96–99 MB
- GPU alternative rejected after a 45.17-second / 1.82 GB 1-hour result
- transient download progress is throttled to whole percentages to avoid UI/task churn

## Storage

Every successful transcript is staged before insertion and synchronized as a human-readable Markdown document with YAML front matter into iCloud Drive. Filenames use UTC timestamps with millisecond precision and a numeric collision suffix only when necessary. Pending documents retry after successful dictation, every minute, and on launch.

## Remaining release gates

Representative human multilingual WER testing, MacBook Neo measurements, broad application and microphone coverage, two-Mac iCloud propagation, Developer ID signing, notarization, and final Instruments certification remain external release gates.
