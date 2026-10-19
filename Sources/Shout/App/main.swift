import AppKit

// `Shout --version` prints the version and quits, without opening any window. The release build runs it to check
// that the packaged app starts: its embedded frameworks load and its signature is accepted.
if CommandLine.arguments.dropFirst().first == "--version" {
    let info = Bundle.main.infoDictionary ?? [:]
    print("Shout \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
