#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p .verification
printf '%s\n' 'Compile production AUHALCapture + MicrophoneInput with injected fake native operations; execute offline harness only.'
xcrun swiftc -swift-version 6 -strict-concurrency=complete -enable-upcoming-feature MemberImportVisibility -warnings-as-errors -parse-as-library \
  Talkify/Dictation/AUHALCapture.swift Talkify/Dictation/MicrophoneInput.swift \
  Talkify/AudioInput/AudioInputRoute.swift Talkify/AudioInput/AudioInputSelection.swift \
  Talkify/AudioInput/CoreAudioInputDevices.swift Tools/AudioCaptureHarness/main.swift \
  Talkify/AudioInput/AudioInputLevelMonitor.swift \
  -o .verification/backend-offline-harness
.verification/backend-offline-harness --offline
for regression in --failure-retirement-regression --route-timeout-regression --token-cap-regression --lifetime-regression --admission-timeout-regression --admission-seriality-regression --startup-route-regression --small-callback-regression --typed-error-regression --concurrent-stop-regression; do
  .verification/backend-offline-harness "$regression"
done
