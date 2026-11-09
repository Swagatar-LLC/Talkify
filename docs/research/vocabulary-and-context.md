# Vocabulary and Local Context: design and implementation plan

Draft for review, 2026-11-09 (card t_eb02067b). Decisions are in ADR-0009,
ADR-0010 and ADR-0011; this file holds the detail and the slices.
Labels: [V] verified by a measurement or file read, [A] asserted (reasoned,
not measured), [U] unknown.

## 1. Is Prompt Shaping the core?

No. The card asked to design "Prompt Shaping + Context" if the evidence
supported it, and to say so if it did not. It does not, for spellings. The
core is the learned Vocabulary; Prompt Shaping is one of four readers.

| reader | best measured | false corrections | source |
|---|---|---|---|
| `SpeechTranscriber` + contextual strings | no effect, byte-identical | 0 | t_b5e423af, t_6976e66b [V] |
| `DictationTranscriber` + contextual strings | 5→13/22; 10→19/36 | 2/22 control; 0/18 protected | t_b5e423af, t_6976e66b [V] |
| `DictationTranscriber` baseline, no hints | 3/36 vs ST 10/36 | 0 | t_6976e66b [V] |
| Shaping Prompt + plain list in pre-instruction, 14 entries | 36% (31/87) | 0/90 clean; 6/90 wrong term in term sentences | t_223bfb77 held-out [V] |
| same, 200 entries | 16% | 0/90 | t_223bfb77 [V] |
| yes/no vocabulary pass, 14 / 50 entries | 25% / 32% | 7% / 6% | t_223bfb77 held-out [V] |
| vocabulary-only free rewrite | 49% | 44% | t_78833387 [V] |
| exact learned variants, no model | 30% | 12% | t_78833387 [V] |

All four corpora are synthetic `say` voices, small n; differences under ~10
points are noise [A]. The arms fix different terms ("tail scale" only by the
list, "Borno"→Vorno only by the pass), so a union should beat each, but that is
unmeasured [U]. The learn loop matters in every arm because learned heard forms
are the main recall lever (t_78833387) [V for that corpus].

Jeff's UX survives intact. What changes is where a correction goes: into the
Vocabulary, which the Shaping Prompt then reads, not into the prompt's wording.

## 2. Data model [A]

```
Vocabulary: Codable                      // Application Support/Talkify/vocabulary.json
  entries: [VocabularyEntry]
  revisions: [Revision]                  // newest last, capped at 200
VocabularyEntry: Codable, Identifiable, Sendable
  id: UUID
  term: String                           // ≤ 64 chars, exact spelling inserted
  heardForms: [HeardForm]                // recognizer output that meant this term
  exclusions: [String]                   // heard forms that must NOT become it
  note: String?                          // ≤ 60 chars, judge context only, never inserted
  origin: typed | learned | promoted     // promoted = came from Local Context via learn
  createdAt, updatedAt
HeardForm: { text, isOrdinary: Bool, addedAt }
Revision: { id, date, kind: learn | edit | import | revert, changes: [EntryChange] }
```

- `isOrdinary` is computed per heard form with `NSSpellChecker`: true when every
  word in it is a dictionary word ("tail scale", "your version"). Only
  non-ordinary heard forms ("Torniquet", "Gamorelli") may apply without a model
  [A; motivated by the "tail scale" false correction, V].
- No usage counters persisted (CONTEXT.md no-persistence line). Rank by
  `updatedAt` [A].
- Export/import is the same format the context folder reads (§6), so a file
  can move between the two.

## 3. Last Dictation retention [A]

```
LastDictation: Sendable                  // memory only, owned by DirectDictationController
  spoken: String                         // finishRecognition() output
  delivered: String                      // what insertText received
  vocabularyEdits: [AppliedEdit]         // span in spoken, heard text, term, entryID
  promptID: String?                      // shaping pick, so shaping-only edits can be ignored
  endedAt: Date
  deliveredChangeCount: Int?             // pasteboard count after delivery, for the stale guard
```

Set just before `recordHistory` in `finishRecognition`
(`DirectDictationController.swift:800` on main) [V for the line]. Cleared by:
the next session's finish, 10 minutes elapsed (clock seam, `DeadlineClock`
exists), `NSWorkspace.screensDidSleepNotification` /
`com.apple.screenIsLocked`, quit, and Escape-cancelled sessions do not set it.
Translated sessions keep `spoken`; learning compares against the language the
user is fixing, so a translated session is learnable only if the correction
aligns to `delivered` and is then mapped no further (open question 3).

## 4. Correction diff [A, thresholds to be pinned by tests]

`CorrectionDiff` is a pure value type in `Talkify/Vocabulary/`.

1. **Tokenize** both texts into words with trailing punctuation split off;
   keep original casing, align on a case- and diacritic-folded key.
2. **Align** corrected against `delivered` and against `spoken` (Myers or LCS on
   folded keys). Use the `spoken` alignment for heard forms, because that is
   what the recognizer will produce again. A hunk present against `delivered`
   but absent against `spoken` is the user undoing a shaping or vocabulary
   edit.
3. **Hunks**: maximal runs of replace operations. Pure insert or delete hunks
   are ignored.
4. **Abort** when more than 50% of `spoken` tokens are in hunks: "Too different
   to learn from".
5. **Classify** each replace hunk (heard H, corrected C):
   - Ignore if |H| > 4 words, |C| > 3 words, or |C| > 64 chars.
   - Ignore if C is digits, a URL, an email, or punctuation-only.
   - Ignore if every word of C is a dictionary word and C has no capital beyond
     sentence-initial position (grammar and word-choice edits: their→there).
   - Ignore a case-only change at sentence start.
   - **Term proposal** when C qualifies as a term and the space-stripped,
     folded H and C pass `letterSimilarity ≥ 0.4 OR phoneticSimilarity ≥ 0.6`.
     These are looser than the vocabulary pass's apply gates (0.5 / 0.68)
     because a human accepts each one [A].
   - **Bare-term proposal** when C qualifies but similarity fails ("an emotion
     era" → Mnemosyne): offer the term without a heard form and say why.
   - **Exclusion proposal** when the hunk reverts an `AppliedEdit` (delivered
     had the term, corrected has the heard text back).
   - Skip anything matching an entry's existing heard form or exclusion, or a
     proposal skipped earlier this launch.
6. **Merge** into an existing entry when C equals its term (case-sensitive);
   otherwise a new entry. Cap at 5 proposals, terms before exclusions.

Fixtures come from the eval corpus `heard` fields and Jeff's examples:
"Talk if I"→Talkify (term), "Ren"→Wren (term, ordinary heard form), "their"→
"there" (ignored), "3 mm"→"3 millimeters" (ignored), "swagger" reverted
(exclusion), a rewritten sentence (abort).

## 5. HUD flow and the Learn shortcut [A]

Input order: `FocusedSelectionReader` selection → clipboard only when its
`changeCount` is newer than `deliveredChangeCount` → otherwise HUD "Nothing to
learn from". No Last Dictation → "No recent dictation". Secure field → refused,
like Read Aloud.

States (a small reducer, tested like `DictationSessionMachine`):
`idle → reviewing(proposals, index) → saved(count) | nothingToLearn(reason) → idle`.

- Each proposal shows `heard → Term` in the shaping band's caption style; an
  exclusion shows `keep "swagger"`. A bare term shows `add Mnemosyne` with a
  second line "too different to learn how it sounds".
- Return accepts, Delete skips, Escape ends (accepted so far are kept). Mouse:
  the two words are buttons. The HUD takes key status without activating
  Talkify, the Staged-transcript precedent (CONTEXT.md) [V that it exists].
- After the last proposal: "Learned 2" for about two seconds, then retract.
  One revision per review.
- A 20-second idle timeout ends the review, pausing while the pointer is over
  the shape.
- Ignored while Direct Dictation records; a Dictation Trigger press during a
  review ends the review first.

Shortcut: recorded in Shortcuts like Read Aloud (`AppSettings.Keys
.readAloudBinding` pattern) [V for the pattern], unbound by default, plus a
status menu item. Lean: suggest ⌃⌥L in the empty recorder's hint, bind nothing
[A].

## 6. How a prompt "meaningfully modifies itself" [A]

The user's prompt text never changes. What the prompt receives changes:

- `ShapingPrompt` gains `usesVocabulary: Bool` (default true; decoded as true
  for stored prompts). When true and the Vocabulary or Local Context has terms,
  `request(wrapping:)` appends a generated block after the pre-instruction:
  "Spell these names exactly as written here when the transcript means one of
  them: A, B, C." That wording is the measured 36% / 0% arm [V].
- The block lists at most 30 terms: first every term with a candidate span in
  this transcript (the pure finder from the eval branch), then by rank. The
  editor's template preview shows the block as it would be now.
- **Keep-spellings check**: every term already present before shaping must
  survive it; if one is missing, insert the unshaped text. Lean only: the
  measured pass→shaping arm lost clean sentences (61/90 unchanged) [V], so
  this ships behind the eval.
- Versioning and undo are the Vocabulary's revisions (§2). "What did my prompt
  look like last Tuesday" is answered by the revision list plus the unchanged
  prompt text.
- Global, not per prompt (ADR-0009). Per-prompt lists were considered: the same
  name would need adding to every prompt, and a name misspelled under one
  prompt but not another is a bug, not a feature.

## 7. Local Context assembly [A]

```
ContextSnapshot  // built at session start, pure ranking, tested
  recognizerTerms: [String]   // ≤ 100: Vocabulary terms first, then sources
  candidatePool: [Term]       // everything ranked, for post-recognition readers
  provenance: [Term: Source]  // shown in Settings
```

| source | permission | freshness | budget share | persisted by Talkify |
|---|---|---|---|---|
| Vocabulary | none | on change | first | yes (user-approved) |
| focused window (AX, `NLTagger` `.nameType` + unknown words) | Accessibility (held) | per session | ≤ 30 | no |
| context folder (`.txt`, `.md`; one term per line or export format) | none (user-picked, security-scoped bookmark) | file watcher, 2 s debounce | ≤ 200 read, ranked | no; files are the user's |
| Calendar (today's titles, attendee names) | Calendar, own toggle | `EKEventStoreChanged` | ≤ 30 | no |
| Contacts (given + family names) | Contacts, own toggle | `CNContactStoreDidChange` | ≤ 100 read, ranked | no |

The context folder is the continuous-stream path: Jeff's agents can write
`talkify-context.md` there daily from Notion or Git, and Talkify needs no
integration [A]. Settings' Context section lists live terms with their source
and offers "Add to Vocabulary" per term (`origin: promoted`).

## 8. Implementation slices

Each slice is one card, one PR, testable alone. Gates in brackets.

| # | slice | test |
|---|---|---|
| 1 | `Vocabulary` model, JSON store, revisions, undo/revert, sanitize-on-read | pure unit tests |
| 2 | Vocabulary Settings section: list, add/edit/delete, revisions, export/import | store tests + preview |
| 3 | `CorrectionDiff` pure type with the §4 fixtures | pure unit tests |
| 4 | `LastDictation` retention in the controller, expiry via clock seam, lock/sleep clear | controller seam tests (`refactor/dictation-controller-test-seam` pattern) |
| 5 | Learn shortcut binding, status menu item, input acquisition (selection → fresh clipboard) | `KeyBinding` tests + acquisition unit with fake pasteboard |
| 6 | Learn review reducer (states, keys, timeout) | pure reducer tests |
| 7 | Learn review HUD state wired to 5 and 6 | manual, Reduce Motion pass |
| 8 | `usesVocabulary` + generated block in `request(wrapping:)` + template preview | `ShapingPrompt` tests; eval rerun [eval: ≥ 30% fixed, 0 false at 14 entries] |
| 9 | Non-ordinary heard forms apply without a model | pure tests; eval arm [false ≤ 2%] |
| 10 | Yes/no pass when no prompt is picked, behind a development setting | eval [beats raw WER, false ≤ 5%] |
| 11 | Keep-spellings check after shaping | eval [unchanged clean ≥ shaping-only] |
| 12 | E1: real-voice ST vs DT harness | **needs Jeff: ~30 dictations, ~20 min** |
| 13 | `DictationTranscriber` + contextual strings behind a setting | [12 shows no general-WER loss]; prewarm rebuild on change |
| 14 | `ContextSnapshot` ranking and budgets | pure tests |
| 15 | Context folder source + Context section with provenance | file-watcher test with temp folder |
| 16 | Focused-window source (session only) | AX fake; [E4 before feeding the recognizer] |
| 17 | Calendar and Contacts sources | permission-denied paths tested |

Order: 1, 3, 6 in parallel (pure); then 2, 4, 5, 7 (the loop works end to end
and only edits the Vocabulary); then 8 (first visible accuracy change); then
9-11 by eval; 12-13 when Jeff can record; 14-17 last. Slices 1-8 deliver
Jeff's UX.

## 9. Open questions for Jeff

1. Ship slices 1-8 first, with the Shaping Prompt block as the only accuracy
   reader? (Lean: yes. It is the best measured text-side arm and needs no
   module switch.)
2. Default Learn shortcut: unbound with a suggested ⌃⌥L, or bound? (Lean:
   unbound, matching "nothing changes for anyone who never opens the
   setting".)
3. Should translated sessions be learnable? (Lean: no in v1; the HUD says so.)
4. Context folder as the continuous-context path for Wren-generated term
   lists: acceptable as the only integration point? (Lean: yes; no network,
   no API.)
5. Upstream: offer ADR-0009-0011 upstream, or keep fork-only until slices 1-8
   soak? (Lean: fork-first, same as Prompt Shaping.)

## 10. Risks [A]

- Synthetic-voice evidence; Jeff's mishearings will differ. Slice 12 is the
  only real-voice check.
- The On-device model changes with macOS; the eval must be rerun on OS
  updates.
- Proposal thresholds are guesses until slice 3's fixtures pin them.
- CONTRIBUTING.md still says "no local inference models"; Prompt Shaping
  already contradicts it on the fork. Not this design's to fix, but upstream
  will raise it.
