import SwiftUI
import ShoutKit

/// Prompt mode: whether the AI editing model looks at the screenshots, to name what was shown ("the gear icon at the
/// top right"). Models that can see pictures need their image reader, a separate download.
struct ScreenshotVisionRow: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var router: AppRouter
    @State private var error: String?

    static let title = "Show screenshots to the AI model"
    static let example = "name what you showed, like “the gear icon at the top right”"

    var body: some View {
        let model = settings.settings.languageModel
        if let reader = model.imageReader {
            let installed = models.isInstalled(reader)
            SettingRow(title: Self.title, detail: detail(model: model, reader: reader, installed: installed)) {
                trailing(reader: reader, installed: installed)
            }
        } else {
            SettingRow(title: Self.title,
                       detail: "Qwen3.5 4B and 9B can look at each screenshot to \(Self.example). \(model.name) only gets what you pointed at.") {
                Button("Choose Model…") { router.page = .models }.controlSize(.small)
            }
        }
    }

    private func detail(model: ModelInfo, reader: ModelInfo, installed: Bool) -> String {
        if let error { return "The download failed: \(error)" }
        switch models.downloads[reader.id] {
        case .downloading(let p, _): return "Downloading \(model.name)'s image reader · \(Int(p * 100))%"
        case .verifying: return "Verifying the download…"
        default: break
        }
        return installed
            ? "\(model.name) looks at each screenshot to \(Self.example). Adds a second or two for each one."
            : "\(model.name) can look at each screenshot to \(Self.example). Its image reader is a \(reader.sizeDescription) download."
    }

    @ViewBuilder private func trailing(reader: ModelInfo, installed: Bool) -> some View {
        if case .downloading(let p, _) = models.downloads[reader.id] {
            HStack(spacing: 8) {
                ProgressRing(progress: p)
                Button { models.cancel(reader) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Cancel download")
            }
        } else if case .verifying = models.downloads[reader.id] {
            ProgressView().controlSize(.small)
        } else if installed {
            SwitchControl(isOn: $settings.settings.promptShowScreenshotsToModel)
        } else {
            Button {
                error = nil
                Task {
                    do {
                        try await models.download(reader)
                        settings.settings.promptShowScreenshotsToModel = true
                    } catch is CancellationError {} catch { self.error = error.localizedDescription }
                }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .controlSize(.small)
        }
    }
}
