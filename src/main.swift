import AppKit
import SwiftUI

// **Two entry points, and they must not collide.** A url arriving from a click routes
// silently; launching the app shows the editor. Measured rather than assumed — a launch
// path that showed a window on url delivery would put a window in front of every link.
//
// Also a CLI, so the routing can be checked from a shell without clicking anything:
//   DiaRouter --explain <url>...   the verdict and the deciding rule
//   DiaRouter --route <url>        route it for real, no window

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// **Resident: launched at login to wait for links, rather than launched by one.**
    ///
    /// A cold start is the whole of the delay before a link opens, so the process stays.
    /// It changes three behaviours, and all three are needed together — resident without
    /// any one of them is a router that quits, or an app that cannot be reopened.
    let resident: Bool
    private var handledURL = false
    private var window: NSWindow?

    init(resident: Bool) {
        self.resident = resident
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledURL = true
        let rules = Store.load()
        for url in urls { Router.open(url.absoluteString, rules: rules) }
        // **A cold launch quits when it is done; a resident one never does.** Either way an
        // open editor keeps it alive, so a link clicked while looking at the rules is
        // routed instead of killing the window mid-edit.
        if !resident, window == nil { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // **A resident launch shows nothing.** It is started by launchd at login, and a
        // rules window appearing then would be the one thing nobody asked for.
        guard !resident else { return }
        // A url launch delivers `application(_:open:)` around this moment, so the decision
        // to show a window waits long enough to see one arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.handledURL, self.window == nil else { return }
            self.showEditor()
        }
    }

    /// **The way into the editor once the app is already running.** Launching it from
    /// Spotlight activates the resident process rather than starting a second one, so
    /// without this the app would appear to do nothing at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showEditor()
        }
        return true
    }

    /// Closing the editor puts the router back to waiting; it does not stop it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !resident
    }

    /// Back to an accessory when the window goes, so the Dock icon does not outlive the
    /// editor it belonged to.
    func windowWillClose(_ notification: Notification) {
        window = nil
        if resident { NSApp.setActivationPolicy(.accessory) }
    }

    private func showEditor() {
        // **Promoted only to show a window.** The process starts as an accessory so
        // routing a link never flashes a Dock icon; `LSUIElement` is deliberately *not*
        // in the Info.plist, because that is the key LaunchServices reads and it would
        // take the app out of the default-browser list.
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: RulesWindow())
        let window = NSWindow(contentViewController: hosting)
        window.title = "DiaRouter"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let resident = arguments.contains("--resident")

// `--resident` is not a command that prints and exits, so it is taken out before the flag
// below decides this is a CLI invocation.
if let flag = arguments.first, flag.hasPrefix("--"), !resident {
    let rules = Store.load()
    let urls = Array(arguments.dropFirst())
    switch flag {
    case "--explain":
        for u in urls {
            let d = decide(u, against: rules)
            let name: String
            switch d.verdict {
            case .profile(let p): name = p.rawValue
            case .native: name = "native"
            }
            print("\(name)\t\(d.reason)\t\(u)")
        }
    case "--route":
        for u in urls { print(Router.open(u, rules: rules).rawValue) }
    case "--list":
        for r in Rule.sortedBySpecificity(rules) {
            print("\(r.profile.rawValue)\t\(r.kind.rawValue)\t\(r.pattern)")
        }
    default:
        FileHandle.standardError.write(Data("usage: DiaRouter [--explain|--route|--list] <url>...\n".utf8))
        exit(2)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = Delegate(resident: resident)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
