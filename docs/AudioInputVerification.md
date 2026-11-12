# Persistent audio input verification

Verified locally on 2026-11-11: MacBook Pro (Mac16,5), arm64, macOS 27.2.1 (26B131), Xcode 27.2. This is a local-fork verification record, not release acceptance. Nothing was installed, pushed or merged. OS input/output settings and the installed app's preferences were not changed. Probe audio was discarded.

## Integration onto Catalog Models main

### Tap rejection and nonblocking Settings startup (2026-11-12)

The preserved attended crash aborted during activation-driven idle-meter restart:
AVFAudio rejected a 48 kHz client tap against 24 kHz hardware. The earlier
explicit-format workaround is superseded, not validated by its historical passes.
Capture now installs a nil-format tap and converts each delivered buffer's format.
On macOS 27 with Xcode 27, the native NSError-returning overload reports tap
rejection instead of raising the legacy Objective-C exception. A disconnected-mixer
regression actually aborted with the old overload and passes with the correction;
it does not simulate a physical Bluetooth transition.

The opt-in `scripts/verify-audio-input-tap.py` compiles production sources with
readback-only diagnostics. Its explicitly labelled stale-snapshot injection failed
on the old source with zero audio at the 30-second bound, then passed all three
one-second checkpoints on the corrected source. Uninjected built-in and Yeti USB
runs matched requested/bound IDs on all three starts; each delivered ten Recognizer
buffers, 26 real-level snapshots and zero errors. All PCM was discarded. AirPods
were absent from the current inventory, so connected-playback isolation, acoustic
identity and the original Bluetooth transition remain unverified.

Settings start/stop/route requests now enqueue hardware work rather than block the
main thread. The dictation lease still synchronously releases the idle owner before
opening another. Semaphore-controlled regressions fail on the old blocking path
and pass after correction, including close-during-start, identical-request
coalescing and single-owner handoff. Queued recognition updates, failures and HUD
levels now reject retired session UUIDs after their MainActor hop. Red logs and
prior failures remain under `.verification`; current final suite/merge evidence is
recorded in `.verification/merge-handoff.md`.

### Bounded diagnostics and startup failure handling (2026-11-11)

The tracked probe now preserves one-second checkpoints for initial idle capture,
initial dictation, every policy switch and idle resumption, then observes the same
process for up to 30 seconds after the synchronous operation returns. It records
first-buffer and real-level timing; `.started` is not counted as audio.

The first baseline and production processes completed all 12 phases, but their
timing labels are provisional: independent review reproduced observer scheduling
that incorrectly counted post-deadline samples. Those logs lack every sample's
timestamp, so their exact checkpoint classifications cannot be recovered.

After correcting timestamp membership, eight deterministic observer cases passed.
One new production-source live run completed all 12 phases: four timely, eight
failed one-second checkpoints followed by same-process recovery, including late
idle resumption. It recorded 54 Recognizer buffers and 67 real-level snapshots,
with no persistent stall or reported error. Exact offsets remain in
`.verification/timing-live-production.log`. These observations do not explain all
earlier intermittent failures or prove a Bluetooth fix.

Production now reports an explicit no-first-buffer failure if a tap delivers no
nonempty buffer within ten seconds after engine startup returns. It does not
retry, bound synchronous Core Audio calls, or detect a stall after audio has
already arrived. Deadline state rejects retired generations and cancellation;
Direct Dictation also rejects failure callbacks from older sessions. Settings
retains the error, and dictation cancels without inserting text. Both Recognizers
still use the unchanged shared RecognizerFeed capture API.

Regression evidence includes three failing startup-policy tests before expiration
was implemented, and a separate failing controller test showing an old failure
could cancel a newer session. The final Debug build and corpus harness build
passed. The full macOS suite passed: 623 distinct cases, 614 passed, nine skipped,
zero failed (717 passing parameterized executions at device level). An earlier
focused run failed the existing native-picker test; that failure is retained and
not claimed fixed. Commands and all logs are in
`.verification/software-followup-report.md`.

Jeff's confirmed AirPods Sound VU answers hardware readiness for this investigation.
No physical reconnect was requested or performed. Acoustic identity, physical
outage recovery, spoken recognition/insertion and macOS 26 runtime behavior remain
unverified. The live no-callback state did not recur in the bounded runs;
the new failure path has deterministic policy/propagation coverage, not a fresh
hardware-triggered timeout demonstration. Product acceptance remains open.

### Restoration follow-up (2026-11-11)

The original three-phase switching probe reproduced the final built-in reopening
failure in three consecutive baseline runs (`1852797029`, Core Audio `nope`).
Recovery kept the stopped engine in a local `previous` reference while binding and
starting its replacement. Removing that overlapping lifetime passed three
consecutive runs of the same live probe: 21/19/21 Recognizer buffers,
47/45/48 monitoring snapshots, zero errors. The diagnostic source differs from
the committed production fix only by its explanatory comment. No settle delay,
retry loop, OS default change or Recognizer architecture change was introduced.

**Acceptance remains blocked.** The strengthened probe now checks three cycles
per capture owner. Before it could complete, explicit AirPods/System capture began
opening successfully but delivering no buffers, including during the initial idle
meter's bounded 30-second wait. A diagnostic starting on built-in delivered real
buffers and levels, then stalled at System/AirPods fallback with zero buffers.
The successful earlier three-phase runs do not prove the extended check passed.
The final Debug build and full suite passed (607 passed, nine skipped, zero failed).
Exact commands, failed and successful logs, diagnostic controls and the local
revision are recorded in `.verification/restoration-report.md`.

At that earlier checkpoint, readiness confirmation was requested and a production
first-buffer timeout was absent. The software follow-up above supersedes both
statuses. No physical connection, permission or system audio setting was changed
to force a green result; a probe deadline is not a recovery guarantee.

### Earlier integration evidence

The implementation was replayed once onto fork base `4251a88`, retaining ADR-9001's Catalog Models and feed-based Recognizers. Persistent input selection is ADR-9002. `RecognizerFeed` supplies the route to `MicrophoneInput` for either Recognizer; `SpeechRecognitionService` remains a PCM consumer, not a capture owner. The corpus harness links the shared audio sources and builds successfully.

The current full Debug suite contains **616 test cases: 607 passed, nine skipped, zero failures**, from `.verification/VerifiedTests.xcresult` and its `test-summary.json`. The device subtotal counts 710 passing parameterized executions; it is not the distinct test-case total. The nine skips comprise the four original media fixtures, two local Catalog Model fixture checks, two opt-in render checks and the opt-in insertion benchmark.

The adapted PCM-feed probe passes basic live capture (10 buffers, 33 meter snapshots, zero errors). A switching run passed with 19 buffers, 45 snapshots and zero errors. Repeated rapid AirPods → built-in → System → built-in switching is **intermittent**: a repeat failed to reopen the last device with Core Audio status `1852797029`. The probe now waits for three buffers and snapshots per phase instead of treating one retiring buffer as proof of replacement capture. This does not eliminate the hardware transition failure, and no seamless-recovery claim follows from the passing run. Exact logs and limitations are in `.verification/report.md`; physical acceptance remains open.

## Prior implementation verification

Before integration onto Catalog Models, the feature branch's Debug build and full app-hosted suite passed with the signing overrides documented in AudioInput.md. That earlier xcresult contained 489 test cases: 485 passed, four existing media-fixture skips, no failures. The matrix below records that phase, not a new physical acceptance run. Parameterized executions are counted separately by Xcode; use the summary's test-case totals consistently.

| Scenario | Observed result | Evidence boundary |
| --- | --- | --- |
| Fresh profile chooses System | Passed | Isolated UserDefaults suite and real controller; native picker renders System |
| System follows default changes | Passed with injected defaults | Real controller/route and native source explanation; OS default was not changed |
| Explicit preference survives restart | Passed for recreated settings/controller | Real UserDefaults, not a separate app-process relaunch |
| Missing device falls back without changing preference | Passed | Controller, native disconnected picker/explanation, stored UID readback |
| Restart while absent, change fallback, no inputs, reconnect with new device ID | Passed | Recreated settings/controller and injected inventory; original UID retained throughout |
| Queued old-source levels / replaced tap events | Passed | Regression tests reject stale levels, failure and stop snapshots |
| Denied/revoked/pending permission | Passed | Injected permission boundary; no real permission was revoked |
| Repeated retained-window close/reopen during dictation | Passed | Actual Settings window, six reopen cycles, capture-owner counters; no competing idle capture |
| Live inventory / UID lookup | Passed | Production sources enumerated seven actual inputs |
| Real idle meter / analyzer-buffer capture / idle resumption | Passed | Production MicrophoneInput and meter, existing authorized microphone access |
| Active capture switches between AirPods and built-in microphone | Passed after format fix | Real audio engines and tap/analyzer callbacks; not speech recognition or insertion |
| Live missing-UID fallback and return | Passed | Real device switching, but absence/return was a policy change, not physical hot-plug |

## Defects corrected

1. Recovery could open System before inventory delivery, then miss a quick reconnect because its cached route still named the preferred device. The new regression failed before the fix and passed afterward. Capture now remembers its live-resolved device.
2. A new device label could display levels queued by the old input. The regression failed before the fix. Route/tap generations now invalidate those snapshots and late callbacks, and selection immediately clears the meter. Terminal failure handling is serialized with replacement-engine startup.
3. A real AirPods (24 kHz) to built-in (48 kHz) switch originally failed with an audio-engine format mismatch. The earlier explicit hardware-format tap workaround passed a bounded probe but later caused the attended AVFAudio abort described above. It is superseded by nil-format tap negotiation; this history is not evidence of seamless Bluetooth recovery.
4. The old probe supplied Float32 PCM to AnalyzerInput, which traps on this macOS release. A standalone nonempty-buffer reproduction confirmed the framework failure; integer PCM succeeds. Production dictation obtains its format from SpeechAnalyzer and was not changed for this probe defect.

An initial full-suite run also exposed an overstrict permission-request count: application activation can legitimately recheck permission. The test now checks capture ownership exactly and permits extra permission rechecks.

## Reproduce the automated checks

Run the build, suite and production-source probe commands in [AudioInput.md](AudioInput.md), adding `--capture --switch` to the probe for active-route changes. A missing preauthorized microphone grant produces an explicit unverified result; do not bypass macOS privacy controls. Keep the failed and passing xcresults when checking regressions. The method-level Swift Testing selector without parentheses selected zero tests; suite-level selection executed the regressions correctly.

## Attended hardware checks still required

Use a separate macOS test account or isolated test bundle; do not reset the installed app's preferences or permissions. Have a removable USB microphone, built-in input and Bluetooth headset available. Record app build, devices, OS input before/after, saved UID and results. Restore the OS default after testing.

1. Launch with an untouched preference domain. Open Settings → Dictation. Confirm System selected and its effective-input name matches System Settings → Sound → Input. Speak near that input and observe the meter. **Not run as a fresh app process; automated fresh-domain coverage passed.**
2. Leave System selected. Change the OS input to a different-rate microphone. Confirm the effective name and meter move without selecting it explicitly. Speak near each device in turn to distinguish acoustic source identity. **Not run; avoided changing the operator's global audio route unattended.**
3. Select the USB input, record `preferredAudioInputUID` from the test bundle's defaults, quit and relaunch. Confirm the explicit selection and live signal return. **Controller recreation passed; full app-process relaunch with a chosen physical device remains unverified.**
4. Unplug USB. Confirm its unavailable picker item remains selected, System fallback is explained, and the meter reacts only to System. Read the saved UID again; it must be identical. Quit/relaunch while absent and repeat the checks. Reconnect USB and confirm automatic restoration without touching the picker. Read the UID once more. **Physical unplug, absent-process relaunch and reconnect not run; injected lifecycle and real policy-switch coverage passed.**
5. Repeat unplug/reconnect while Direct Dictation is held and latched. End each session and confirm recognized text arrives in the previously focused field. Close/reopen Settings and leave its Dictation section during capture. Ensure no duplicate engine and that closing Settings does not cancel dictation. **Real analyzer-buffer switching and hosted capture ownership passed; spoken recognition/insertion and physical outage remain unverified.**
6. In the isolated test account, deny then grant microphone access through System Settings; return to Settings and check recovery. Disconnect every removable input and test on hardware exposing no usable input, if available. Confirm unavailable/denied messaging rather than a fake signal. **Injected denied/revoked/pending and empty-inventory checks passed; real privacy revocation and zero-input hardware were not exercised.**
7. Exercise Bluetooth profile renegotiation and actual headset removal/return. Confirm eventual recovery or an explicit session error, never a silently frozen meter. **AirPods/built-in switching passed; physical profile-transition races remain unverified.**

## Acceptance limits

No seamless speech is promised across a hardware outage. Capture no longer passes a sampled hardware format to tap installation. An Xcode 27 / Swift 6.4 build on macOS 27 uses AVFAudio's NSError-returning tap API, with native rejection tested without process abort. macOS 26, or a build using an older SDK, retains the legacy nil-format API; blanket exception containment there is **not verified**. The attended AirPods transition itself has not been repeated after the correction. An attended hot-plug/profile test remains a release gate, not a passing result inferred from inventory injection. The first-buffer deadline starts only after synchronous engine startup returns; it does not bound synchronous recovery or monitor gaps after the first buffer. Settings requests no longer wait on that startup, but a blocked driver can still delay the background dictation ownership handoff. Device UID identity remains driver-controlled. This soak preparation targets macOS 27.2.1; macOS 26 runtime acceptance remains open.
