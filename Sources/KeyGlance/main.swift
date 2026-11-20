import AppKit

let arguments = CommandLine.arguments

// Debug: `KeyGlance --dump <bundle id or app name>` prints what the overlay would show.
if let i = arguments.firstIndex(of: "--dump") {
    DumpCommand.run(target: i + 1 < arguments.count ? arguments[i + 1] : nil)
    exit(0)
}

if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

if let i = arguments.firstIndex(of: "--snapshot") {
    exit(Snapshot.run(outputDirectory: i + 1 < arguments.count ? arguments[i + 1] : "."))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

enum DumpCommand {
    static func run(target: String?) {
        guard AXIsProcessTrusted() else {
            print("Accessibility access is not granted to this process (or its parent terminal).")
            exit(1)
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let target,
              let app = apps.first(where: { $0.bundleIdentifier == target })
                ?? apps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(target) == true }) else {
            print("Usage: KeyGlance --dump <bundle id | app name>\nRunning apps:")
            apps.forEach { print("  \($0.localizedName ?? "?")  (\($0.bundleIdentifier ?? "-"))") }
            exit(1)
        }
        let start = Date()
        let items = MenuReader.readShortcuts(pid: app.processIdentifier, layout: .current())
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("\(app.localizedName ?? "?"): \(items.count) shortcuts in \(ms) ms\n")
        for s in items {
            let flags = [s.enabled ? nil : "disabled", s.isUniversal ? "universal" : nil,
                         s.keyCode == nil ? "no-key" : nil].compactMap { $0 }
            let combo = s.display.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(combo) \((s.path + [s.title]).joined(separator: " › "))\(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")")
        }
    }
}
