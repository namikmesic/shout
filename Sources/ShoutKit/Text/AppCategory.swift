import Foundation

/// Fine-grained classification of where the user is dictating.
public enum AppCategory: String, Sendable {
    case personalMessaging, workMessaging, email, chatbot, developer, terminal, document, browser, other

    public var styleCategory: StyleCategory {
        switch self {
        case .personalMessaging: .personal
        case .workMessaging: .work
        case .email: .email
        default: .other
        }
    }

    public var label: String {
        switch self {
        case .personalMessaging: "personal messaging"
        case .workMessaging: "work messaging"
        case .email: "email"
        case .chatbot: "AI chat assistant prompt"
        case .developer: "code editor"
        case .terminal: "terminal"
        case .document: "document editor"
        case .browser: "web browser"
        case .other: "general app"
        }
    }

    static let bundles: [String: AppCategory] = [
        // Personal messaging
        "com.apple.MobileSMS": .personalMessaging, "net.whatsapp.WhatsApp": .personalMessaging,
        "desktop.WhatsApp": .personalMessaging, "ru.keepcoder.Telegram": .personalMessaging,
        "org.telegram.desktop": .personalMessaging, "org.whispersystems.signal-desktop": .personalMessaging,
        "com.facebook.archon": .personalMessaging, "com.facebook.archon.developerID": .personalMessaging,
        "com.hnc.Discord": .personalMessaging, "jp.naver.line.mac": .personalMessaging,
        "com.tencent.xinWeChat": .personalMessaging, "com.viber.osx": .personalMessaging,
        // Work messaging
        "com.tinyspeck.slackmacgap": .workMessaging, "com.microsoft.teams": .workMessaging,
        "com.microsoft.teams2": .workMessaging, "us.zoom.xos": .workMessaging,
        "com.google.Chat": .workMessaging, "com.mattermost.desktop": .workMessaging,
        "im.riot.app": .workMessaging, "com.webex.meetingmanager": .workMessaging,
        // Email
        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.readdle.smartemail-Mac": .email,
        "com.readdle.SparkDesktop": .email, "com.superhuman.electron": .email, "com.mimestream.Mimestream": .email,
        "it.bloop.airmail2": .email, "com.freron.MailMate": .email, "com.postbox-inc.postbox": .email,
        "org.mozilla.thunderbird": .email, "com.canarymail.mac": .email, "io.notion.mail": .email,
        // AI assistants
        "com.openai.chat": .chatbot, "com.anthropic.claudefordesktop": .chatbot, "ai.perplexity.mac": .chatbot,
        // Developer
        "com.microsoft.VSCode": .developer, "com.microsoft.VSCodeInsiders": .developer,
        "com.todesktop.230313mzl4w4u92": .developer, "com.exafunction.windsurf": .developer,
        "com.apple.dt.Xcode": .developer, "dev.zed.Zed": .developer, "com.sublimetext.4": .developer,
        "com.panic.Nova": .developer, "com.google.antigravity": .developer,
        // Terminals
        "com.apple.Terminal": .terminal, "com.googlecode.iterm2": .terminal, "dev.warp.Warp-Stable": .terminal,
        "com.mitchellh.ghostty": .terminal, "net.kovidgoyal.kitty": .terminal, "io.alacritty": .terminal,
        "com.github.wez.wezterm": .terminal,
        // Documents
        "com.apple.iWork.Pages": .document, "com.microsoft.Word": .document, "notion.id": .document,
        "md.obsidian": .document, "com.apple.Notes": .document, "com.apple.TextEdit": .document,
        "com.craft.craft": .document, "net.shinyfrog.bear": .document, "com.lukilabs.lukiapp": .document,
        "com.linear": .document,
        // Browsers
        "com.apple.Safari": .browser, "com.google.Chrome": .browser, "company.thebrowser.Browser": .browser,
        "org.mozilla.firefox": .browser, "com.brave.Browser": .browser, "com.microsoft.edgemac": .browser,
        "com.vivaldi.Vivaldi": .browser, "com.operasoftware.Opera": .browser, "app.zen-browser.zen": .browser,
        "company.thebrowser.dia": .browser,
    ]

    static let hosts: [(String, AppCategory)] = [
        ("mail.google.com", .email), ("outlook.live.com", .email), ("outlook.office.com", .email),
        ("outlook.office365.com", .email), ("mail.yahoo.com", .email), ("app.fastmail.com", .email),
        ("mail.proton.me", .email), ("superhuman.com", .email), ("app.hey.com", .email),
        ("slack.com", .workMessaging), ("teams.microsoft.com", .workMessaging), ("teams.live.com", .workMessaging),
        ("chat.google.com", .workMessaging), ("discord.com", .personalMessaging),
        ("web.whatsapp.com", .personalMessaging), ("messenger.com", .personalMessaging),
        ("web.telegram.org", .personalMessaging), ("instagram.com", .personalMessaging),
        ("chatgpt.com", .chatbot), ("chat.openai.com", .chatbot), ("claude.ai", .chatbot),
        ("gemini.google.com", .chatbot), ("perplexity.ai", .chatbot), ("chat.mistral.ai", .chatbot),
        ("docs.google.com", .document), ("notion.so", .document), ("linear.app", .document),
        ("github.com", .developer), ("gitlab.com", .developer),
    ]

    public static func classify(bundleID: String?, url: String?) -> AppCategory {
        var app = AppCategory.other
        if let bundleID {
            if let c = bundles[bundleID] { app = c } else if bundleID.hasPrefix("com.jetbrains.") { app = .developer }
        }
        // The site decides only in a browser or an app Shout doesn't know: a known app's web view shows its own
        // service (Notion Mail runs mail.notion.so, which would otherwise read as a Notion document).
        guard app == .browser || app == .other else { return app }
        if let url, let host = URL(string: url)?.host?.lowercased() {
            for (h, cat) in hosts where host == h || host.hasSuffix("." + h) { return cat }
        }
        return app
    }
}
