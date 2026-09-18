import AppKit
import Foundation

/// **The two things the app cannot do for itself at build time**: be handed the links, and
/// be running before the first one arrives. Both are a click here and a paragraph of
/// System Settings otherwise, which is why they are asked for on first open rather than
/// left in a readme nobody reads twice.
enum Setup {
    /// **Still the old name, and deliberately.** The label and the bundle identifier are
    /// what the default-browser binding and every Automation grant are attached to; a
    /// tidier string would cost a trip through System Settings and one prompt per browser,
    /// and nobody ever sees either of them.
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

    /// **Set by Sparkle on its way out and read once on the way back in.** It is the only
    /// thing that survives between the process being replaced and the new one starting, so
    /// it is where "you were resident before the update" has to live.
    static var relaunchingForUpdate: Bool {
        get { UserDefaults.standard.bool(forKey: "relaunchingForUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "relaunchingForUpdate") }
    }

    /// Read it and clear it, so a crash on the next launch cannot leave the app resident
    /// for ever with no way to open its own window.
    static func consumeRelaunchFlag() -> Bool {
        guard relaunchingForUpdate else { return false }
        relaunchingForUpdate = false
        return true
    }

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

    /// What a failed attempt reports back: a sentence to show, and whether the way forward
    /// is System Settings rather than the same button again.
    struct Refusal {
        let message: String
        let needsSystemSettings: Bool
    }

    /// **The confirmation is the system's, not ours.** There is no way to take the default
    /// quietly, and a system prompt raised from a background app is a prompt nobody sees —
    /// hence the activate first.
    ///
    /// **The scheme asked for is `http`, and it has to be.** Asking for `https` — the one
    /// every link in the setup panel actually starts with — answers `permErr` (-54) without
    /// raising a dialog or changing anything, on any bundle, signed or ad-hoc, agent or
    /// regular app. `http` raises the dialog and carries `https` with it, which is why the
    /// second scheme below is almost always already done by the time it is checked.
    static func makeDefaultBrowser(_ done: @escaping (Refusal?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: bundle, toOpenURLsWithScheme: "http") { error in
            DispatchQueue.main.async {
                if let error { done(refusal(error)); return }
                // **https is set only if it did not follow.** It normally moves with http,
                // and asking for a scheme that is already ours buys a second identical
                // dialog for nothing.
                guard handler(for: "https") != Bundle.main.bundleIdentifier else { done(nil); return }
                NSWorkspace.shared.setDefaultApplication(at: bundle, toOpenURLsWithScheme: "https") { error in
                    DispatchQueue.main.async { done(error.map(refusal)) }
                }
            }
        }
    }

    /// `permErr` arrives wrapped in a Cocoa error whose description names a file nobody
    /// mentioned, so the diagnosis is read from the innermost error rather than the top.
    private static func refusal(_ error: Error) -> Refusal {
        var underlying = error as NSError
        while let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError { underlying = next }
        guard underlying.domain == NSOSStatusErrorDomain, underlying.code == -54 else {
            return Refusal(message: error.localizedDescription, needsSystemSettings: false)
        }
        return Refusal(
            message: "macOS would not let BrowserRouter take the default on its own. Pick BrowserRouter under \u{201C}Default web browser\u{201D} in System Settings instead.",
            needsSystemSettings: true)
    }

    /// The pane that holds "Default web browser" — the choice macOS always honours, because
    /// there it is the user making it rather than an app asking on their behalf.
    static func openDefaultBrowserSettings() {
        guard let pane = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else { return }
        NSWorkspace.shared.open(pane)
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
