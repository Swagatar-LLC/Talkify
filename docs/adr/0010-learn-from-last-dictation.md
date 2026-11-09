# Learn from the last dictation

*Status: Proposed (draft, 2026-11-09). Not ratified. Depends on ADR-0009.*

The Vocabulary grows from one gesture. The user dictates, fixes the words by
hand where they landed, selects or copies the fixed text, and presses the
**Learn shortcut**. Talkify compares that text with the **Last Dictation**,
proposes entries in the HUD, and adds only the ones the user accepts.

Comparing against the last dictation only, held in memory, is deliberate.
VoiceInk and Wispr Flow learn by watching the pasted field through
Accessibility; that sees every edit, including ones that were never
corrections, and it needs Talkify to keep reading someone else's document
after the session ends. One explicit gesture over one remembered dictation
reads nothing the user did not hand over, and the user is right there to
judge each proposal.

The Last Dictation lives in memory and nowhere else. It holds the words as
spoken, the words delivered, the vocabulary edits applied on the way, and when
the session ended. A new session replaces it; it expires after ten minutes,
on screen lock or sleep, and on quit. Nothing from it is written unless the
user accepts a proposal.

The input is the focused selection, read the way Read Aloud reads one. With
no selection, the clipboard is used only if it changed after the Last
Dictation was delivered, so a stale clipboard is never mistaken for a fix.

The comparison is a word-level alignment, and code decides what becomes a
proposal. A replaced span of up to four heard words, against up to three
corrected words, becomes a proposal when the two sound or look alike and the
corrected side is a term: it holds a word the system dictionary does not
know, or a capital the heard side lacked away from the start of a sentence.
Everything else is ignored as a rewrite: insertions, deletions, punctuation,
grammar between ordinary words, numbers, links and addresses, and any edit
that changed more than half the dictation. A corrected term with no
sound-alike heard span is offered as a bare term, with the HUD saying the
heard words were too different to learn. Proposals stop at five.

When the Last Dictation had a vocabulary edit and the user put the original
words back, the proposal is an exclusion: "swagger" must not become Swagatar.
That is how the measured false corrections get taught away.

The HUD shows one proposal at a time, heard form to term, in the shape it
already has. It takes key status without activating Talkify, as it does
while holding a Staged transcript: Return accepts, Delete skips, Escape ends
the review. A skipped proposal is remembered for the life of the app, not
forever, so a mistaken skip costs one dictation.

The Learn shortcut is recorded in the Shortcuts section like Read Aloud's,
unbound by default, and is also a status menu item, "Learn from Last
Dictation". It is ignored while Direct Dictation is active.

## Consequences

- Every accepted batch is one revision in the Vocabulary file. Undo reverts
  the newest revision; Settings lists revisions and can revert any of them.
  Single entries can be edited or deleted there too.
- With the Learn shortcut unbound and the menu item unused, nothing in this
  ADR runs.
- Shaping rewrites are not corrections. Edits that only undo shaping are
  ignored here; teaching a Shaping Prompt its style is a separate decision.
- The alignment and the classification are a pure value type with fixtures,
  following CLAUDE.md's testing rule. The thresholds start from the eval
  card's numbers and move only with that suite.
- The proposal review is a HUD state, so it obeys the HUD rules: one shape,
  no resize mid-state, Reduce Motion respected.
