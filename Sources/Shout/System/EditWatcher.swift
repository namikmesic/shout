import AppKit
import ApplicationServices
import ShoutKit

/// After a paste, watches the text field for up to 60 s to see how the user edits the dictated text.
/// When editing settles, aligns original vs. edited words and reports likely vocabulary corrections.
@MainActor
final class EditWatcher {
    struct Result {
        let historyID: Int64
        let original: String
        let edited: String
        let candidates: [EditLearner.Candidate]
    }

    private var timer: Timer?
    private var deadline = Date()
    private var lastValue: String?
    private var lastChange = Date()
    private var job: (handle: ContextReader.FocusHandle, inserted: String, prefix: String, suffix: String, historyID: Int64)?
    var onResult: ((Result) -> Void)?
    var knownWords: () -> Set<String> = { [] }

    func start(handle: ContextReader.FocusHandle, inserted: String, historyID: Int64) {
        stop()
        guard let value = handle.fullValue, let sel = handle.selection else { return }
        let ns = value as NSString
        let loc = min(sel.location, ns.length)
        let end = min(sel.location + sel.length, ns.length)
        job = (handle, inserted, ns.substring(to: loc), ns.substring(from: end), historyID)
        deadline = Date().addingTimeInterval(60)
        lastValue = nil
        lastChange = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard self != nil else { t.invalidate(); return }
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        job = nil
    }

    private func tick() {
        guard let job else { stop(); return }
        // Stop when focus moved to a different element or app (a background app keeps reporting its
        // last focused element, so check the frontmost app too).
        let focused = ContextReader.focusedElement(pid: job.handle.pid)
        let stillFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == job.handle.pid &&
            (focused.map { CFEqual($0, job.handle.element) } ?? false)
        let value = ContextReader.value(of: job.handle.element)
        if let value, value != lastValue { lastValue = value; lastChange = Date() }
        let settled = Date().timeIntervalSince(lastChange) > 8
        if !stillFocused || Date() > deadline || (settled && lastValue != nil) {
            finish(value: lastValue)
        }
    }

    private func finish(value: String?) {
        guard let job else { return }
        stop()
        guard let value else { return }
        // Locate the dictated segment between the untouched prefix and suffix.
        let v = value as NSString
        let prefix = job.prefix as NSString, suffix = job.suffix as NSString
        var p = 0
        while p < min(prefix.length, v.length) && prefix.character(at: p) == v.character(at: p) { p += 1 }
        var q = 0
        while q < min(suffix.length, v.length - p) &&
              suffix.character(at: suffix.length - 1 - q) == v.character(at: v.length - 1 - q) { q += 1 }
        guard p >= prefix.length - 2, v.length - q >= p else { return } // edits outside the dictated text
        // Widen to whole composed characters so an emoji's surrogate pair is never cut in half.
        var start = p, end = v.length - q
        if start > 0 && start < v.length { start = v.rangeOfComposedCharacterSequence(at: start).location }
        if end > 0 && end < v.length {
            let r = v.rangeOfComposedCharacterSequence(at: end)
            if r.location < end { end = NSMaxRange(r) }
        }
        let edited = v.substring(with: NSRange(location: start, length: end - start))
        let original = job.inserted.trimmingCharacters(in: .whitespaces)
        let editedTrim = edited.trimmingCharacters(in: .whitespaces)
        guard !editedTrim.isEmpty, editedTrim != original else { return }
        let candidates = EditLearner.candidates(original: original, edited: editedTrim, known: knownWords())
        onResult?(Result(historyID: job.historyID, original: original, edited: editedTrim, candidates: candidates))
    }
}
