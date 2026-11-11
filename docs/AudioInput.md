# Audio input routing (Swagatar fork)

`AudioInputController` is the main-actor observable model for the input Settings section. `AppDelegate` owns one instance and injects it into Direct Dictation. Pass that **same instance** into Settings; do not create a second controller or capture engine in a view.

## Settings interface

- `devices`: live, name-sorted `[AudioInputDevice]`. `id` is Core Audio's persistent UID; `deviceID` is a transient runtime handle and must never be persisted.
- `preferredInputUID`: nil means **System**, otherwise the user's saved UID. `selectInput(uid:)` persists immediately through `AppSettings.preferredAudioInputUID` (UserDefaults key `preferredAudioInputUID`). The UI should call this method rather than maintain its own selection state. Direct AppSettings edits are also observed.
- `effectiveInput`: resolved available device, or nil when no usable default exists. A saved but missing device falls back to the current OS default without changing the saved UID. Reconnection resolves its UID to its new runtime handle automatically.
- `isPreferredAvailable`: false when an explicit saved UID is absent. `isUsingSystem`: true for System and for unavailable-device fallback. A disconnected preference is not in `devices`; retain a separate unavailable picker option tagged with the saved UID. Only the UID is persisted, not its old display name.
- `level`: normalized first-channel RMS, 0–1 over a 50 dB window. `isMonitoring` distinguishes an active capture at zero level (silence) from inactive capture. `captureError` and `discoveryError` are optional user-facing diagnostics. `microphoneAuthorization` reads macOS permission state without requesting permission.
- `await startMonitoring()`: call from the input section's `.task`. Requests microphone permission via the existing permission service and starts a level-only capture while idle. `stopMonitoring()`: call on disappearance/window closure. If a permission dialog resolves after the view closes, capture does not start.
- `refresh()`: refresh devices/default and clear transient discovery errors; useful when the app becomes active again. It does not request permission. Reinvoke `startMonitoring()` after the user changes permission in System Settings.
- `stop()`: application shutdown only, not view disappearance. Removes hardware listeners, stops the idle meter, and invalidates the capture route. Listener tokens also unregister on deallocation.

During Direct Dictation, the idle meter releases its engine synchronously **before** dictation opens the device. Settings then consumes the existing dictation tap's levels. Closing Settings never stops dictation; ending dictation resumes idle metering only if the section is still open. Audio is never saved by monitoring. Capture events carry complete sequenced snapshots so main-actor scheduling cannot resurrect stale meter state.

## Routing and platform constraints

Settings → Dictation hosts the selector, effective-input explanation and live input-level meter. The unavailable saved UID remains a separate selected menu option; it is never replaced by System. Only the UID is persisted, so a device absent since launch is identified by UID rather than a remembered display name. Insertion and History retain a scoped next-session notice during dictation; microphone changes are live.

The retained Settings window explicitly tracks visibility and a presentation generation, so closing and immediately reopening it restarts monitoring even if SwiftUI coalesces the visibility changes. Closing synchronously cancels pending permission and stops only idle monitoring. Returning from System Settings rechecks permission before restarting monitoring. Revoked permission releases idle capture and prevents route changes from restarting it.

`AudioInputSettingsTests` hosts the actual SwiftUI views and window, reads their native accessibility nodes, and selects a device through the native menu using key events. Its inventory, permission reply and capture owner are injected; it never records real audio or prompts for permission. Coverage includes fallback and reconnection rendering, zero/signal/error/unavailable meter states, denied/revoked permission, retained-window close/reopen and synchronous dictation handoff. PNG attachments in the test result show the rendered states.

Core Audio device-list/default-input listeners keep selection current while idle. Capture sets `kAudioOutputUnitProperty_CurrentDevice` on its own input audio unit, never the system-wide default. System is a policy, not a persisted device: the default is reread on hardware events and before every engine open/rebuild. This also closes the race where an engine-configuration notification precedes the Settings model's unplug notification.

Engine startup, recovery, and shutdown run on one serial queue. An effective-route change rebuilds the engine and its converter. Bluetooth profile changes may still fail a session if hardware supplies no usable format; failure ends that capture with an error rather than silently listening to a dead engine. The preference remains saved and the next capture resolves it again. Seamless speech across a hardware outage is not promised.

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

The probe checks live inventory, UID resolution and System fallback without changing OS settings. `--capture` additionally exercises idle meter → analyzer buffers → idle meter for three seconds, discarding all audio. It runs capture only when microphone permission is already authorized, otherwise prints `UNVERIFIED` and never requests a prompt. The probe is not a substitute for app-level permission, physical unplug/reconnect, or Bluetooth testing.

Hardware verification remains the downstream integration task: exercise System while changing the OS default, explicit input across relaunch, unplug and relaunch while absent, reconnect with automatic restoration, and Settings open/close during dictation. Confirm selector, effective source and meter agree. Do not infer these results from the pure model tests.
