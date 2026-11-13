# Rolling Whisper replay: local review candidate

The final adapter decodes the latest five seconds of session-owned PCM after at least one second of new audio. Drafts are volatile HUD text, never insertion text. Decodes are serialized; finish retains the full recording. No microphone ownership or UI changes.

Independent review caught a speech-only flag that discarded drafts in the controller. Fixed with a failing-then-passing adapter → RecognizerFeed → controller → HUD-effect regression. Cancellation, next-session isolation, silence, duration cap, Vocabulary and full final PCM have regressions. Debug build passed; full suite: 737 passed, 9 skipped, zero failures, using ad-hoc signing because the development certificate is unavailable.

## Final five-second candidate

Apple M4 Max, macOS 27.2.1. Installed Catalog Model, WhisperKit 1.1.1, downloading disabled and inference network-denied. Two paced repetitions each of 2.142-second speech, 42.260-second concatenated speech and five-second silence. These are recorded synthetic fixtures, not live human acceptance.

| Measure | Batch | Five-second rolling |
| --- | --- | --- |
| First nonempty draft | none | 1.560–1.563 s |
| Long draft count | none | 33 each |
| Long draft cadence | none | median 1.036 s; maximum 3.545 s |
| Short finish | 680 / 703 ms | 1108 / 1106 ms |
| Long finish | 2057 / 2086 ms | 2002 / 2263 ms |
| After-load RSS | 185.5 MiB | 184.7 MiB |
| After-prewarm RSS | 214.9 MiB | 214.2 MiB |
| Sampled session peak RSS | 259.8 MiB | 256.8 MiB |
| Process lifetime peak RSS | 269.1 MiB | 267.9 MiB |
| Loaded physical footprint | 81.1 MiB | 80.7 MiB |

All six paced finals matched batch exactly; silence emitted no drafts or final text. Separate 48-clip corpus outputs also matched exactly: 32/36 terms, 18/18 unit-normalised controls (15/18 strict), 1.2% WER. Corpus p90 finish increased from 684 to 1344 ms: latency gate fails. Corpus warm RSS was 401/407 MiB, failing 400 MiB for both; lifetime peaks 760/765 MiB include model compilation. Fixed ordering and cache state prevent attributing these memory differences to rolling decoding. RSS/footprint are runtime measurements, not model allocation sizes.

A rejected fifteen-second prototype increased long finish to 3671–4568 ms. Five seconds reduces that cost but deliberately shows recent words, not a cumulative transcript.

**Remaining decision:** accept roughly 0.4–0.7 seconds additional short-session finish latency for provisional words, despite the one-second corpus gate, before authorizing any installed trial. Human speech/HUD acceptance remains untested. No installation, commits or publication performed.

## Reproduce

Run `python3 Tools/WhisperCorpusHarness/replay.py --help`; supply the installed Models root, existing hint-spike corpus, resolved SwiftPM cache and a fresh scratch output directory. No downloads or microphone are needed. Final raw evidence and exact source snapshots: `~/.hermes/cache/scratch/t_74e03601-replay-5s/`; fifteen-second evidence: sibling `t_74e03601-replay/`. Final source snapshot matches the working adapter byte-for-byte. The runner timed out during its corpus stage; retained paced runs completed, and both corpus runs were subsequently completed separately.
