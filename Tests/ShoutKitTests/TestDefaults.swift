import Foundation

/// Removes a test's throwaway settings suite, its file included: macOS keeps an empty plist in
/// ~/Library/Preferences after `removePersistentDomain`, one per test run otherwise.
func removeTestDefaults(_ suite: String) {
    UserDefaults().removePersistentDomain(forName: suite)
    CFPreferencesAppSynchronize(suite as CFString)
    let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: file)
}
