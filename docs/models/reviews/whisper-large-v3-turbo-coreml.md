# Review: Whisper large-v3-turbo (`whisper-large-v3-turbo-coreml`)

Listed as `available` on synthetic evidence under ADR-9001. Real-voice numbers from the
soak replace these; the same gate holds for both.

Reviewers: `t_c8121969` (verify card: independent re-run, network audit, adversarial
review) and `t_47119487` (slice 4: the Whisper Recognizer and its first corpus gate), on
the Swagatar talkify-oss board. Date: 2026-11-11.

## Gate, re-measured

Corpus `hint-spike-corpus`, `corpus.json` SHA-256 `b3811fe4…a93a`, 48 synthetic clips,
36 term targets, 18 controls. M4 Max, 48 GB, macOS 27.2.1 (26B131), Xcode 27.2,
WhisperKit 1.1.1. Scored by the corpus harness and again by a separate script written
from `corpus.json`'s rules; both agree.

| Gate (ADR-9001) | Measured | Result |
|---|---|---|
| Terms at least 10 points over Apple's best arm | 32/36 (88.9 %) against 26/36 (72.2 %): +16.7 points | pass |
| Every control unchanged | 18/18 unit-normalised; 15/18 strict, the 3 being "3mm" formatting Whisper writes with no prompt as well | pass |
| p90 latency at or under 1.0 s | key release to insertion, 48 sessions: p50 821 ms, p90 837 ms. Whisper's finish alone: p50 656, p90 675 ms | pass |
| Warm resident memory at or under 400 MiB | process peak 273 MiB on a warm load; 229 MiB sampled while transcribing | pass |

WER 1.2 % against Apple's 8.5 %. The 49-term Vocabulary through the hint planner scores
the same terms, controls and WER, with finish p90 807 ms. Silence, noise and three seconds
of zeros return no text. The first load on a Mac compiles for the Neural Engine: 220.7 s
here, with the process peaking at 742 MiB; Install pays it.

Apple's best arm (DictationTranscriber with contextual strings and a custom language
model) is re-scored from the cycle 1 spike's stored outputs, not re-run on macOS 27.

## Network

Every run above happened with the network denied, each after a positive control showed
the denial working:

- The corpus harness ran under `sandbox-exec` with `(deny network*)`. Its own TCP probe
  was refused with EPERM; it re-hashed, loaded and transcribed every clip.
- A test host sandboxed itself with the same rule, then rendered the live Settings window
  on the Recognizer pane and ran 96 whole Direct Dictation sessions on injected corpus
  audio, 48 on Apple Speech and 48 on this model. The kernel logged no network denial
  for that process between the controls and a closing probe.
- The Debug app launched under `sandbox-exec` and ran for 90 s with Apple Speech chosen,
  and 30 s with this model chosen but not installed. No denial was logged for it.

## Installer and catalog review

Tried against the installer and catalog: path traversal, symlinks in the model folder,
redirects off the allowlist, verify-then-load races, a partial write reaching the promote,
the size caps, and catalog entries the lint should refuse. The lint let through a model id
that names a folder outside the install root, so Delete could remove all of
`Application Support/Talkify`; it also missed install paths that collide on a
case-insensitive volume, a file beneath another file, a non-Core ML format and a missing
network-deny result. All five are fixed with tests (PR #11). The rest held, within the
threat model the installer states: it guards integrity, not a local attacker who can
already edit the app.
