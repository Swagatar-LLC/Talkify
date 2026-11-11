# Catalog Models are opt-in recognizers behind the Vocabulary's hint layer

*Status: Accepted (2026-11-10, Jeff, from the cycle 2 review). Fork-only under ADR-9000
and numbered in its space: it adds a second Swift package and reverses "No Whisper"
(`CONTRIBUTING.md`), both of which upstream settled. Proposed upstream only after a soak
with real-voice numbers.*

Talkify gains **Catalog Models**: open-weight speech recognizers the user can choose to
download from a list committed in this repository. Apple Speech stays the default and
the fallback. Nothing downloads unless the user asks for it, and recognition never
leaves the Mac.

The question going in was whether any open model is accurate enough to be worth a
download, a dependency and a reversed rule. Apple's SpeechTranscriber ties the best open
models on clean read English, so raw accuracy alone is not a reason. Vocabulary is.
SpeechTranscriber ignores contextual strings, so a learned Vocabulary (ADR-0009) cannot
reach it. On the cycle 1 corpus, Whisper large-v3-turbo with the Vocabulary as its
initial prompt spelled 32 of 36 hard terms and changed no control sentence, at 1.2 %
WER. Apple's best arm, DictationTranscriber with contextual strings and a custom
language model, spelled 26 of 36 at 8.5 %. Parakeet's keyword boosting spelled 31 of 36
at its defaults, but rewrote 11 of 18 control words ("rent" became "Wren"), so a
recognizer that biases needs the same do-not-touch discipline as every other Vocabulary
reader.

That corpus is synthetic speech. The first entry ships on the fork on that evidence,
labelled synthetic in the catalog; real-voice numbers from a soak replace it, and the gate
(at least 10 points of terms over Apple's best arm, every control kept, p90 finish latency
at or under 1.0 s, warm resident memory at or under 400 MiB) is held to both.

The first entry is Whisper large-v3-turbo, run through WhisperKit pinned to an exact
version (1.1.1) and confined to `Talkify/Whisper/`, as Sparkle is to `Talkify/Updates/`.
WhisperKit is called only with local paths and with downloading turned off. A Core ML-only runtime written in this repository
would avoid the package, but it is weeks of decoder work, spent only if upstream asks
for it. Core AI on macOS 27 replaces the package if the deployment target rises.

The catalog is a JSON file in the app bundle. Every file is pinned by repository,
commit, size and SHA-256 from Talkify's own manifest, never from the host. Each file is
hashed again at every load, and an entry is listed only with two reviewers, a
network-deny test result and measured numbers. A revocation ships as an app update. Only
Core ML formats are allowed in-process. Any other format needs an XPC service with no
network entitlement first.

The Vocabulary does not change shape for this. The recognizer reader of ADR-0009 becomes
a hint layer with one adapter per recognizer:
- DictationTranscriber gets contextual strings.
- Whisper gets a short prompt, at most 15 terms and 93 tokens, with the likeliest terms
  last. A 49-term prompt with its targets first dropped Whisper from 32 to 11 of 36.
  The token budget leaves a full 30 s window room for its words in Whisper's
  224-token decoder, measured with the model's own tokenizer.
- Parakeet, if it is ever listed, gets a boosting list with rescue off.

A pure planner chooses the terms. The readers after recognition, and the exclusions,
apply unchanged whichever recognizer ran.

## Consequences

- `CONTEXT.md` gains **Catalog Model**, kept apart from **Speech Model**, which stays
  Apple-managed. "No Whisper fallback" and "Talkify does not bundle or train speech
  models" are amended on the fork: Talkify still bundles none, and downloads one only
  on request.
- The README's "makes no network requests" becomes one honest sentence. Talkify connects
  for a Catalog Model once, when the user taps Download; nothing spoken is ever sent.
- The feature requires macOS 26.7 or later, past the CoreML CVE-2026-84624 fix.
  Earlier systems see Apple Speech only.
- A Whisper session finishes later than an Apple session: about 0.6 s per short clip
  measured, against 0.13 s. The insertion latency benchmark (roadmap item 4) must report
  both. Whisper also writes text on silence, so a voice-activity gate sits in front of it.
- The first load compiles for the Neural Engine, measured at 153 to 234 s. Install pays
  that cost, never the first Fn press.
- Every Catalog Model failure, whether files missing, a hash mismatch, revocation, an
  unsupported language or a load error, uses Apple Speech for that session and says so
  in Settings. Nothing fails silently or re-downloads on its own.
- Learned heard forms record which recognizer produced them, and the Vocabulary gains a
  ranking signal the hint planner can sort by.
- `SURequireSignedFeed` is turned on, because the catalog and its revocations now travel
  with the update feed.
- Every rebase onto upstream carries a package entry in `project.pbxproj`. That conflict
  hotspot is accepted.

