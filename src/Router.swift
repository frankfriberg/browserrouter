import AppKit

/// Places a url in a browser, and in a profile inside it where the browser has any.
///
/// **There is no single mechanism, so there is no single router.** What every browser can
/// do is open a url; naming a profile is where they diverge, and they diverge completely —
/// see ``Browser/Mechanism``. Each case below is that browser family's own way, and each
/// was measured rather than guessed, against the dictionary or the flag the browser
/// actually ships.
enum Router {
    enum Outcome: String {
        case handedOff = "handoff", focused, created, launched
        case noWindow = "nowindow", noProfile = "noprofile", failed
    }

    /// Route a url, falling back to opening it plainly whenever anything goes wrong.
    ///
    /// **It never refuses.** A link in the wrong profile is a nuisance; a link that does
    /// not open is a broken machine. That mattered less when the router sat in front of a
    /// real default browser; now that it *is* the default browser, a refusal here is a
    /// click that does nothing at all, with nowhere for the user to look.
    @discardableResult
    static func open(_ url: String, _ settings: Settings) -> Outcome {
        // **A rule pointing at an app is allowed to fail, and failing drops it.** The app
        // may have been deleted since the rule was written, or may refuse the link; either
        // way the link must carry on down the list exactly as if that line were not there,
        // rather than being swallowed by an app that cannot open it.
        var rules = settings.rules
        for _ in 0...settings.rules.count {
            let decision = decide(url, against: rules, fallback: settings.fallback)
            let target = decision.target

            if case .app = target {
                if hand(url, to: target) { return .handedOff }
                guard let failed = decision.rule,
                      let index = rules.firstIndex(where: { $0.id == failed.id })
                else { break }
                rules.remove(at: index)
                continue
            }

            let outcome = route(url, to: target)
            switch outcome {
            case .focused, .created, .launched, .handedOff:
                return outcome
            default:
                // Everything specific has failed: the profile is gone, the script was
                // refused, the browser would not talk. The link still has to open, so it
                // opens the only way left — plainly, in that browser, or in the fallback
                // one if it is not there at all.
                let browser = target.browser ?? settings.fallback.browser ?? .safari
                _ = launch(browser, url: url)
                    || launch(settings.fallback.browser ?? .safari, url: url)
                    || Browser.allCases.contains { $0.installedAt != nil && launch($0, url: url) }
                return outcome
            }
        }
        // Every app rule in the way refused and nothing else matched. The fallback browser
        // is the last thing standing.
        return route(url, to: settings.fallback)
    }

    /// Hand the url to an app rather than a browser. False means it did not go, and the
    /// caller should carry on down the list.
    ///
    /// **A built-in is opened at its bundle; anything else is opened at its scheme.**
    /// Naming the bundle is what stops `linear://` going to whatever registered last, and
    /// it is only possible for the apps whose identifiers are written down. For a name
    /// someone typed, LaunchServices' own answer is the only answer there is — and it is
    /// the right one, since the user picked the scheme precisely because an app claims it.
    private static func hand(_ url: String, to target: Target) -> Bool {
        guard let deep = target.deepLink(for: url) else { return false }
        if let built = target.handoff {
            guard let application = built.installedAt else { return false }
            return openWaiting([deep], at: application)
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: deep) != nil else { return false }
        return NSWorkspace.shared.open(deep)
    }

    private static func route(_ url: String, to target: Target) -> Outcome {
        if case .app = target { return hand(url, to: target) ? .handedOff : .failed }
        guard let browser = target.browser, let app = browser.installedAt else { return .failed }
        switch browser.mechanism {
        case .dia:
            return dia(url, profile: target.profile)
        case .arc:
            return arc(url, profile: target.profile)
        case .chromium(let support):
            return chromium(url, browser, app: app, support: support, profile: target.profile)
        case .gecko(_, let executable):
            return gecko(url, app: app, executable: executable, profile: target.profile)
        case .none:
            // Safari, and anything else with no way to be told. Focusing a tab that is
            // already showing the url is the whole of what can be done here, and it is
            // worth doing: it is the difference between one tab and eleven.
            if focusExistingTab(url, in: browser) { return .focused }
            return launch(browser, url: url) ? .launched : .failed
        }
    }

    /// Whether the browser has a window to put a tab in. Dia and Arc both refuse to make
    /// one, so this is the wait after asking the app to open.
    private static func hasWindow(_ browser: Browser) -> Bool {
        execute("tell application \"\(browser.scriptingName)\" to return (count of windows) as text") != "0"
    }

    // MARK: - Dia

    /// Dia, where a profile is a scriptable object inside a window: a tab can be made
    /// directly in one and found again afterwards. Every quirk in the script below was
    /// measured against Dia's own dictionary.
    private static func dia(_ url: String, profile: String?) -> Outcome {
        let wanted = profile ?? ""
        var outcome = run(diaScript(url: url, wanted: wanted))

        // A routed url with nowhere to go: ask for a window, then try once more.
        // `windows` is read-only in the dictionary, so a window cannot be made directly.
        if outcome == .noWindow {
            _ = launch(.dia, url: nil)
            for _ in 0..<30 where !hasWindow(.dia) { usleep(100_000) }
            outcome = run(diaScript(url: url, wanted: wanted))
        }
        return outcome
    }

    private static func diaScript(url: String, wanted: String) -> String {
        """
        set theURL to \(literal(url))
        set wanted to \(literal(wanted))
        set target to my strip(theURL)

        tell application "Dia"
            activate
            if (count of windows) is 0 then return "nowindow"
            -- Indexed, not `repeat with p in profiles of w`: that form builds a reference
            -- into a reference and Dia answers -1700 for every window.
            repeat with wi from 1 to (count of windows)
                set ps to profiles of window wi
                repeat with pi from 1 to (count of ps)
                    set p to item pi of ps
                    if wanted is "" or (name of p as text) is wanted then
                        -- The explicit `get` is load-bearing. Without it Dia answers with
                        -- tab references rather than strings: `count` works and every
                        -- comparison fails with -1700, so a dedupe looks healthy and does
                        -- nothing.
                        -- **The tab references are captured before anything is focused.**
                        -- `focus p` changes what `tabs of p` resolves to, so a tab looked
                        -- up after it is the wrong one: the profile comes forward and the
                        -- tab does not. Focusing the tab alone brings its profile with it.
                        set tl to tabs of p
                        set us to (get URL of every tab of p)
                        repeat with i from 1 to (count of us)
                            if my strip(item i of us) is target then
                                set t to item i of tl
                                focus t
                                return "focused"
                            end if
                        end repeat
                    end if
                end repeat
            end repeat
            if wanted is "" then
                -- No profile was asked for and no tab already had it, so the browser's own
                -- handling is the right answer rather than a made tab in an arbitrary one.
                return "nomatch"
            end if
            try
                set p to (first profile of front window whose name is wanted)
                set t to make new tab at end of tabs of p with properties {URL:theURL}
                try
                    focus p
                    focus t
                end try
                return "created"
            on error
                -- A renamed profile lands here, which is the failure this is likeliest to
                -- meet: the name is the lookup key and it can be edited.
                return "noprofile"
            end try
        end tell

        \(stripHandler)
        """
    }

    // MARK: - Arc

    /// Arc, which is Dia's idea with none of Dia's spelling. **Four things had to be found
    /// by trying them**, because the dictionary describes none of them:
    ///
    /// - a space is named `title`; `name` fails to coerce and takes the script with it;
    /// - `first space ... whose title is` cannot filter, so the space is found by index
    ///   out of `get title of every space`;
    /// - `make new tab at end of tabs of <space>` returns a tab and creates nothing — it
    ///   reports success, and no tab exists anywhere afterwards;
    /// - a tab answers `select`, not `focus`, and selecting one in a background space
    ///   brings that space forward with it.
    ///
    /// What works for creating is to focus the space and then make the tab *on the window*,
    /// which lands it in whichever space is focused.
    private static func arc(_ url: String, profile: String?) -> Outcome {
        let wanted = profile ?? ""
        var outcome = run(arcScript(url: url, wanted: wanted))
        if outcome == .noWindow {
            _ = launch(.arc, url: nil)
            for _ in 0..<30 where !hasWindow(.arc) { usleep(100_000) }
            outcome = run(arcScript(url: url, wanted: wanted))
        }
        return outcome
    }

    private static func arcScript(url: String, wanted: String) -> String {
        """
        set theURL to \(literal(url))
        set wanted to \(literal(wanted))
        set target to my strip(theURL)

        tell application "Arc"
            activate
            if (count of windows) is 0 then return "nowindow"
            repeat with wi from 1 to (count of windows)
                -- `get title of every space`, because a title read off one space at a time
                -- answers -1700. An unnamed space has no title at all, so each comparison
                -- is guarded rather than the list filtered.
                set ts to (get title of every space of window wi)
                repeat with si from 1 to (count of ts)
                    set match to false
                    try
                        if wanted is "" or (item si of ts as text) is wanted then set match to true
                    end try
                    if match then
                        set us to (get URL of every tab of space si of window wi)
                        repeat with i from 1 to (count of us)
                            if my strip(item i of us as text) is target then
                                -- `select`, not `focus`: focus is the space's verb, select
                                -- is the tab's, and selecting brings the space along.
                                select tab i of space si of window wi
                                return "focused"
                            end if
                        end repeat
                    end if
                end repeat
            end repeat
            if wanted is "" then return "nomatch"
            repeat with wi from 1 to (count of windows)
                set ts to (get title of every space of window wi)
                repeat with si from 1 to (count of ts)
                    set match to false
                    try
                        if (item si of ts as text) is wanted then set match to true
                    end try
                    if match then
                        focus space si of window wi
                        -- The focus is not instant, and a tab made before it arrives lands
                        -- in the space that was showing a moment ago.
                        delay 0.5
                        tell front window to make new tab with properties {URL:theURL}
                        return "created"
                    end if
                end repeat
            end repeat
            return "noprofile"
        end tell

        \(stripHandler)
        """
    }

    // MARK: - Chromium

    /// Chrome, Brave, Edge and Vivaldi, which share a command line and a dictionary.
    ///
    /// **The profile is named on the command line, and nowhere else.** The dictionary has
    /// never heard of profiles — there is no way to make a tab in one, and no way to ask
    /// which profile a window belongs to. So the tab is placed by relaunching the app with
    /// `--profile-directory`, which is the same mechanism Chromium's own profile picker
    /// uses.
    private static func chromium(_ url: String, _ browser: Browser, app: URL,
                                 support: String, profile: String?) -> Outcome {
        // **The dedupe cannot be scoped to the profile, so it is not scoped at all.** A
        // window carries no profile that AppleScript can read. Focusing a tab that already
        // shows this exact url is still the right answer nearly always — it is the tab the
        // click was asking for — and the alternative is a second copy of it every time.
        if focusExistingTab(url, in: browser) { return .focused }

        guard let profile else { return launch(browser, url: url) ? .launched : .failed }
        guard let directory = ChromiumProfiles.directory(support, named: profile) else {
            // The profile in the rule no longer exists. Falling back to whichever profile
            // is in front would put a work link in the personal one silently, which is the
            // exact thing the rule was written to prevent, so it is reported instead.
            return .noProfile
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-n` is what makes the flags be read at all: without it `open` hands the url to
        // the running instance and drops everything after `--args`.
        task.arguments = ["-n", "-a", app.path, "--args",
                          "--profile-directory=\(directory)", url]
        do { try task.run() } catch { return .failed }
        task.waitUntilExit()
        return task.terminationStatus == 0 ? .created : .failed
    }

    // MARK: - Firefox

    /// Firefox and Zen. **`-P` is better than it reads**: measured against both, it opens
    /// the named profile alongside a different one that is already running, and when that
    /// profile *is* the running one the url arrives as a tab in it rather than a second
    /// window. Two profiles of each ran side by side throughout.
    ///
    /// The one thing neither can do is be looked inside: both ship the boilerplate Cocoa
    /// scripting suite, with no tab class in it, so a url already open is opened again.
    ///
    /// **Run against the binary, not through `open`.** `-P` is a flag for the browser and
    /// `open -a` has nowhere to put it that Firefox reads.
    private static func gecko(_ url: String, app: URL, executable: String,
                              profile: String?) -> Outcome {
        guard let profile else {
            let browser = executable == "zen" ? Browser.zen : .firefox
            return launch(browser, url: url) ? .launched : .failed
        }
        let task = Process()
        task.executableURL = app.appendingPathComponent("Contents/MacOS/\(executable)")
        task.arguments = ["-P", profile, "-new-tab", url]
        do { try task.run() } catch { return .failed }
        return .created
    }

    // MARK: - Shared

    /// Find a tab already showing this url anywhere in the browser and bring it forward.
    ///
    /// Written twice below rather than once, because Safari and Chromium name the current
    /// tab differently and there is no spelling that satisfies both.
    private static func focusExistingTab(_ url: String, in browser: Browser) -> Bool {
        guard browser.canFocusExistingTab, browser.installedAt != nil else { return false }
        // Asking a browser that is not running to list its windows launches it, which is
        // the opposite of cheap and would make the dedupe the slow path.
        guard NSWorkspace.shared.runningApplications.contains(where: {
            browser.bundleIDs.contains($0.bundleIdentifier ?? "")
        }) else { return false }

        let name = browser.scriptingName
        let select: String
        if case .none = browser.mechanism {
            // Safari's tabs are objects you assign; Chromium's are an index you set.
            select = "set current tab of window wi to item i of ts"
        } else {
            select = "set active tab index of window wi to i"
        }
        let source = """
        set target to my strip(\(literal(url)))
        tell application "\(name)"
            if (count of windows) is 0 then return "nomatch"
            repeat with wi from 1 to (count of windows)
                set ts to tabs of window wi
                -- A tab that has never loaded answers `missing value` for its URL, which
                -- is not a string and cannot be compared; the whole loop would fail on it.
                try
                    set us to (get URL of every tab of window wi)
                on error
                    set us to {}
                end try
                repeat with i from 1 to (count of us)
                    try
                        if my strip(item i of us as text) is target then
                            \(select)
                            set index of window wi to 1
                            activate
                            return "focused"
                        end if
                    end try
                end repeat
            end repeat
            return "nomatch"
        end tell

        \(stripHandler)
        """
        return execute(source) == "focused"
    }

    /// Open the url in a browser with nothing asked of it, or just launch the browser when
    /// there is no url. False means it did not go.
    ///
    /// **This is the fallback and not the ordinary path, which matters most for Arc.** A
    /// url handed to Arc this way opens in a Little Arc window — a popup that Arc's own
    /// AppleScript cannot even see, let alone put in a space. Routing goes through the
    /// script above precisely so that this never happens except when everything else has
    /// already failed.
    @discardableResult
    private static func launch(_ browser: Browser, url: String?) -> Bool {
        guard let app = browser.installedAt else { return false }
        guard let url, let target = URL(string: url) else {
            // **Named by bundle, not by `open -a <label>`.** "Brave" and "Brave Browser"
            // are not the same string to `open`, and the label is the one on screen.
            let done = DispatchSemaphore(value: 0)
            var ok = true
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                ok = error == nil
                done.signal()
            }
            return done.wait(timeout: .now() + 10) == .timedOut ? true : ok
        }
        // Waited on, because a cold launch may terminate this process as soon as the route
        // returns — the same reason ``Handoff/hand(_:)`` waits.
        let done = DispatchSemaphore(value: 0)
        var opened = true
        NSWorkspace.shared.open([target], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            opened = error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .timedOut ? true : opened
    }

    /// **Waited on, because the caller may terminate the process as soon as this returns**
    /// — a cold launch does exactly that. The timeout is long enough for a cold app launch
    /// and short enough that a wedged one still lets the link through.
    @discardableResult
    private static func openWaiting(_ urls: [URL], at application: URL) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var opened = true
        NSWorkspace.shared.open(urls, withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            opened = error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .timedOut ? true : opened
    }

    /// A trailing slash is not a different page. Nothing else is normalised away: a
    /// fragment and a query each name somewhere specific, so a link to one comment on a
    /// pull request must not be answered by focusing the tab showing the whole thread.
    private static let stripHandler = """
    on strip(u)
        set u to u as text
        if (count of u) > 1 and u ends with "/" then set u to text 1 thru -2 of u
        return u
    end strip
    """

    /// AppleScript is a string, so values are escaped into literals rather than
    /// interpolated raw — a url carrying a quote would otherwise rewrite the script.
    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String) -> Outcome {
        Outcome(rawValue: execute(source) ?? "") ?? .failed
    }

    private static func execute(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}

extension Handoff {
    /// Where the app is, or nil when it is not installed. **This is what a preset is
    /// offered by**: a rule pointing at an app that is not there is a rule that can only
    /// ever be skipped.
    var installedAt: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }
}
