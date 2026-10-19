import SwiftUI
import ShoutKit

/// Prompt mode: the switch, and screenshots with their permissions. See docs/PROMPT_MODE.md.
struct PromptsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var router: AppRouter

    var body: some View {
        let s = settings.settings
        Page(title: "Prompts",
             subtitle: "Say what you want for Claude Code, Cursor or any AI assistant. Shout keeps your words, cleans them up and names what you point at precisely.") {
            Card(padding: 0, spacing: 0) {
                SettingRow(title: "Prompt mode", detail: usage(s)) {
                    SwitchControl(isOn: $settings.settings.promptModeEnabled)
                }
                RowDivider()
                SettingRow(title: "Screenshots", detail: s.promptScreenshotsAvailable
                           ? "Screenshots you take while talking go into the prompt with the words you said: ⌘⇧4, ⌃⌘⇧4 (clipboard), or tap ⌥ for the window under the mouse (or the text you selected). Tap the shortcut to talk hands-free."
                           : "Needs an AI model that handles screenshots: Qwen3 4B Instruct, Qwen3.5 4B or Qwen3.5 9B. \(s.languageModel.name) is selected.") {
                    HStack(spacing: 10) {
                        if !s.promptScreenshotsAvailable {
                            Button("Choose Model…") { router.page = .models }.controlSize(.small)
                        }
                        // Grayed out, and shown off, while the model can't do it; the choice is kept for when it can.
                        SwitchControl(isOn: Binding(get: { s.promptScreenshotsOn }, set: { settings.settings.promptScreenshots = $0 }))
                            .disabled(!s.promptScreenshotsAvailable)
                    }
                }
                if s.promptScreenshotsOn {
                    RowDivider()
                    ScreenshotVisionRow()
                    RowDivider()
                    ScreenshotPermissionRows()
                }
            }
            Text("Words in your Dictionary are spelled the same way in prompts.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        // Picks up a switch flipped in System Settings while this page is open.
        .onAppear { permissions.refresh(); permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private func usage(_ s: AppSettings) -> String {
        let keys = s.promptShortcut.isEmpty ? "the Prompt mode shortcut (set it in Settings)" : s.promptShortcut.displayString
        return "Hold \(keys) and talk. Tap it with text selected to turn that text into a prompt, or with nothing selected to talk hands-free."
    }
}
