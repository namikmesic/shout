import AppKit
import Combine
import SwiftUI
import ShoutKit

/// The meeting's notes beside the call: a normal window docked to the right edge of the screen
/// (30 % of its width, full height), not floating above other apps. Closing it never stops recording.
@MainActor
final class NotepadWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = NotepadModel()
    private let scribe: ScribeController
    private let opener: NotepadOpener
    private let calendar: CalendarService
    private var cancellables: Set<AnyCancellable> = []
    private var sheetObserver: NSObjectProtocol?
    private var spaceRevert: DispatchWorkItem?

    init(scribe: ScribeController, opener: NotepadOpener, calendar: CalendarService) {
        self.scribe = scribe
        self.opener = opener
        self.calendar = calendar
        super.init()
        // The main queue, not RunLoop.main: that one waits out menu tracking and modal loops.
        Store.shared.meetingDeleted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.leave(deleted: id) }
            .store(in: &cancellables)
    }

    /// `activate: false` (opened automatically when recording starts) shows the window beside the
    /// call without taking keyboard focus away from the meeting app.
    func show(meetingID: String, activate: Bool = true) {
        model.meetingID = meetingID
        if window == nil {
            let root = NotepadRoot(model: model)
                .environmentObject(SettingsStore.shared)
                .environmentObject(Store.shared)
                .environmentObject(Permissions.shared)
                .environmentObject(AppRouter.shared)
                .environmentObject(scribe)
                .environmentObject(opener)
                .environmentObject(calendar)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = "Notepad"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 500, height: 600)
            w.delegate = self
            w.collectionBehavior = [.fullScreenAuxiliary]
            w.sharingType = hiddenFromCapture ? .none : .readOnly
            if !w.setFrameUsingName("ShoutNotepad") { dock(w) }
            w.setFrameAutosaveName("ShoutNotepad")
            // Sheets are separate windows and don't inherit the parent's sharing type. Each one protects itself before
            // it is shown (Ask through `hiddenFromScreenCapture`, confirmations through `Confirmation`); this is a
            // backstop for any other sheet, which can only be reached once attached.
            sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: w,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.protectSheets() }
                // The sheet may only be attached once the notification has been handled.
                Task { @MainActor in self?.protectSheets() }
            }
            window = w
        }
        guard let w = window else { return }
        // A display it was on may have been disconnected since.
        let onScreen = NSScreen.screens.contains {
            let overlap = $0.visibleFrame.intersection(w.frame)
            return overlap.width > 1 && overlap.height > 1
        }
        if !onScreen { dock(w) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        bringToCurrentSpace(w)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var nsWindow: NSWindow? { window }
    /// The note shown (nil once closed).
    var meetingID: String? { model.meetingID }

    /// Keeps the Notepad and its sheets out of screenshots and screen sharing.
    var hiddenFromCapture = false {
        didSet {
            window?.sharingType = hiddenFromCapture ? .none : .readOnly
            protectSheets()
        }
    }

    /// Closing the window lets go of the note, so a hidden Notepad doesn't keep reloading it.
    func windowWillClose(_ notification: Notification) {
        model.meetingID = nil
    }

    private func protectSheets() {
        guard let window else { return }
        for sheet in window.sheets + [window.attachedSheet].compactMap({ $0 }) {
            sheet.sharingType = hiddenFromCapture ? .none : .readOnly
        }
    }

    /// The note shown was deleted (Discard, or Delete here or in the main window): switch to the meeting being
    /// recorded, or close, rather than keep a note whose edits can't be saved.
    private func leave(deleted id: String) {
        guard model.meetingID == id else { return }
        if let live = scribe.activeMeetingID, live != id {
            model.meetingID = live
        } else {
            window?.close()
            model.meetingID = nil
        }
    }

    /// Joins every Space while it is ordered front, so it opens on the Space the user is on (next to a full-screen
    /// call) instead of switching back to the Space it was last on.
    private func bringToCurrentSpace(_ w: NSWindow) {
        spaceRevert?.cancel()
        w.collectionBehavior.insert(.canJoinAllSpaces)
        let revert = DispatchWorkItem { [weak w] in MainActor.assumeIsolated { _ = w?.collectionBehavior.remove(.canJoinAllSpaces) } }
        spaceRevert = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: revert)
    }

    /// Right edge of the screen the pointer is on: 30 % of its width (at least 500 pt), full height.
    private func dock(_ w: NSWindow) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let width = min(vf.width, max(500, (vf.width * 0.3).rounded()))
        w.setFrame(NSRect(x: vf.maxX - width, y: vf.minY, width: width, height: vf.height), display: false)
    }
}

/// Lets any view open a meeting in the Notepad window.
@MainActor
final class NotepadOpener: ObservableObject {
    var handler: ((String) -> Void)?
    func open(_ meetingID: String) { handler?(meetingID) }
}

@MainActor
final class NotepadModel: ObservableObject {
    @Published var meetingID: String?
}

private struct NotepadRoot: View {
    @ObservedObject var model: NotepadModel
    var body: some View {
        if let id = model.meetingID {
            MeetingDetailView(meetingID: id, inNotepad: true)
                .id(id)
                .frame(minWidth: 500, minHeight: 600)
        } else {
            // Closed: same sizing as a note, so the hidden window keeps its frame.
            Color.clear.frame(minWidth: 500, minHeight: 600)
        }
    }
}
