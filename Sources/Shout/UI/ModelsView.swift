import SwiftUI
import ShoutKit

struct ModelsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var hub: EngineHub
    @State private var ollamaModels: [String] = []
    @State private var error: String?
    @State private var diskUsage = ""
    @State private var listedOllama = false

    var body: some View {
        Page(title: "Models", subtitle: "Everything runs on this Mac with Metal acceleration. Nothing you say leaves your computer.") {
            section(title: "Speech recognition", caption: "Turns your voice into text", state: hub.speechState,
                    items: ModelCatalog.speech, slot: \.speechModelID)

            section(title: "AI editing", caption: "Cleans up text, applies your tone and runs Command Mode", state: hub.languageState,
                    items: ModelCatalog.language, slot: \.languageModelID)

            if settings.settings.languageModelID == "ollama" {
                Card {
                    CardHeader(title: "Ollama", caption: "Only servers on localhost are allowed")
                    HStack(spacing: 10) {
                        TextField("Server", text: $settings.settings.ollamaURL).textFieldStyle(.roundedBorder).frame(width: 220)
                        Picker("Model", selection: $settings.settings.ollamaModel) {
                            Text("Choose…").tag("")
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                        Button("Refresh") { Task { await loadOllama() } }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text("\(diskUsage) used in Application Support").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.models]) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 4)

            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
        }
        .task(id: settings.settings.ollamaURL) {
            // A new server address lists its models once typing pauses; the first listing runs straight away.
            if listedOllama { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !Task.isCancelled else { return }
            listedOllama = true
            await loadOllama()
        }
        .onAppear { diskUsage = Self.diskUsage() }
        .onChange(of: models.installed) { _, _ in
            hub.configure(settings.settings)
            diskUsage = Self.diskUsage()
        }
    }

    private func section(title: String, caption: String, state: EngineHub.State, items: [ModelInfo],
                         slot: WritableKeyPath<AppSettings, String>) -> some View {
        Card(padding: 0, spacing: 0) {
            CardHeader(title: title, caption: caption) {
                HStack(spacing: 6) {
                    EngineStatusDot(state: state).frame(width: 13)
                    Text(statusText(state)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            ForEach(items) { m in
                Divider().padding(.leading, 62)
                ModelRow(model: m, slot: slot, availability: availability(m), onError: { error = $0 })
            }
        }
    }

    private func statusText(_ s: EngineHub.State) -> String {
        switch s {
        case .ready: "Loaded"
        case .loading: "Loading…"
        case .disabled: "Off"
        case .missingModel: "Not downloaded"
        case .failed: "Error"
        case .idle: "Not loaded"
        }
    }

    /// Read when the page opens and when a download lands or is deleted, not on every redraw (progress ticks).
    private static func diskUsage() -> String {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.models, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = urls.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func loadOllama() async {
        // listOllamaModels never contacts a server that isn't on this Mac.
        guard let url = URL(string: settings.settings.ollamaURL) else {
            ollamaModels = []
            return
        }
        let found = await OpenAICompatibleGenerator.listOllamaModels(baseURL: url)
        if !Task.isCancelled { ollamaModels = found }
    }

    private func availability(_ m: ModelInfo) -> String? {
        switch m.engine {
        case .appleSpeech:
            if #available(macOS 26.0, *) { return AppleSpeechEngine.isSupported ? nil : "Not available on this Mac" }
            return "Requires macOS 26"
        case .appleIntelligence:
            if #available(macOS 26.0, *) { return AppleIntelligenceGenerator.unavailableReason }
            return "Requires macOS 26"
        default: return nil
        }
    }
}

private struct ModelRow: View {
    let model: ModelInfo
    /// The setting this model is chosen into (speech or AI editing model).
    let slot: WritableKeyPath<AppSettings, String>
    let availability: String?
    let onError: (String?) -> Void
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: SettingsStore

    private var selected: Bool { settings.settings[keyPath: slot] == model.id }
    private func select() { settings.settings[keyPath: slot] = model.id }

    var body: some View {
        let installed = models.isInstalled(model)
        HStack(alignment: .center, spacing: 14) {
            ModelGlyph(model: model)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 13, weight: .medium))
                    if let b = model.badge, b != "Built in" { Badge(text: b, tint: b == "Recommended" ? .green : .secondary) }
                }
                Text(model.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                metaLine(installed: installed)
            }
            Spacer(minLength: 12)
            trailing(installed: installed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func metaLine(installed: Bool) -> some View {
        if let availability {
            Text(availability).font(.system(size: 11)).foregroundStyle(.orange)
        } else if case .failed(let e) = models.downloads[model.id] {
            Text(e).font(.system(size: 11)).foregroundStyle(.red)
        } else if case .downloading(let p, let speed) = models.downloads[model.id] {
            Text("Downloading · \(Int(p * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        } else if case .verifying = models.downloads[model.id] {
            Text("Verifying…").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            Text(model.isDownloadable ? (installed ? "Downloaded · \(model.sizeDescription)" : model.sizeDescription)
                 : (model.engine == .ollama ? "Uses the Ollama server on this Mac" : "Included with macOS"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func trailing(installed: Bool) -> some View {
        if case .downloading(let p, _) = models.downloads[model.id] {
            HStack(spacing: 8) {
                ProgressRing(progress: p)
                Button { models.cancel(model) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Cancel download")
            }
        } else if case .verifying = models.downloads[model.id] {
            ProgressView().controlSize(.small)
        } else if selected {
            Label("In use", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
        } else if availability != nil {
            EmptyView()
        } else if installed || !model.isDownloadable {
            HStack(spacing: 6) {
                Button("Use", action: select).controlSize(.small)
                if model.isDownloadable {
                    Menu {
                        Button("Delete Download", role: .destructive) { models.delete(model) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        } else {
            Button {
                onError(nil)
                // Downloading doesn't switch models: the row then offers "Use" (a silent switch surprised the user).
                Task {
                    do { try await models.download(model) }
                    catch is CancellationError {} catch { onError(error.localizedDescription) }
                }
            } label: { Label("Get", systemImage: "arrow.down.circle") }
            .controlSize(.small)
        }
    }
}

/// Rounded icon tile identifying the model family.
private struct ModelGlyph: View {
    let model: ModelInfo
    var body: some View {
        let (symbol, colors): (String, [Color]) = {
            switch model.engine {
            case .parakeet: return ("waveform", [Color(red: 0.2, green: 0.75, blue: 0.55), Color(red: 0.1, green: 0.55, blue: 0.45)])
            case .whisper: return ("waveform.badge.mic", [Color(red: 0.35, green: 0.55, blue: 1), Color(red: 0.25, green: 0.35, blue: 0.85)])
            case .appleSpeech, .appleIntelligence: return ("apple.logo", [Color(white: 0.45), Color(white: 0.25)])
            case .llama: return ("sparkles", [Color(red: 0.62, green: 0.45, blue: 1), Color(red: 0.42, green: 0.3, blue: 0.85)])
            case .ollama: return ("server.rack", [Color(white: 0.5), Color(white: 0.3)])
            }
        }()
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
        .frame(width: 18, height: 18)
    }
}
