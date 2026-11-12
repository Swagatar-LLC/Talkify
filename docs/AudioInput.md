# Audio input routing (Swagatar fork)

Routing is recorded in [ADR-9002](adr/9002-persistent-audio-input-selection.md). `AudioInputController` is the main-actor observable model for the input Settings section. `AppDelegate` owns one instance and injects it into Direct Dictation. Pass that **same instance** into Settings; do not create a second controller or capture engine in a view.

## Settings interface

- `devices`: live, name-sorted `[AudioInputDevice]`. `id` is Core Audio's persistent UID; `deviceID` is a transient runtime handle and must never be persisted.
- `preferredInputUID`: nil means **System**, otherwise the user's saved UID. `selectInput(uid:)` persists immediately through `AppSettings.preferredAudioInputUID` (UserDefaults key `preferredAudioInputUID`). The UI should call this method rather than maintain its own selection state. Direct AppSettings edits are also observed.
- `effectiveInput`: resolved available device, or nil when no usable default exists. A saved but missing device falls back to the current OS default without changing the saved UID. Reconnection resolves its UID to its new runtime handle automatically.
- `isPreferredAvailable`: false when an explicit saved UID is absent. `isUsingSystem`: true for System and for unavailable-device fallback. A disconnected preference is not in `devices`; retain a separate unavailable picker option tagged with the saved UID. Only the UID is persisted, not its old display name.
- `level`: normalized first-channel RMS, 0–1 over a 50 dB window. `isMonitoring` distinguishes an active capture at zero level (silence) from inactive capture. `captureError` and `discoveryError` are optional user-facing diagnostics. `microphoneAuthorization` reads macOS permission state without requesting permission.
- `await startMonitoring()`: call from the input section's `.task`. Requests microphone permission via the existing permission service and starts a level-only capture while idle. `stopMonitoring()`: call on disappearance/window closure. If a permission dialog resolves after the view closes, capture does not start.
- `refresh()`: refresh devices/default and clear transient discovery errors; useful when the app becomes active again. It does not request permission. Reinvoke `startMonitoring()` after the user changes permission in System Settings.
- `stop()`: application shutdown only, not view disappearance. Removes hardware listeners, stops the idle meter, and invalidates the capture route. Listener tokens also unregister on deallocation.

`RecognizerFeed` owns `MicrophoneInput` for both Apple Speech and Catalog Models. Its feed closure delivers converted PCM to the chosen Recognizer; routing does not live in `SpeechRecognitionService` and is not tied to `AnalyzerInput`.

During Direct Dictation, the idle meter releases its engine synchronously **before** dictation opens the device. Settings then consumes the existing dictation tap's levels. Closing Settings never stops dictation; ending dictation resumes idle metering only if the section is still open. Audio is never saved by monitoring. Capture events carry complete sequenced snapshots so main-actor scheduling cannot resurrect stale meter state.

## Routing and platform constraints

Settings → Dictation hosts the selector, effective-input explanation and live input-level meter. The unavailable saved UID remains a separate selected menu option; it is never replaced by System. Only the UID is persisted, so a device absent since launch is identified by UID rather than a remembered display name. Insertion and History retain a scoped next-session notice during dictation; microphone changes are live.

The retained Settings window explicitly tracks visibility and a presentation generation, so closing and immediately reopening it restarts monitoring even if SwiftUI coalesces the visibility changes. Closing synchronously cancels pending permission and stops only idle monitoring. Returning from System Settings rechecks permission before restarting monitoring. Revoked permission releases idle capture and prevents route changes from restarting it.

`AudioInputSettingsTests` hosts the actual SwiftUI views and window, reads their native accessibility nodes, and selects a device through the native menu using key events. Its inventory, permission reply and capture owner are injected; it never records real audio or prompts for permission. Coverage includes fallback and reconnection rendering, zero/signal/error/unavailable meter states, denied/revoked permission, retained-window close/reopen and synchronous dictation handoff. PNG attachments in the test result show the rendered states.

Core Audio device-list/default-input listeners keep selection current while idle. Capture sets `kAudioOutputUnitProperty_CurrentDevice` on its own input audio unit, never the system-wide default. System is a policy, not a persisted device: the default is reread on hardware events and before every engine open/rebuild. This also closes the race where an engine-configuration notification precedes the Settings model's unplug notification.

Engine startup, recovery, and shutdown run on one serial queue. An effective-route change rebuilds the engine and its converter. Each tap has a generation-checked first-buffer deadline: if no nonempty audio buffer arrives within ten seconds after `engine.start()` returns, capture publishes “The microphone started but supplied no audio. Check the microphone or choose another input.” Settings retains that error, and Direct Dictation cancels through the shared RecognizerFeed failure path without insertion. Silent buffers satisfy startup; empty callbacks do not. Stop, failure and replacement invalidate the old deadline, including capture without an AudioInputRoute. Dictation also rejects failure callbacks queued by a retired session. This is failure reporting, not a retry, a bound on synchronous Core Audio startup, or a fix for a driver stall. Bluetooth profile changes may still fail a session if hardware supplies no usable format. The preference remains saved and the next capture resolves it again. Seamless speech across a hardware outage is not promised.

Device UIDs depend on the driver: changing a device's identity in Audio MIDI Setup or replacing hardware may produce a different UID. Virtual input devices are included when Core Audio reports an alive input stream. Enumeration requires no microphone or Speech permission. Metering needs microphone permission only; recognition still uses its existing microphone and Speech permission guards. macOS 26 remains the deployment target; no new dependency was added.

## Repeatable verification

Build and test with the commands in CONTRIBUTING.md. On a host without upstream's signing identity, append `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=` for a local ad-hoc build; do not change committed signing settings.

The tests cover persistence, System default changes, missing/returning preferred devices with changed runtime IDs, early engine-recovery resolution, shutdown invalidation, permission denial/pending permission cancellation, shared levels, and synchronous idle-meter ownership handoff. No automated test requests permission or records live audio.

Compile a probe against the production audio sources:

```sh
mkdir -p .verification
xcrun swiftc -swift-version 6 -parse-as-library \
  scripts/AudioInputProbe.swift \
  Talkify/AudioInput/AudioInputSelection.swift \
  Talkify/AudioInput/AudioInputRoute.swift \
  Talkify/AudioInput/CoreAudioInputDevices.swift \
  Talkify/AudioInput/AudioInputLevelMonitor.swift \
  Talkify/Dictation/MicrophoneInput.swift Talkify/App/AppLog.swift \
  -o .verification/audio-input-probe
.verification/audio-input-probe --capture
```

The probe checks live inventory, UID resolution and System fallback without changing OS settings. `--capture` additionally exercises idle meter → Recognizer buffers → idle meter, discarding all audio. Every phase retains a one-second checkpoint and continues the same process for up to 30 seconds after its synchronous operation returns. Counts are restricted to new samples timestamped at or before the absolute return-plus-one/30-second cutoffs, not whatever has arrived when the observer resumes; startup-relative negative timestamps remain eligible. It also logs every phase's recorded sample offsets for reclassification. It reports synchronous duration, first buffer/real level relative to that return (negative means during startup), and distinguishes timely capture, late recovery, persistent stall at the observation bound, and reported capture failure. Startup snapshots are not counted as real tap levels. Failed capture checks unwind ownership before exiting; a later passing process never erases a failed checkpoint. `--self-test` checks classification and level counting without opening hardware. Capture runs only when microphone permission is already authorized; otherwise the probe prints `UNVERIFIED` without prompting. This is not a substitute for app-level permission, physical unplug/reconnect, or Bluetooth testing.

Hardware checks and their current results are recorded in [AudioInputVerification.md](AudioInputVerification.md). Injected inventory changes are not physical unplug/reconnect evidence.

The probe also accepts `--capture --switch`. It checks three cycles of explicit built-in input → System through a deliberately missing UID → preferred built-in input. The second and third explicit selections are intentional same-device checks. Each phase requires at least three Recognizer buffers and meter snapshots; idle-meter resumption is checked after dictation. This never changes the OS default or simulates a physical disconnection; the missing-UID and return stages are policy changes. Each phase has a bounded 30-second wait. The probe uses integer PCM for AnalyzerInput compatibility on macOS 27.

Replacement startup must not retain the stopped engine in a local reference. Its HAL resources can outlive `stop()` and prevent binding the replacement to built-in input after Bluetooth capture. The recovery queue replaces the owning reference before starting the new engine; no settle delay or retry loop is used. See AudioInputVerification.md for the current passing evidence and remaining no-buffer hardware blocker.

Capture snapshots carry a route/tap generation as well as a sequence. Changing the effective device immediately clears the displayed level; events queued by an older source and late callbacks from replaced taps cannot relight it. Engine failures are validated on the same serial queue that replaces engines. Capture's live hardware resolution updates its remembered route so a quick reconnect still triggers recovery even when the UI never observed the outage. Taps use nil format rather than imposing a hardware snapshot that may become stale. On macOS 27 with Xcode 27 / Swift 6.4, the NSError-returning tap API propagates native rejection through startup failure handling. Older SDKs and macOS 26 retain the legacy nil-format API; blanket exception containment there remains unverified.

Settings start, stop and route-refresh requests enqueue hardware work without waiting on Core Audio on the main thread. Only Direct Dictation's ownership lease waits synchronously for idle capture to release, on the recognizer executor. A blocked driver can still delay that background handoff; this is not a synchronous-startup timeout. Identical pending monitoring requests are coalesced, and closing or changing the request invalidates an in-flight startup before a replacement can open.

For stable-input diagnostics, `AudioInputProbe --capture --uid '<exact available UID>'` refuses an absent UID rather than silently opening System. This is probe safety only; the app preserves ADR-9002's missing-preference → System behavior, which can choose AirPods. The opt-in `python3 scripts/verify-audio-input-tap.py --capture --uid BuiltInMicrophoneDevice --label built-in-check` compiles a diagnostic copy of current production sources, logs requested/read-back device IDs and actual buffer format, and runs the bounded handoff probe. `--stale-snapshot` deliberately corrupts only the pre-tap snapshot to reproduce stale-format handling; it is fault injection, not hardware acceptance. Pause other capture owners first, restore them afterward, and preserve failed logs. No audio is saved and no OS route is changed.
