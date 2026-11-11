import SwiftUI

/// Download, and the three stages after it.
///
/// Before anything starts, the sheet says plainly what the one fetch is: how much, from
/// which host and repositories, under which licence, and that nothing spoken is sent.
/// Once started it shows the store's progress, so closing the sheet changes nothing and
/// reopening it from the row picks up where the install is.
struct RecognizerDownloadSheet: View {
  let store: RecognizerStore
  let model: CatalogModel
  let onClose: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(progress == nil ? "Download \(model.displayName)?" : model.displayName)
          .font(.system(size: 17, weight: .semibold, design: .rounded))
        Text(model.formattedSize + " · " + model.licence.spdx)
          .font(.caption)
          .foregroundStyle(secondary)
      }

      if let progress {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(InstallProgress.Stage.allCases, id: \.self) { stage in
            RecognizerStageRow(stage: stage, progress: progress)
          }
        }
        if case .failed(let stage, let reason) = progress.outcome {
          Text(failureText(stage: stage, reason: reason))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        disclosure
      }

      HStack(spacing: 8) {
        Spacer()
        buttons
      }
    }
    .padding(24)
    .frame(width: 500)
    .background(SettingsTheme.background)
    .preferredColorScheme(.dark)
    .tint(SettingsTheme.accent)
  }

  private var progress: InstallProgress? { store.installs[model.id] }

  private var secondary: Color {
    .white.opacity(contrast == .increased ? 0.72 : 0.5)
  }

  private var disclosure: some View {
    VStack(alignment: .leading, spacing: 12) {
      fact("Size", model.formattedSize)
      fact("From", hosts)
      fact("Licence", model.licence.attribution ?? model.licence.spdx)

      Text(
        "This is the only time Talkify connects for this model. Nothing you say is sent: "
          + "dictation stays on this Mac."
      )
      .font(.system(size: 12, weight: .medium))
      .fixedSize(horizontal: false, vertical: true)

      Text(
        "After the download, Talkify checks every file against the fingerprint in its "
          + "built-in catalog, then prepares the model for the Neural Engine. Preparing "
          + "takes about three minutes, once, here rather than on your first dictation."
      )
      .font(.caption)
      .foregroundStyle(secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var hosts: String {
    model.sources.map { "\($0.host)/\($0.repository)" }.joined(separator: "\n")
  }

  private func fact(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(secondary)
        .frame(width: 60, alignment: .leading)
      Text(value)
        .font(.system(size: 12))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var buttons: some View {
    switch progress?.outcome {
    case nil where progress == nil:
      Button("Cancel", action: onClose)
        .buttonStyle(SettingsButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button("Download \(model.formattedSize)") { store.install(model) }
        .buttonStyle(SettingsButtonStyle())
        .keyboardShortcut(.defaultAction)
    case nil:
      if progress?.stage == .download {
        Button("Cancel Download") { store.cancelInstall(model) }
          .buttonStyle(SettingsButtonStyle())
      }
      Button("Hide", action: onClose)
        .buttonStyle(SettingsButtonStyle())
        .keyboardShortcut(.cancelAction)
    case .ready:
      Button("Close") {
        store.dismissInstall(model)
        onClose()
      }
      .buttonStyle(SettingsButtonStyle())
      .keyboardShortcut(.cancelAction)
      Button("Use \(model.displayName)") {
        store.use(model)
        store.dismissInstall(model)
        onClose()
      }
      .buttonStyle(SettingsButtonStyle())
      .keyboardShortcut(.defaultAction)
    case .failed:
      Button("Close", action: onClose)
        .buttonStyle(SettingsButtonStyle())
        .keyboardShortcut(.cancelAction)
      if store.canDownload(model) {
        Button("Try Again") { store.install(model) }
          .buttonStyle(SettingsButtonStyle())
      }
    }
  }

  private func failureText(stage: InstallProgress.Stage, reason: String) -> String {
    switch stage {
    case .download:
      "The download stopped and nothing was kept. \(reason) Apple Speech stays in use."
    case .verify:
      "The files did not verify. \(reason) Apple Speech stays in use."
    case .prepare:
      "The model downloaded but could not be prepared. \(reason) Apple Speech stays in use."
    }
  }
}

/// One stage: done, running, waiting, or where the install stopped.
private struct RecognizerStageRow: View {
  let stage: InstallProgress.Stage
  let progress: InstallProgress

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      icon
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 6) {
        Text(stage.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white.opacity(state == .waiting ? 0.45 : 1))
        if let detail {
          Text(detail)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        if stage == .download, state == .running {
          ProgressView(value: progress.downloadedFraction)
            .progressViewStyle(.linear)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private enum StageState { case done, running, waiting, failed }

  private var state: StageState {
    if case .failed(let failedStage, _) = progress.outcome {
      if failedStage == stage { return .failed }
      return failedStage.rawValue > stage.rawValue ? .done : .waiting
    }
    if progress.outcome == .ready || progress.stage.rawValue > stage.rawValue { return .done }
    return progress.stage == stage ? .running : .waiting
  }

  @ViewBuilder
  private var icon: some View {
    switch state {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(SettingsTheme.accent)
    case .running:
      ProgressView().controlSize(.small)
    case .waiting:
      Image(systemName: "circle").foregroundStyle(.white.opacity(0.3))
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
    }
  }

  private var detail: String? {
    switch (stage, state) {
    case (.download, .running):
      return "\(Self.size(progress.receivedBytes)) of \(Self.size(progress.totalBytes))"
    case (.download, .done):
      return Self.size(progress.totalBytes)
    case (.verify, .running), (.verify, .waiting):
      return "Every file is checked against the catalog's fingerprint."
    case (.verify, .done):
      return "Every file matches."
    case (.prepare, .running):
      return "About three minutes, once. Started \(progress.stageStartedAt.formatted(date: .omitted, time: .shortened))."
    case (.prepare, .waiting):
      return "About three minutes, once. Dictation never waits for this."
    case (.prepare, .done):
      return "Ready. Choose Use to dictate with it."
    default:
      return nil
    }
  }

  private static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
