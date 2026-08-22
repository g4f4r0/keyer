# Profiling Instructions

Profile only the Release app target on a named supported Mac after granting production-equivalent permissions.

1. Use Time Profiler for launch, Fn down, recording, release/finalization, response decode, and insertion.
2. Use Allocations plus VM Tracker for idle before model load, warm-model idle, normal recording, inference peak, memory-pressure unload, and post-session settling. Run 1,000 short sessions and compare settled footprints.
3. Use Leaks across repeated HUD/settings/device cycles.
4. Use Energy Log/System Trace to verify no idle timers, display refresh, audio engine, GPU, or polling wakeups.
5. Inspect `com.keyer.app/pipeline` signposts and export raw traces. Do not add transcript/audio to trace labels.
6. Use Network Instruments for the first-use model download and iCloud history synchronization. Confirm no speech or transcript is sent to a third-party model service.

Measure at least 30 warm samples for p50 and 100+ for credible tails. Include first-use download and fresh-process model preparation separately. Record microphone format, input duration, WAV byte count, model, detected language, compute units, thermal state, and power mode. Never remove outliers unless the exclusion rule was defined before capture and the excluded values remain reported.
