import SwiftUI
import ShoutKit

/// Prompt mode's screenshot permissions, asked here (Settings, the Prompts page) instead of in the middle of a
/// dictation: Screen Recording for ⌥ captures, and reading the folder macOS saves screenshots to.
struct ScreenshotPermissionRows: View {
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        PermissionRow(title: "Screen Recording", detail: "For ⌥ screenshots of the window under the mouse",
                      granted: permissions.screenRecording) { permissions.requestScreenRecording() }
            .settingRowPadding()
        if permissions.screenRecordingRequested && !permissions.screenRecording {
            RestartForScreenRecording().settingRowPadding()
        }
        RowDivider()
        PermissionRow(title: "Screenshots folder", detail: ScreenshotPermissionRows.folderDetail(permissions.screenshotFolder),
                      granted: permissions.canReadScreenshotFolder) { Task { await permissions.requestScreenshotFolder() } }
            .settingRowPadding()
    }

    static func folderDetail(_ access: Permissions.FolderAccess) -> String {
        let name = ScreenshotWatcher.screenshotFolder().lastPathComponent
        switch access {
        case .notNeeded: return "Screenshots you save (⌘⇧4) are read from \(name)"
        case .granted: return "Screenshots you save (⌘⇧4) are read from \(name)"
        case .notAsked: return "To include screenshots you save (⌘⇧4) to \(name)"
        case .denied: return "Not allowed: turn on \(name) for Shout in Files & Folders"
        }
    }
}

/// A new Screen Recording grant applies to Shout once it restarts.
struct RestartForScreenRecording: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(.secondary)
            Text("Turned on Shout in Screen Recording? It applies after a restart.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Restart Shout") { Permissions.relaunch() }.controlSize(.small)
        }
    }
}
