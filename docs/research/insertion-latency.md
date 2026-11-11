# Insertion latency benchmark

Roadmap item 4. It measures the time from the trigger's release to the session's text
reaching insertion, for each Recognizer, over the 48 clips of the synthetic hint corpus
(16 kHz WAV, 1.4 to 2.9 s each, three voices).

## What it runs

`TalkifyTests/InsertionLatencyBenchmark.swift`. Every clip is a whole held Direct
Dictation session through `DirectDictationController`, `DictationRecognizers` and
`RecognizerFeed`, with the real Recognizer. Two things are stand-ins. The microphone is
the clip, played into the feed in 1,024-frame-at-48-kHz buffers, each handed over once
its audio would have been spoken. The paste is a closure that notes when the text
arrived. The release comes when the last buffer has been fed. Each pass runs one
uncounted warm-up session and leaves half a second between sessions.

The Vocabulary is the 49-term spike list, likeliest last, so Apple Speech gets all 49 as
contextual strings and Whisper gets the planner's 15-term prompt.

```
TEST_RUNNER_TALKIFY_LATENCY_CORPUS=<corpus>/wav \
TEST_RUNNER_TALKIFY_WHISPERKIT_FIXTURES=<folder holding openai_whisper-large-v3-v20240930_turbo_632MB> \
TEST_RUNNER_TALKIFY_LATENCY_VOCABULARY=<terms, one per line> \
TEST_RUNNER_TALKIFY_LATENCY_REPORT=<report>.json \
xcodebuild test-without-building -project Talkify.xcodeproj -scheme Talkify \
  -destination 'platform=macOS' -only-testing:TalkifyTests/InsertionLatencyBenchmark
```

The test fails when Whisper's p90 is over 1.0 s, the gate ADR-9001 set.

## Results

M4 Max, macOS 27.2.1, 2026-11-11. Nearest-rank percentiles over 48 sessions, two runs.

| Recognizer | Run | p50 | p90 | max | mean |
|---|---|---|---|---|---|
| Apple Speech | 1 | 53 ms | 64 ms | 110 ms | 56 ms |
| Apple Speech | 2 | 55 ms | 62 ms | 70 ms | 55 ms |
| Whisper large-v3-turbo | 1 | 820 ms | 835 ms | 843 ms | 820 ms |
| Whisper large-v3-turbo | 2 | 822 ms | 840 ms | 856 ms | 822 ms |

Whisper adds about 0.77 s at the median. That is more than the roughly 0.5 s extra cycle 3
accepted, though under the 1.0 s p90 gate it was accepted with, in both runs. Loading and
warming it took 3.0 s in run 1 and
139 s in run 2, which recompiled for the Neural Engine after the full test suite had run
in between; why that cache was dropped is not known. Sessions run on Apple Speech while a
load is under way, so neither number reaches a keypress.

Whisper's time barely moves with clip length: the encoder runs a full 30-second window
whatever the session holds, so a short dictation pays the same as a long one.

## What it does not measure

The paste itself (pasteboard write, the synthesized Command-V, and the target
application's handling of it) is the same for both Recognizers and is not in these
numbers. Neither is a live microphone: dictating into a real application by holding Fn
cannot be automated here, so how either Recognizer feels on a real voice is unknown
until the soak.
