# Persistent audio input verification

Verified locally on 2026-11-11: MacBook Pro (Mac16,5), arm64, macOS 27.2.1 (26B131), Xcode 27.2. This is a local-fork verification record, not release acceptance. Nothing was installed, pushed or merged. OS input/output settings and the installed app's preferences were not changed. Probe audio was discarded.

## Integration onto Catalog Models main

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

Jeff must confirm the headset is ready to supply microphone audio, and, if needed,
reconnect it during an attended check before rerunning the production probe three
times. No physical connection, permission or system audio setting was changed to
force a green result. A production first-buffer timeout is still absent; the
probe's deadline is a test deadline, not an implemented recovery guarantee.

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
3. A real AirPods (24 kHz) to built-in (48 kHz) switch failed with an audio-engine format mismatch. Routed taps now use hardware input format rather than the output format cached from System. The production-source probe subsequently passed selection, fallback and return with real buffers. Bluetooth teardown/recovery exceeded one second; the probe waits up to 30 seconds.
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

No seamless speech is promised across a hardware outage. Explicit tap installation still has a hardware-format read/install window: a physical format change there may raise an Objective-C framework exception, which Swift cannot catch. An attended hot-plug/profile test is a release gate, not a passing result inferred from inventory injection. The current implementation does not impose a production recovery timeout, so Bluetooth transitions can take several seconds. Device UID identity remains driver-controlled. macOS 26 deployment compatibility compiled, but this run only exercised macOS 27.2.1.
