# Maintain Swagatar-LLC/Talkify as a deployable fork

*Status: Accepted (2026-08-17). Fork-only, never submitted upstream. Numbered 9000 to
stay out of upstream's ADR number space, which our feature ADRs share.*

Swagatar contributes to Talkify through upstream pull requests against
tornikegomareli/Talkify. That is the delivery vehicle and it stays the
delivery vehicle. The fork exists for two other reasons: insurance, so
Swagatar can ship a working build if upstream stalls or diverges, and a
staging ground, where changes can soak on real machines before they are
proposed upstream.

The fork's `main` tracks `upstream/main`. Fork-only commits ride on top and
are rebased onto upstream after every sync; the fork never merges upstream
in, so history stays linear, matching upstream's own branch rule. A
fork-only commit either graduates (it becomes an upstream PR and is dropped
from the fork stack once merged) or it stays in the permanent fork-only set.
That set is deliberately small: this ADR, any feature upstream declines
(the prompt shaping alpha is the first candidate), and future
Swagatar-specific configuration. Anything not in that set that lingers on
the fork for more than one sync cycle is a smell.

If the fork ever ships its own build, it must not impersonate upstream's
update channel. Upstream's review of its own trust chain (issue #56,
tornikegomareli/Talkify) shows why: the `SUPublicEDKey` in `Info.plist`,
the `SUFeedURL`, and `release.sh` together form the single
remote-influenced code path into an unsandboxed, fully privileged process.
A Swagatar release therefore carries its own Sparkle EdDSA key pair (never
upstream's, and the private key stays out of every repo), its own appcast
served from an immutable per-tag release asset rather than a mutable
branch, its own bundle identifier, and its own signing and notarization
identity. The #56 hardening items (release-time public-key verification,
reviewed merges to the release path) apply to the fork's release pipeline
from day one, not retroactively.

## Consequences

- Rebasing rewrites the fork's published `main`; anyone tracking the fork
  force-pulls after a sync. Accepted, because a linear fork-only stack is
  what makes each commit an upstream PR candidate.
- Upstream renames and refactors land on the fork at every sync; the
  fork-only set is kept small precisely so rebase conflicts stay cheap.
- No fork build ships until the separate key pair, feed, and bundle
  identity exist. A build signed with upstream's identity or pointing at
  upstream's appcast is a bug, not a shortcut.
- Upstream's release blockers bind the fork too: the Pop sound set and the
  Siri-orb artwork must be replaced or dropped before any Swagatar release.
