import Foundation

/// Snapshot of where the user is dictating, captured through Accessibility when recording starts.
public struct DictationContext: Sendable, Equatable {
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    /// Text immediately before the cursor (nil when the field could not be read).
    public var textBefore: String?
    /// Text immediately after the cursor.
    public var textAfter: String?
    public var selectedText: String?
    public var isEditable: Bool
    public var isSecure: Bool

    public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, url: String? = nil,
                textBefore: String? = nil, textAfter: String? = nil, selectedText: String? = nil,
                isEditable: Bool = false, isSecure: Bool = false) {
        self.appName = appName; self.bundleID = bundleID; self.windowTitle = windowTitle; self.url = url
        self.textBefore = textBefore; self.textAfter = textAfter; self.selectedText = selectedText
        self.isEditable = isEditable; self.isSecure = isSecure
    }

    public var category: AppCategory { AppCategory.classify(bundleID: bundleID, url: url) }
    public var hasSelection: Bool { !(selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
