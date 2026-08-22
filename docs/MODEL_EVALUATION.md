# Model Evaluation Report

Status: production local model selected and long-form performance validated on M4 Pro; representative human accuracy corpus pending

## Selection

Keyer uses Parakeet TDT 0.6B v3 int8 through FluidAudio 0.15.6. It was selected for its 25-language European coverage, automatic multilingual transcription, Apple Neural Engine execution, approximately 461 MB download, and long-form throughput.

Production settings are:

- encoder compute: CPU + Neural Engine
- parallel chunk concurrency: 4
- disk-backed streaming for audio longer than 30 seconds
- mel chunk context: disabled to avoid a persistent English prior during automatic multilingual decoding
- dual-decode arbitration: disabled because it did not change the stress transcript and increased 40-second inference from about 0.20 s to 0.72 s
- seam-gap repair: enabled for long-form boundary safety
- transient inference retry: one bounded retry after resetting decoder state

GPU encoder placement was rejected on the test M4 Pro: the 1-hour fixture slowed from 17.53 s to 45.17 s and active peak footprint rose from about 99 MB to about 1.8 GB.

## Accuracy evidence

English-only, Spanish-only, Portuguese-only, and an English → Spanish → English clip all returned the spoken languages without translation. A 40-second artificial sequence containing tightly concatenated synthetic voices exposed some Romance-language drift, so release accuracy claims remain gated on a private corpus of real speakers and natural pauses.

## Performance evidence

See [BENCHMARKS.md](BENCHMARKS.md). Ten 1-hour runs and five 2-hour runs completed without an empty result or inference failure.
