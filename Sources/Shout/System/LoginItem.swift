import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Only the installed copy (in /Applications or ~/Applications) registers itself, so development
    /// builds never add stray login items.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    static func set(_ enabled: Bool) {
        guard isInstalledCopy else { return }
        do {
            // `.requiresApproval` is registered already and waits on the user in Login Items; registering
            // it again on every launch can't change that.
            let status = SMAppService.mainApp.status
            if enabled { if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() } }
            else { if status == .enabled || status == .requiresApproval { try SMAppService.mainApp.unregister() } }
        } catch {
            NSLog("Shout: login item update failed: \(error)")
        }
    }
}
