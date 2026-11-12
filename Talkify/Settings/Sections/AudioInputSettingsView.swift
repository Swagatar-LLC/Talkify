import AVFoundation
import SwiftUI

struct AudioInputSettingsView: View {
  let audioInput: AudioInputController
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    SettingsCard(title: "Microphone") {
      SettingsRow(title: "Audio input", description: "System follows the macOS input choice.") {
        Picker("Audio input", selection: Binding(
          get: { audioInput.preferredInputUID },
          set: { audioInput.selectInput(uid: $0) }
        )) {
          Text("System").tag(String?.none)
          ForEach(audioInput.devices) { device in
            Text(device.name).tag(Optional(device.id))
          }
          if let uid = audioInput.preferredInputUID, !audioInput.isPreferredAvailable {
            Text("Unavailable input (\(uid))").tag(Optional(uid))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 240, alignment: .trailing)
        .accessibilityIdentifier("audio-input-picker")
      }

      SettingsRow(title: "Effective input", description: routeDescription) {
        Image(systemName: audioInput.isPreferredAvailable ? "mic" : "mic.badge.xmark")
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Input level")
          .font(.system(size: 13, weight: .medium))
        ProgressView(value: displayedLevel, total: 1)
          .tint(SettingsTheme.accent)
        Text(meterDescription)
          .font(.caption)
          .foregroundStyle(.white.opacity(contrast == .increased ? 0.85 : 0.65))
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 13)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Input level: \(meterDescription)")
      .accessibilityIdentifier("audio-input-meter")

      if permissionDenied {
        Button("Open Microphone Settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(SettingsButtonStyle())
        .accessibilityIdentifier("audio-input-permission-settings")
        .padding(.bottom, 12)
      }

      if let error = audioInput.discoveryError {
        Text("Could not refresh audio inputs: \(error)")
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 12)
      }
    }
  }

  private var permissionDenied: Bool {
    audioInput.isMicrophoneAccessDenied || audioInput.microphoneAuthorization == .denied
      || audioInput.microphoneAuthorization == .restricted
  }

  private var displayedLevel: Double {
    audioInput.effectiveInput != nil && audioInput.isMonitoring && !permissionDenied
      && audioInput.captureError == nil ? Double(audioInput.level) : 0
  }

  private var meterDescription: String {
    if permissionDenied { return "Microphone access is denied. Enable it in System Settings." }
    guard audioInput.effectiveInput != nil else { return "Input unavailable" }
    if let error = audioInput.captureError { return error }
    guard audioInput.isMonitoring else { return "Waiting for microphone…" }
    return displayedLevel > 0.01
      ? "Signal detected, \(Int((displayedLevel * 100).rounded())) percent" : "No signal"
  }

  private var routeDescription: String {
    guard let input = audioInput.effectiveInput else {
      return audioInput.isPreferredAvailable
        ? "No input is available. Connect a microphone or choose an input in System Settings."
        : "Saved input is disconnected. No System input is available. Your preference is kept."
    }
    if !audioInput.isPreferredAvailable {
      return "Saved input is disconnected. Using System: \(input.name). Your preference is kept and will return automatically."
    }
    return audioInput.isUsingSystem ? "Using System: \(input.name)" : "Using: \(input.name)"
  }
}
