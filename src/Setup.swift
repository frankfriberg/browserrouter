import AppKit
import Foundation

/// **The two things the app cannot do for itself at build time**: be handed the links, and
/// be running before the first one arrives. Both are a click here and a paragraph of
/// System Settings otherwise, which is why they are asked for on first open rather than
/// left in a readme nobody reads twice.
enum Setup {
    static let agentLabel = "com.frankfriberg.diarouter"
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    /// **Asked of LaunchServices every time rather than remembered.** The default browser
    /// can be changed behind the app's back — by another browser's own nag screen, most
    /// often — and a stored flag would then describe a world that no longer exists.
    static var isDefaultBrowser: Bool { handler(for: "https") == Bundle.main.bundleIdentifier }

    static var isLoginAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlist.path)
    }

    static var isComplete: Bool { isDefaultBrowser && isLoginAgentInstalled }

    /// Whether the first-open panel has already had its chance. Only this is remembered:
    /// declining is a decision, and re-asking at every launch would make it a nag.
    static var hasBeenOffered: Bool {
        get { UserDefaults.standard.bool(forKey: "setupOffered") }
        set { UserDefaults.standard.set(newValue, forKey: "setupOffered") }
    }

    private static func handler(for scheme: String) -> String? {
        guard let url = URL(string: "\(scheme)://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    /// **The confirmation is the system's, not ours.** There is no way to take the default
    /// quietly, and a system prompt raised from a background app is a prompt nobody sees —
    /// hence the activate first.
    static func makeDefaultBrowser(_ done: @escaping (String?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: bundle, toOpenURLsWithScheme: "https") { error in
            DispatchQueue.main.async {
                if let error { done(error.localizedDescription); return }
                // **http is set only if it did not follow.** Changing the https handler
                // normally moves http with it, and asking for a scheme that is already ours
                // buys a second identical dialog for nothing.
                guard handler(for: "http") != Bundle.main.bundleIdentifier else { done(nil); return }
                NSWorkspace.shared.setDefaultApplication(at: bundle, toOpenURLsWithScheme: "http") { error in
                    DispatchQueue.main.async { done(error?.localizedDescription) }
                }
            }
        }
    }

    /// The same agent `install-login-agent.sh` writes, written from inside the app instead:
    /// on first open the bundle already knows where it is, so there is nothing to go find.
    ///
    /// Launched through `open` rather than by running the binary directly, so the process is
    /// the app bundle as LaunchServices knows it — which is what lets it receive the url
    /// events and keeps its Automation grant.
    static func installLoginAgent() -> String? {
        let app = Bundle.main.bundleURL.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(agentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>-a</string>
            <string>\(app)</string>
            <string>--args</string>
            <string>--resident</string>
          </array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>

        """
        do {
            try FileManager.default.createDirectory(
                at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist.write(to: agentPlist, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        let domain = "gui/\(getuid())"
        // A stale definition is booted out first, so installing twice is not an error.
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
        return run("/bin/launchctl", ["bootstrap", domain, agentPlist.path])
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let errors = Pipe()
        task.standardError = errors
        task.standardOutput = Pipe()
        do { try task.run() } catch { return error.localizedDescription }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus != 0 else { return nil }
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "launchctl exited \(task.terminationStatus)" : message
    }
}
