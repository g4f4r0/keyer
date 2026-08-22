# Reference Audit and Baseline

Audit date: August 22, 2026. Reference: `hoomanaskari/mac-dictate-anywhere`, default branch shallow checkout at the then-current HEAD.

## Architecture map

The reference uses a SwiftUI/AppKit menu-bar app, a CGEvent tap hotkey service, AVAudioEngine/AVCapture audio paths, local FluidAudio transcription coordinators, AX plus clipboard insertion, overlay windows, transcript cleanup providers, model management, settings/history views, and Sparkle updating.

## Dependency and feature audit

- Swift source: 19,288 lines at audit time.
- Swift packages: FluidAudio and Sparkle.
- Bundled content: two variable fonts and multiple audio test fixtures.
- Features outside Wave scope: alternate local ASR models, local/remote cleanup providers, transcript history databases, vocabulary management, live preview, updater, and broad language/input-source controls.

## Baseline build

The required Release build was attempted with signing disabled. It did not reach compilation because the installed Xcode 26.6 could not load `IDESimulatorFoundation`; its framework expected a symbol absent from the installed `DVTDownloads.framework`. This is a local Xcode installation mismatch, not a measured reference-project failure.

Therefore launch time, idle/recording memory, CPU, wakeups, and latency are **not measured**. No values are inferred.

## Decision

Clean implementation. A reduced fork would begin with substantially more excluded code/dependencies than required code, increasing audit surface, binary size, memory risk, and maintenance cost. No reference source was reused, so no reference attribution is required in binary notices beyond documenting the audit.
