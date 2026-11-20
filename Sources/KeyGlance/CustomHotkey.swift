import AppKit

/// What a user-defined universal hotkey does.
enum HotkeyAction: Codable, Hashable {
    case openApp(path: String)
    case openURL(String)
    case shell(String)
    case showOverlay

    var summary: String {
        switch self {
        case let .openApp(path): return "Opens \(FileManager.default.displayName(atPath: path))"
        case let .openURL(url): return "Opens \(url)"
        case let .shell(command): return "Runs: \(command)"
        case .showOverlay: return "Shows the KeyGlance cheat sheet (pinned)"
        }
    }

    var symbol: String {
        switch self {
        case .openApp: return "square.grid.2x2"
        case .openURL: return "link"
        case .shell: return "terminal"
        case .showOverlay: return "keyboard"
        }
    }
}

/// A system-wide hotkey the user created in KeyGlance.
struct CustomHotkey: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var combo: KeyCombo
    var action: HotkeyAction
    var enabled = true
}

enum HotkeyActionRunner {
    static func run(_ action: HotkeyAction, showOverlay: () -> Void) {
        switch action {
        case let .openApp(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case let .openURL(string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        case let .shell(command):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            try? process.run()
        case .showOverlay:
            showOverlay()
        }
    }
}
