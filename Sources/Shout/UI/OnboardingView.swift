import SwiftUI
import ShoutKit

struct OnboardingView: View {
    let controller: DictationController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var hub: EngineHub
    @EnvironmentObject var router: AppRouter
    @State private var step = 0
    @State private var forward = true
    @State private var tryText = ""
    @State private var globeConflict = Permissions.globeKeyConflicts
    @State private var downloadError: String?

    private let stepCount = 5

    init(controller: DictationController, startStep: Int = 0) {
        self.controller = controller
        _step = State(initialValue: startStep)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear], center: .top, startRadius: 10, endRadius: 520)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                StepDots(count: stepCount, current: step).padding(.top, 34)
                ZStack {
                    stepView
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .onAppear { permissions.refresh(); permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
        // The 🌐 key's action is changed in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            globeConflict = Permissions.globeKeyConflicts
        }
    }

    @ViewBuilder private var stepView: some View {
        switch step {
        case 0: welcome
        case 1: permissionsStep
        case 2: modelsStep
        case 3: shortcutStep
        default: tryStep
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { go(-1) }.controlSize(.large).keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step < stepCount - 1 {
                Button(step == 0 ? "Get Started" : "Continue") { go(1) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !permissions.allGranted)
            } else {
                Button("Start Using Shout") {
                    settings.settings.hasCompletedOnboarding = true
                    router.showOnboarding = false
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { step = max(0, min(stepCount - 1, step + delta)) }
    }

    // MARK: Steps

    private var welcome: some View {
        StepLayout(title: "Welcome to Shout",
                   message: "Voice dictation for every app on your Mac, powered entirely by on-device models.") {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "waveform", tint: .blue, title: "Dictate anywhere",
                           detail: "Hold fn in any app, speak naturally and let go. Your words appear at the cursor.")
                FeatureRow(symbol: "sparkles", tint: .purple, title: "Clean, polished text",
                           detail: "Filler words, false starts and punctuation are fixed, in a tone that suits the app.")
                FeatureRow(symbol: "lock.shield.fill", tint: .green, title: "Private by design",
                           detail: "Speech recognition and AI editing run on this Mac. Nothing is sent anywhere.")
            }
            .padding(.top, 6)
        }
    }

    private var permissionsStep: some View {
        StepLayout(title: "Allow access",
                   message: "Shout needs two permissions to hear you while you hold the shortcut and to type into other apps.") {
            HeroTile(symbol: "hand.raised.fill", colors: [.orange, .red])
        } content: {
            Card(padding: 0, spacing: 0) {
                PermissionLine(symbol: "mic.fill", tint: .red, title: "Microphone", detail: "Only while you hold the shortcut",
                               granted: permissions.microphone == .authorized) { Task { _ = await permissions.requestMicrophone() } }
                Divider().padding(.leading, 58)
                PermissionLine(symbol: "accessibility", tint: .blue, title: "Accessibility", detail: "For the global shortcut, context and pasting",
                               granted: permissions.accessibility) { permissions.requestAccessibility() }
            }
            if !permissions.accessibility {
                Text("In System Settings › Privacy & Security › Accessibility, turn on Shout. If it's on but not detected, remove it with − and add it again.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 8)
            }
            // Optional, but asked here so macOS never asks in the middle of a dictation.
            VStack(alignment: .leading, spacing: 6) {
                Text("Optional: screenshots in Prompt mode").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Card(padding: 0, spacing: 0) {
                    PermissionLine(symbol: "camera.viewfinder", tint: .purple, title: "Screen Recording",
                                   detail: "For ⌥ screenshots of the window under the mouse",
                                   granted: permissions.screenRecording) { permissions.requestScreenRecording() }
                    if permissions.screenRecordingRequested && !permissions.screenRecording {
                        RestartForScreenRecording().padding(.horizontal, 14).padding(.bottom, 10)
                    }
                    Divider().padding(.leading, 58)
                    PermissionLine(symbol: "folder", tint: .teal, title: "Screenshots folder",
                                   detail: ScreenshotPermissionRows.folderDetail(permissions.screenshotFolder),
                                   granted: permissions.canReadScreenshotFolder) { Task { await permissions.requestScreenshotFolder() } }
                }
            }
            .padding(.top, 4)
        }
    }

    private var modelsStep: some View {
        StepLayout(title: "Download the models",
                   message: "One model turns speech into text, the other polishes it. They download once and work offline.") {
            HeroTile(symbol: "cpu", colors: [Color(red: 0.55, green: 0.4, blue: 1), Color(red: 0.3, green: 0.3, blue: 0.9)])
        } content: {
            Card(padding: 0, spacing: 0) {
                let items = [settings.settings.speechModel, settings.settings.languageModel]
                ForEach(Array(items.enumerated()), id: \.offset) { i, m in
                    if i > 0 { Divider().padding(.leading, 58) }
                    ModelDownloadLine(model: m, role: m.kind == .speech ? "Speech recognition" : "AI editing") { download(m) }
                }
            }
            HStack {
                Button("Download Both") {
                    for m in [settings.settings.speechModel, settings.settings.languageModel] where !models.isInstalled(m) { download(m) }
                }
                .disabled(models.isInstalled(settings.settings.speechModel) && models.isInstalled(settings.settings.languageModel))
                Spacer()
                Button("Other models…") { router.showOnboarding = false; router.page = .models }.buttonStyle(.link)
            }
            .font(.system(size: 12.5))
            if let downloadError { Text(downloadError).font(.system(size: 11.5)).foregroundStyle(.red) }
        }
    }

    private func download(_ m: ModelInfo) {
        downloadError = nil
        Task {
            do { try await models.download(m); hub.configure(settings.settings) }
            catch is CancellationError {} catch { downloadError = error.localizedDescription }
        }
    }

    private var shortcutStep: some View {
        StepLayout(title: "Hold to talk",
                   message: "Hold the key below anywhere on your Mac, speak, and let go. Double-tap it to keep listening hands-free.") {
            BigKey(label: settings.settings.pushToTalk.displayString)
        } content: {
            Card(spacing: 10) {
                ShortcutRow(title: "Push to talk", subtitle: "Hold to dictate", slot: .pushToTalk,
                            combo: $settings.settings.pushToTalk, controller: controller)
                Divider()
                ShortcutRow(title: "Command Mode", subtitle: "Hold with text selected to edit it by voice", slot: .command,
                            combo: $settings.settings.command, controller: controller)
            }
            if globeConflict && settings.settings.pushToTalk.keys.contains(KeyCombo.Key.fn) {
                Card { GlobeKeyWarning { globeConflict = Permissions.globeKeyConflicts } }
            }
        }
    }

    private var tryStep: some View {
        StepLayout(title: "Give it a try",
                   message: "Click in the box, hold \(settings.settings.pushToTalk.displayString) and say something like “um, let's meet at two, actually three”.") {
            HeroTile(symbol: "mic.fill", colors: [Color(red: 0.25, green: 0.6, blue: 1), Color(red: 0.2, green: 0.4, blue: 0.95)])
        } content: {
            PlaceholderEditor(text: $tryText, placeholder: "Your words will appear here…", minHeight: 130)
            HStack(spacing: 16) {
                statusLabel(hub.speechState, symbol: "waveform")
                statusLabel(hub.languageState, symbol: "sparkles")
            }
        }
    }

    private func statusLabel(_ s: EngineHub.State, symbol: String) -> some View {
        HStack(spacing: 6) {
            EngineStatusDot(state: s).frame(width: 13)
            Text(s.label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Building blocks

private struct StepLayout<Hero: View, Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(spacing: 16) {
                hero
                VStack(spacing: 8) {
                    Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.4)
                    Text(message).font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 460)
            }
            VStack(spacing: 12) { content }
                .frame(maxWidth: 480)
                .padding(.top, 26)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.primary.opacity(i < current ? 0.35 : 0.14))
                    .frame(width: i == current ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current)
    }
}

private struct HeroTile: View {
    let symbol: String
    let colors: [Color]
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: colors.last!.opacity(0.35), radius: 14, y: 6)
    }
}

/// A large keyboard key, used to show the dictation shortcut.
private struct BigKey: View {
    let label: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "globe").font(.system(size: 13, weight: .regular)).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Text(label).font(.system(size: 20, weight: .medium, design: .rounded)) }
        }
        .padding(10)
        .frame(width: label.count > 3 ? 150 : 84, height: 76)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.white)
                .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.18), radius: 0, y: 3)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionLine: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow", action: request).controlSize(.regular)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: granted)
    }
}

private struct ModelDownloadLine: View {
    let model: ModelInfo
    let role: String
    let download: () -> Void
    @EnvironmentObject var models: ModelManager
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.kind == .speech ? "waveform" : "sparkles")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(model.kind == .speech ? Color.teal.gradient : Color.purple.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name).font(.system(size: 13, weight: .medium))
                Text(role + (model.sizeDescription.isEmpty ? "" : " · \(model.sizeDescription)"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if models.isInstalled(model) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
            } else if case .downloading(let p, _) = models.downloads[model.id] {
                Text("\(Int(p * 100))%").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                ProgressRing(progress: p)
            } else if case .verifying = models.downloads[model.id] {
                ProgressView().controlSize(.small)
            } else {
                Button("Download", action: download)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
