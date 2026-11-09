# A learned Vocabulary is the core, and Prompt Shaping is one of its readers

*Status: Proposed (draft, 2026-11-09). Not ratified. Fork-first; numbered in
the shared space per ADR-9000, so renumber on collision with upstream.*

Talkify gains a **Vocabulary**: one global list of terms the user wants spelled
their way, each carrying the heard forms the recognizer produced for it. The
list grows mainly by learning from the user's own corrections (ADR-0010) and
is read by every layer that can use it. No single layer is the mechanism.

The question going in was whether Prompt Shaping should be the core: a
correction teaches the active Shaping Prompt, and the prompt carries the
glossary. Four measurements on this Mac say no, and say what is instead.

- `SpeechTranscriber`, the module Talkify uses, ignores
  `AnalysisContext.contextualStrings`: output byte-identical with and without
  them, reproducing upstream issue #19. `DictationTranscriber` honours them
  (5/22 to 13/22, and 10/36 to 19/36 in a second corpus), but its unhinted
  baseline is worse than `SpeechTranscriber`'s, so switching modules is gated
  on a test with the user's real voice.
- A glossary written plainly into a Shaping Prompt's pre-instruction fixed 36%
  of misheard terms with no false corrections on clean sentences, at 14
  entries. It fell to 16% at 200, and in 6 of 90 sentences it put in the wrong
  name or pasted the whole list.
- A separate vocabulary pass (code proposes sound-alike spans, the On-device
  model answers yes or no through guided generation, code applies) fixed
  25-32% with 6-8% false corrections on held-out data, and fixed terms the
  in-prompt list never touched.
- Letting the model rewrite freely with a vocabulary-only prompt doubled
  recall and put a dictionary term into 44% of clean sentences.

No layer passes about a third of misheard terms on its own, and the layers
fix different terms. What every layer needs is the same thing: the user's
terms plus the variants the recognizer actually heard for them. So the
Vocabulary is the core, and the learn loop exists to grow it. Prompt Shaping
reads it; it does not own it.

A correction never edits a Shaping Prompt's own wording. The prompt is the
user's writing, ADR-0008 keeps the framing out of their hands for a reason,
and an edit nobody can read back is not one the user can trust. What changes
over time is the generated vocabulary block a prompt receives, which the
template preview shows.

The Vocabulary is global, not per prompt. A name is spelled the same way
whatever prompt is picked and whichever language is spoken. A prompt can turn
the vocabulary block off; it cannot hold its own list.

## Consequences

- Readers, in pipeline order: the recognizer (`DictationTranscriber` plus
  contextual strings, only after the real-voice test passes); exact learned
  variants that contain a word no dictionary knows; the Shaping Prompt's
  vocabulary block when a prompt is picked; the yes-or-no pass when none is.
  Each is added behind the eval suite on `feature/shaping-vocabulary-eval`,
  and none ships on a number that suite has not reproduced.
- A heard form that is ordinary English ("tail scale", "your version") never
  applies without context. Measured: applying it blindly rewrote "lost her
  tail scale" and "Let me talk if I can".
- A learned entry stores text derived from dictation: the heard form. That is
  a second exception to "persists no recognized text", after history, and it
  is made the same way: only on the user's explicit accept, local, deletable.
- Entries also carry exclusions, heard forms the user has said must not
  become the term. They come from undoing a wrong correction (ADR-0010).
- The Vocabulary lives in a JSON file in Application Support, not
  `AppSettings`: variants, exclusions and revisions outgrow UserDefaults. This
  replaces the upstream `feature/vocabulary` storage choice and its
  `SpeechTranscriber` wiring; its prewarm-and-rebuild rule carries over.
- The model reads notes and descriptions only as judge context. Measured: a
  note in a free rewrite came back as text ("tail scale" became "the VPN mesh
  network").
