# Performance Benchmarks

Measured August 22, 2026 on a MacBook Pro with Apple M4 Pro, 14 logical/physical cores, 24 GB RAM, macOS 26.5.2, Swift 6.2 Release build, FluidAudio 0.15.6, and Parakeet TDT 0.6B v3 int8.

## Method

The duration stress fixture is a deterministic 40.1-second sequence of synthetic English, Spanish, Portuguese, and code-switched speech with short silences, repeated without re-encoding discontinuities to exact 1-hour and 2-hour PCM16 16 kHz mono WAV files. This validates throughput, stability, seam handling, language metadata, and memory behavior; it is not a human-speech WER corpus.

Percentiles use Keyer’s nearest-rank implementation. Every timed run used the production CPU + Neural Engine path, concurrency 4, disk-backed streaming, mel context off, dual decode off, and seam-gap repair on.

## Results

| Workload | Runs | Inference p50 | Inference p95 | Failures | Active peak footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 hour | 10 | 17.25 s | 17.76 s | 0 | 99.0 MB |
| 2 hours | 5 | 29.35 s | 29.54 s | 0 | 95.9 MB |

The separate single-run 2-hour measurement completed in 30.68 seconds at about 91.2 MB active footprint. The raw 2-hour WAV is 230,400,078 bytes, confirming that the streaming path does not retain the entire decoded float waveform.

The 10 one-hour inference values in milliseconds were:

```text
17285.23, 17265.10, 17533.13, 17757.42, 17248.83,
17180.03, 16972.13, 16728.01, 16885.86, 16709.68
```

The five two-hour values were:

```text
29536.68, 29348.69, 29390.68, 29089.04, 29166.02
```

## Tuning evidence

| Configuration, 1-hour fixture | Inference | Active peak footprint |
| --- | ---: | ---: |
| ANE, concurrency 2 | 20.12 s | 73.9 MB |
| ANE, concurrency 4 | 17.53 s | 99.5 MB |
| ANE, concurrency 6 | 16.61 s | 100.5 MB |
| ANE, concurrency 8 | 16.53 s | 118.9 MB |
| GPU, concurrency 4 | 45.17 s | 1.82 GB |

Concurrency 4 remains the production default because it stays within the requested 16–23 second one-hour range, matches FluidAudio’s supported default, scales cleanly to 2 hours, and avoids oversubscribing lower-end Apple Silicon. Concurrency above 4 produced little or no 2-hour improvement. GPU placement was rejected.

Dual-decode arbitration did not change the 40-second transcript and raised inference from about 0.20 seconds to 0.72 seconds, so it remains disabled.

## Language smoke tests

- English-only: passed
- Spanish-only: passed
- Portuguese-only: passed exactly
- English → Spanish → English: passed exactly and reported `en, es`
- 40-second English/Spanish/Portuguese sequence: nonempty and reported `en, es, pt`

A tightly concatenated synthetic sequence showed Romance-language drift in two segments even though each segment transcribed correctly in isolation. A representative real-speaker corpus remains the release gate for accuracy and WER claims.

## Remaining release measurements

Run the same corpus on a MacBook Neo, validate real microphones and noisy rooms, complete broad insertion compatibility, and execute Developer ID/notarized Instruments runs before public release certification.
