import AppKit
import SwiftUI

// **Two entry points, and they must not collide.** A url arriving from a click routes
// silently; launching the app shows the editor. Measured rather than assumed — a launch
// path that showed a window on url delivery would put a window in front of every link.
//
// Also a CLI, so the routing can be checked from a shell without clicking anything:
//   BrowserRouter --explain <url>...   the verdict and the deciding rule
//   BrowserRouter --route <url>        route it for real, no window

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// **Resident: launched at login to wait for links, rather than launched by one.**
    ///
    /// A cold start is the whole of the delay before a link opens, so the process stays.
    /// It changes three behaviours, and all three are needed together — resident without
    /// any one of them is a router that quits, or an app that cannot be reopened.
    let resident: Bool
    private var handledURL = false
    private var window: NSWindow?
    /// **Made once the app is running, not in `init`.** Starting the updater schedules a
    /// network check, and a `--explain` run that never reaches `NSApplication` has no
    /// business making one.
    private var updater: Updater?

    init(resident: Bool) {
        self.resident = resident
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledURL = true
        let settings = Store.load()
        for url in urls {
            Router.open(url.absoluteString, settings)
        }
        // **A cold launch quits when it is done; a resident one never does.** Either way an
        // open editor keeps it alive, so a link clicked while looking at the rules is
        // routed instead of killing the window mid-edit.
        if !resident, window == nil { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // **Installed only if the grant is already there**, never asked for here: the
        // prompt belongs to the toggle in the editor, where somebody is looking at the
        // app, and not to a launch that happened at login or to open a link.
        if Store.load().tabSwitcher { Hotkey.install(true) }
        Hotkey.retryWhenDiaAppears()
        updater = Updater(promote: { [weak self] in self?.promoteForUpdate() },
                          demote: { [weak self] in self?.demoteAfterUpdate() })
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

    /// **The app becomes an ordinary app for the length of an update session.** Sparkle's
    /// window is a real window and an accessory app cannot put one in front of anyone; the
    /// menu comes with it, because the update alert is a window like the editor's and ⌘Q
    /// has to keep working while it is up.
    private func promoteForUpdate() {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// **Only if there is nothing else on screen.** The update can be asked for from the
    /// rules window's own menu, and demoting while that window is open would take its Dock
    /// icon away underneath it.
    private func demoteAfterUpdate() {
        guard window == nil else { return }
        if resident { NSApp.setActivationPolicy(.accessory) }
    }

    /// Back to an accessory when the window goes, so the Dock icon does not outlive the
    /// editor it belonged to.
    func windowWillClose(_ notification: Notification) {
        window = nil
        if resident { NSApp.setActivationPolicy(.accessory) }
    }

    /// **An app with no menu bar has no ⌘Q**, and this one had neither. `LSUIElement`
    /// means macOS builds nothing for us, and the window is made by hand rather than by a
    /// SwiftUI `App`, so the menu is made by hand too: Quit, because otherwise the only way
    /// out of the editor is the close button, and Edit, because a rules window is mostly
    /// text fields and ⌘V is not optional in one of those.
    private func installMenu() {
        guard NSApp.mainMenu == nil else { return }
        let app = NSMenu()
        // Sparkle's own action, on the updater rather than the responder chain, since an
        // accessory app's chain does not reach it.
        let check = NSMenuItem(title: "Check for Updates…",
                               action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updater
        app.addItem(check)
        app.addItem(.separator())
        app.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit BrowserRouter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        for submenu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func showEditor() {
        // **Promoted only to show a window.** `LSUIElement` keeps the process out of the
        // Dock the rest of the time, including while it routes a link; this is the one
        // moment it is allowed a Dock icon, and `windowWillClose` takes it away again.
        NSApp.setActivationPolicy(.regular)
        installMenu()
        let hosting = NSHostingController(rootView: RulesWindow())
        let window = NSWindow(contentViewController: hosting)
        window.title = "BrowserRouter"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
// **A relaunch after an update is a resident launch.** Sparkle restarts the bundle with no
// arguments, and without this the app it restarts is a different app from the one it
// replaced: a rules window instead of a silent router. Read once and cleared.
let resident = arguments.contains("--resident")
    || (!arguments.contains { $0.hasPrefix("--") } && Setup.consumeRelaunchFlag())

// `--resident` is not a command that prints and exits, so it is taken out before the flag
// below decides this is a CLI invocation.
if let flag = arguments.first, flag.hasPrefix("--"), !resident {
    let settings = Store.load()
    let urls = Array(arguments.dropFirst())
    switch flag {
    case "--explain":
        for u in urls {
            let d = decide(u, against: settings.rules, fallback: settings.fallback)
            let name = d.target.token
            // The deep link is the part worth seeing: it is the thing that either resolves
            // in the app or does not.
            if let deep = d.rule?.deepLink(for: u) {
                print("\(name)\t\(d.reason)\t\(deep.absoluteString)")
            } else {
                print("\(name)\t\(d.reason)\t\(u)")
            }
        }
    case "--route":
        for u in urls {
            print(Router.open(u, settings, secondChance: false).rawValue)
        }
    case "--save":
        // **Reads the file and writes it straight back**, which is how a file still in an
        // older format gets migrated without opening the window. Everything the reader
        // understands is preserved; everything it does not was already being ignored.
        print(Store.save(settings) ? "wrote \(Store.file.path)" : "could not write \(Store.file.path)")
    case "--switcher":
        // **What the app can see about itself**, because everything that can go wrong
        // with a tap is invisible: the grant, the install, and the setting are three
        // separate yes-or-nos and only all three together are a working ⌘T.
        print("setting\t\(settings.tabSwitcher ? "on" : "off")")
        print("accessibility\t\(Hotkey.isTrusted ? "granted" : "not granted")")
        print("tap\t\(Hotkey.install(true) ? "installs" : "refused")")
    case "--list":
        print("default\t\(settings.fallback.token)")
        // In list order, because that is the order they are consulted in and the numbers
        // are what a `--explain` line points back at.
        for (i, r) in settings.rules.enumerated() {
            print("\(i + 1)\t\(r.target.token)\t\(r.kind.rawValue)\t\(r.pattern)")
        }
    default:
        FileHandle.standardError.write(Data("usage: BrowserRouter [--explain|--route|--list|--save|--switcher] <url>...\n".utf8))
        exit(2)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = Delegate(resident: resident)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
