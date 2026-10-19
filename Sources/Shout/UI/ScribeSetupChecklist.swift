import SwiftUI
import ShoutKit

/// "Set up Scribe" progress card in the sidebar until each step is done (or the user hides it).
struct ScribeSetupChecklist: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var permissions: Permissions
    @State private var hover = false
    @State private var hasNote = false
    @State private var hasSummary = false

    private struct Step: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let action: () -> Void
    }

    var body: some View {
        let all = steps
        let done = all.filter(\.done).count
        VStack(spacing: 0) {
            if !settings.settings.scribeSetupDismissed && done < all.count { card(all, done: done) }
        }
        .onAppear(perform: refresh)
        .onChange(of: store.meetingsRevision) { _, _ in refresh() }
    }

    /// The sidebar redraws for every transcript line, so the store is only read until both note steps are done.
    private func refresh() {
        guard !settings.settings.scribeSetupDismissed, !(hasNote && hasSummary) else { return }
        (hasNote, hasSummary) = store.meetingSetupProgress()
    }

    private func card(_ all: [Step], done: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Set up Scribe").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { settings.settings.scribeSetupDismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).opacity(hover ? 1 : 0).help("Hide")
            }
            ProgressView(value: Double(done), total: Double(all.count))
                .progressViewStyle(.linear).tint(.green).controlSize(.mini)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(all) { step in
                    Button(action: step.action) {
                        HStack(spacing: 7) {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12)).foregroundStyle(step.done ? Color.green : Color.secondary)
                            Text(step.title).font(.system(size: 11.5))
                                .foregroundStyle(step.done ? .secondary : .primary)
                                .strikethrough(step.done, color: .secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(step.done)
                }
            }
        }
        .padding(12)
        .background(CardSurface(radius: 10))
        .onHover { hover = $0 }
    }

    private var steps: [Step] {
        [
            Step(id: "try", title: "Try Scribe", done: hasNote) {
                router.page = .scribe
                scribe.start()
            },
            Step(id: "audio", title: "Allow system audio", done: permissions.systemAudioAllowed
                                                                   || !ScribeController.systemAudioSupported) {
                Task { await permissions.requestSystemAudio() }
            },
            Step(id: "calendar", title: "Connect calendar", done: calendar.access == .granted) {
                // The prompt only shows the first time; after a denial, System Settings is where it can change.
                if calendar.access == .notDetermined { Task { _ = await calendar.requestAccess() } } else { calendar.openSettings() }
            },
            Step(id: "summary", title: "Get your first summary", done: hasSummary) {
                router.page = .scribe
            },
        ]
    }
}
