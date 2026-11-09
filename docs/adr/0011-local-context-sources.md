# Local Context: terms that stay current without being typed

*Status: Proposed (draft, 2026-11-09). Not ratified. Depends on ADR-0009. Each
source below ships separately and off by default.*

The Vocabulary holds what the user approved. **Local Context** holds terms
that are probably relevant now: the names in a document the user is looking
at, today's meeting attendees, a project's word list. It feeds the same
readers as the Vocabulary, ranked below it, and it is never stored as
Vocabulary unless the learn flow promotes a term.

Four sources, from least to most reach:

1. A **context folder** the user picks. Talkify reads plain-text and
   Markdown files there and takes terms from them, one per line or in the
   Vocabulary export format. It watches the folder and re-reads on change.
   This is the path for a stream that stays current: any tool the user runs,
   a note export, a script, an agent, can write that folder, and Talkify
   only reads it. No account, no request, no new permission.
2. **The focused window**, read through the Accessibility permission Talkify
   already holds, at session start. Proper nouns and unknown words found with
   `NLTagger` become session-only context. Nothing is kept after the session.
3. **Contacts**, names only, behind its own permission.
4. **Calendar**, today's event titles and attendee names, behind its own
   permission.

Every source has its own toggle in a Context section, and that section shows
exactly which terms Talkify would use right now and where each came from.
Nothing leaves the Mac. Nothing a source produced is persisted by Talkify;
the context folder is the user's own files.

Budgets come from measurement, not taste. Contextual strings diluted at 200
and Apple documents 100, so the recognizer gets at most 100 terms. The
Shaping Prompt's vocabulary block fixed the most at 14 entries and degraded
past 50, so it gets at most 30, chosen per dictation by which ones look like
something in the transcript. The yes-or-no pass sees at most 8 candidates.
Rank is Vocabulary first, then the focused window, the context folder,
Calendar, Contacts, and newest within each.

## Consequences

- The recognizer's list must be set before audio starts, and a new
  `setContext` replaces the old one. Whether a prewarmed analyzer can take
  new context between prewarm and keypress is unmeasured; until it is, the
  window source feeds only the post-recognition readers.
- Folder terms refresh within seconds of a file change. Contacts and
  Calendar refresh on their store-changed notifications. Window terms are
  per session by construction.
- Reading the focused window is a new use of Accessibility. It is opt-in,
  and secure fields and password managers are skipped the way Direct
  Dictation already skips them.
- More sources do not mean better spelling. Past the budgets above, every
  measured reader got worse, so the ranking decides what is left out.
