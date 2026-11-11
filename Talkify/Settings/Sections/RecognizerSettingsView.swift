import SwiftUI

/// The Recognizer section: Apple Speech, and each Catalog Model this Mac can run, with
/// what it costs to download and what it measured against Apple.
///
/// Everything listed comes from the catalog compiled into the app, so opening this pane
/// connects to nothing. Download is the one action that does, and its sheet says so.
struct RecognizerSettingsView: View {
  let store: RecognizerStore

  @State private var sheetModel: CatalogModel?
  @State private var deleteCandidate: CatalogModel?
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let notice = store.notice {
        RecognizerNoticeBanner(
          notice: notice,
          canRedownload: canRedownload(notice),
          onRedownload: { model(notice.modelID).map(store.redownload) },
          onDelete: { deleteCandidate = model(notice.modelID) },
          onDismiss: store.dismissNotice
        )
      }

      SettingsCard(title: "Choose one") {
        RecognizerRow(
          title: "Apple Speech",
          tags: [],
          details: ["Built in · on-device · the default, and the fallback"]
        ) {
          if store.selectedModelID == nil {
            InUseLabel()
          } else {
            Button("Use") { store.use(nil) }
              .buttonStyle(SettingsButtonStyle())
          }
        }

        ForEach(store.listedModels) { model in
          RecognizerRow(title: model.displayName, tags: tags(for: model), details: model.rowDetails) {
            controls(for: model)
          }
        }
      }

      if let note = store.olderSystemNote {
        footnote(note)
      }
      if let failure = store.deleteFailure {
        footnote(failure)
      }

      footnote(
        "The list is built into Talkify, so opening this pane connects to nothing. "
          + "Talkify connects only when you choose Download, and only to fetch that model. "
          + "Whatever you dictate stays on this Mac with every recognizer."
      )
    }
    .onAppear(perform: store.refresh)
    .sheet(item: $sheetModel) { model in
      RecognizerDownloadSheet(store: store, model: model) { sheetModel = nil }
    }
    .confirmationDialog(
      deleteCandidate.map { "Delete \($0.displayName)?" } ?? "",
      isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
      presenting: deleteCandidate
    ) { model in
      Button("Delete", role: .destructive) { store.delete(model) }
    } message: { model in
      Text(
        "Frees \(model.formattedSize). Dictation uses Apple Speech until you choose "
          + "another recognizer. Downloading it again also prepares it again."
      )
    }
  }

  @ViewBuilder
  private func controls(for model: CatalogModel) -> some View {
    HStack(spacing: 8) {
      if let progress = store.installs[model.id], progress.outcome == nil {
        Text(progress.shortStatus)
          .font(.system(size: 12, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.62))
        Button("Show") { sheetModel = model }
          .buttonStyle(SettingsButtonStyle())
      } else if case .failed = store.installs[model.id]?.outcome, !store.isInstalled(model) {
        Button("Try Again") { sheetModel = model; store.install(model) }
          .buttonStyle(SettingsButtonStyle())
      } else if store.isInstalled(model) {
        if store.selectedModelID == model.id {
          InUseLabel()
        } else if store.canUse(model) {
          Button("Use") { store.use(model) }
            .buttonStyle(SettingsButtonStyle())
        }
        Button("Delete") { deleteCandidate = model }
          .buttonStyle(SettingsButtonStyle())
      } else if store.canDownload(model) {
        Button("Download…") { sheetModel = model }
          .buttonStyle(SettingsButtonStyle())
      }
    }
  }

  private func tags(for model: CatalogModel) -> [RecognizerTag] {
    var tags: [RecognizerTag] = []
    if let measured = model.measured {
      tags.append(RecognizerTag(evidence: measured.evidence))
    }
    switch model.status {
    case .proposed: tags.append(RecognizerTag(text: "Proposed", tone: .neutral))
    case .revoked: tags.append(RecognizerTag(text: "Withdrawn", tone: .warning))
    case .available: break
    }
    if model.status != .revoked, model.revoked != nil {
      tags.append(RecognizerTag(text: "Withdrawn", tone: .warning))
    }
    return tags
  }

  private func model(_ id: String) -> CatalogModel? {
    store.catalog.models.first { $0.id == id }
  }

  private func canRedownload(_ notice: RecognizerNotice) -> Bool {
    guard notice.fallback.offersRedownload, let model = model(notice.modelID) else { return false }
    return model.status == .available && model.revoked == nil
  }

  private func footnote(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
  }
}

/// A recognizer row in the Settings row's shape, with tags beside the title and as many
/// detail lines as the entry has numbers for.
private struct RecognizerRow<Control: View>: View {
  let title: String
  let tags: [RecognizerTag]
  let details: [String]
  @ViewBuilder let control: Control

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(title)
            .font(.system(size: 13, weight: .medium))
          ForEach(tags, id: \.text) { tag in
            tag
          }
        }
        ForEach(details, id: \.self) { line in
          Text(line)
            .font(.caption)
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.48))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      control
    }
    .padding(.vertical, 13)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(contrast == .increased ? 0.16 : 0.07))
        .frame(height: 1)
    }
  }
}

/// A small capsule label: the evidence behind a model's numbers, or its catalog status.
struct RecognizerTag: View {
  enum Tone { case neutral, caution, warning }

  let text: String
  let tone: Tone

  init(text: String, tone: Tone) {
    self.text = text
    self.tone = tone
  }

  init(evidence: CatalogModel.Measured.Evidence) {
    switch evidence {
    case .synthetic: self.init(text: "Synthetic speech", tone: .caution)
    case .realVoice: self.init(text: "Real voice", tone: .neutral)
    }
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(color.opacity(0.14), in: Capsule())
      .accessibilityLabel(accessibilityText)
  }

  private var color: Color {
    switch tone {
    case .neutral: .white.opacity(0.7)
    case .caution: SettingsTheme.accent
    case .warning: .orange
    }
  }

  private var accessibilityText: String {
    text == "Synthetic speech" ? "Measured on synthetic speech" : text
  }
}

private struct InUseLabel: View {
  var body: some View {
    Label("In Use", systemImage: "checkmark.circle.fill")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(SettingsTheme.accent)
      .labelStyle(.titleAndIcon)
  }
}

/// The last session's fallback: what was refused, that Apple Speech was used, and the
/// actions that can cure it.
private struct RecognizerNoticeBanner: View {
  let notice: RecognizerNotice
  let canRedownload: Bool
  let onRedownload: () -> Void
  let onDelete: () -> Void
  let onDismiss: () -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(notice.message)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(contrast == .increased ? 0.95 : 0.82))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        Spacer()
        if canRedownload {
          Button("Download Again", action: onRedownload)
            .buttonStyle(SettingsButtonStyle())
        }
        if offersDelete {
          Button("Delete", action: onDelete)
            .buttonStyle(SettingsButtonStyle())
        }
        Button("Dismiss", action: onDismiss)
          .buttonStyle(SettingsButtonStyle())
      }
    }
    .padding(16)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.orange.opacity(contrast == .increased ? 0.5 : 0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }

  private var offersDelete: Bool {
    switch notice.fallback {
    case .filesMissing, .hashMismatch, .revoked, .loadFailed: true
    case .unsupportedLanguage: false
    }
  }
}

extension CatalogModel {
  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
  }

  /// The lines under a model's name: what it costs, what it measured against Apple on the
  /// same corpus, and where it comes from.
  var rowDetails: [String] {
    var lines = [[formattedSize, licence.spdx, languageList].joined(separator: " · ")]
    if let measured {
      var scores = "Terms \(measured.termHits.hits)/\(measured.termHits.of) against Apple's "
        + "\(measured.appleBaseline.termHits.hits)/\(measured.appleBaseline.termHits.of)"
      scores += " · controls \(measured.controlsUnchanged.hits)/\(measured.controlsUnchanged.of)"
      if let wer = measured.wer, let appleWER = measured.appleBaseline.wer {
        scores += " · word errors \(Self.percent(wer)) against \(Self.percent(appleWER))"
      }
      lines.append(scores)
      var costs: [String] = []
      if let p90 = measured.latencyMillisecondsP90 {
        costs.append("Finishes in \(Self.seconds(p90)) s after you release (p90)")
      }
      if let warm = measured.peakRSSMiBWarm {
        let bytes = Int64(warm) * 1_048_576
        costs.append("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)) of memory while loaded")
      }
      if !costs.isEmpty { lines.append(costs.joined(separator: " · ")) }
      lines.append(evidenceSentence(measured.evidence))
    }
    if let revoked {
      lines.append("Withdrawn \(revoked.date): \(revoked.reason)")
    } else if status == .proposed {
      lines.append("Proposed: under review, not yet offered for download.")
    }
    lines.append(publisherLine)
    return lines
  }

  private var languageList: String {
    let names = languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
    return names.count > 3 ? "\(names.count) languages" : names.joined(separator: ", ")
  }

  private var publisherLine: String {
    let weights = publisher.weights.components(separatedBy: " (").first ?? publisher.weights
    guard let conversion = publisher.conversion else { return "From \(weights)" }
    let converter = conversion.components(separatedBy: " (").first ?? conversion
    return "From \(weights), converted by \(converter)"
  }

  private func evidenceSentence(_ evidence: Measured.Evidence) -> String {
    switch evidence {
    case .synthetic:
      "Measured on synthetic speech; real-voice numbers replace these after testing."
    case .realVoice:
      "Measured on real voices."
    }
  }

  private static func percent(_ fraction: Double) -> String {
    (fraction * 100).formatted(.number.precision(.fractionLength(1))) + "%"
  }

  private static func seconds(_ milliseconds: Int) -> String {
    (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(2)))
  }
}

extension InstallProgress {
  /// The row's one-line readout while an install runs.
  var shortStatus: String {
    switch stage {
    case .download: "Downloading \(Int((downloadedFraction * 100).rounded(.down)))%"
    case .verify: "Verifying"
    case .prepare: "Preparing"
    }
  }
}
