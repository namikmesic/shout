import SwiftUI
import UniformTypeIdentifiers
import ShoutKit

// MARK: - Design tokens

enum Theme {
    static let pagePadding: CGFloat = 28
    static let maxContentWidth: CGFloat = 880
    static let cardRadius: CGFloat = 12
    static let sectionSpacing: CGFloat = 22
}

/// Page scaffold: large title, optional subtitle and trailing accessory, constrained content width.
struct Page<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: title, subtitle: subtitle)
                    accessory
                }
                content
            }
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 22)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Page where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.accessory = EmptyView(); self.content = content()
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grouped surface in the style of System Settings: white in light mode, a lifted tint in dark mode.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface())
    }
}

struct CardSurface: View {
    var radius: CGFloat = Theme.cardRadius
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(scheme == .dark ? Color.white.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.07), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 1.5, y: 0.5)
    }
}

/// Card header: title, optional caption, trailing accessory.
struct CardHeader<Accessory: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let caption { Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(title: String, caption: String? = nil) { self.title = title; self.caption = caption; self.accessory = EmptyView() }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor
    var body: some View {
        Card(padding: 14, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14)))
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            // Large standalone figures use proportional digits.
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .accentColor
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }
}

/// A physical-looking key: light face, hairline edge and a 1pt bottom lip.
struct KeyCap: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.white)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.16), lineWidth: 0.5))
    }
}

struct ComboCaps: View {
    let combo: KeyCombo
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(combo.displayString.components(separatedBy: " + ").enumerated()), id: \.offset) { KeyCap(text: $0.element) }
        }
    }
}

struct EngineStatusDot: View {
    let state: EngineHub.State
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().fill(color.opacity(0.35)).frame(width: 13, height: 13).opacity(isLoading ? 1 : 0))
    }
    private var isLoading: Bool { if case .loading = state { return true }; return false }
    private var color: Color {
        switch state {
        case .ready: .green; case .loading: .orange; case .disabled, .idle: .gray
        case .missingModel: .yellow; case .failed: .red
        }
    }
}

/// App icon for a bundle identifier, with a neutral fallback.
struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 20
    static let genericIcon: NSImage =
        NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
        ?? NSWorkspace.shared.icon(for: .application)
    var body: some View {
        if let id = bundleID, let icon = AppIcons.icon(for: id) {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // macOS's generic application icon for apps that aren't installed here.
            Image(nsImage: Self.genericIcon).resizable().interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Installed apps' icons by bundle identifier. Looking them up asks Launch Services, which is too slow to repeat
/// for every row on every redraw.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    /// The app's icon, or nil when it isn't installed.
    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}

/// Lays its children out left to right and wraps to a new line when the width runs out (pills under a title).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in line.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = lines.last, last.width + spacing + size.width <= width {
                lines[lines.count - 1] = (last.items + [i], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                lines.append(([i], size.width, size.height))
            }
        }
        return lines
    }
}

extension View {
    /// Keeps the window this view is shown in (e.g. a sheet, which doesn't inherit it from its parent) out of
    /// screenshots, recordings and screen sharing while `hidden` is true.
    func hiddenFromScreenCapture(_ hidden: Bool) -> some View {
        background(CaptureProtection(hidden: hidden))
    }
}

private struct CaptureProtection: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.protect = hidden }

    final class Probe: NSView {
        var protect = false { didSet { apply() } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        private func apply() { if protect { window?.sharingType = .none } }
    }
}

/// The window a view is shown in, for presenting AppKit sheets from SwiftUI (`Confirmation`).
@MainActor
final class HostWindow {
    weak var window: NSWindow?
}

extension View {
    /// Keeps `host.window` pointing at the window this view is in.
    func readingHostWindow(_ host: HostWindow) -> some View {
        background(HostWindowReader(host: host))
    }
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.host = host }

    final class Probe: NSView {
        var host: HostWindow? { didSet { host?.window = window } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
        /// Only watches; clicks go to the controls in front of it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A confirmation sheet built with NSAlert rather than SwiftUI's `confirmationDialog`, so that on a window kept out
/// of screen capture (the Notepad, with "Hide Notepad and Flow Bar from screen sharing") the sheet is kept out too
/// before its first frame. A SwiftUI dialog's window can only be reached once it is already on screen, and sheets
/// don't inherit their parent's sharing type.
@MainActor
enum Confirmation {
    static func present(on window: NSWindow?, title: String, message: String, confirm: String, destructive: Bool = true,
                        onConfirm: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        let hidden = window.map { $0.sharingType == .none } ?? SettingsStore.shared.settings.scribeHideFromScreenCapture
        if hidden { alert.window.sharingType = .none }
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { MainActor.assumeIsolated { onConfirm() } }
        }
    }
}

/// Copy button that confirms with a checkmark.
struct CopyButton: View {
    let text: String
    var label: String? = nil
    @State private var copied = false
    var body: some View {
        Button {
            TextInserter.copy(text)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
        } label: {
            if let label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
            }
        }
        .help("Copy")
    }
}

/// Friendly empty state built from an SF Symbol.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    /// An optional button under the message.
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            if let action {
                Button(action.title, action: action.run).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

extension Date {
    /// Read for every row of a list, so the formatter is made once.
    @MainActor private static let shortRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    @MainActor var relativeShort: String {
        Self.shortRelativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}

/// Plain multi-line text editor with a placeholder.
struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 80
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
            if text.isEmpty {
                Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// A modal form for adding or editing something: a title and short explanation, the fields, what's wrong with the
/// input (if anything), then Cancel and the confirming button. Esc cancels.
struct FormSheet<Fields: View>: View {
    let title: String
    var subtitle: String? = nil
    let confirmTitle: String
    var canConfirm = true
    var problem: String? = nil
    /// Return by default. A form with a multi-line field confirms with ⌘Return, so Return starts a new line.
    var confirmShortcut: KeyboardShortcut = .defaultAction
    var width: CGFloat = 460
    let confirm: () -> Void
    @ViewBuilder var fields: Fields
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 16) { fields }.padding(.top, 18)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(confirmShortcut)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
            .controlSize(.large)
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: width)
    }
}

/// A form field with its label above it.
struct FormField<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            control
        }
    }
}

enum SnapshotMode {
    static let active = ProcessInfo.processInfo.environment["SHOUT_SNAPSHOT_DIR"] != nil
}

/// Scrollable page container. In snapshot mode it lays content out in a plain stack, because
/// SwiftUI scroll views cannot be captured offscreen.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if SnapshotMode.active {
            VStack(alignment: .leading, spacing: 0) { content }.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}
