import AppKit

/// Places a url in a Dia profile.
///
/// **AppleScript is the only surface that can do this.** `open -a Dia <url>` lands in
/// whichever window is in front and `--profile-directory` opens nothing at all; a Chrome
/// extension cannot help either, since an extension is sandboxed per profile and there is
/// no cross-profile tab api. Every quirk worked around below was measured against Dia's
/// own dictionary, not guessed.
enum Router {
    enum Outcome: String { case focused, created, noWindow = "nowindow", noMatch = "nomatch", failed }

    /// Route a url, falling back to Dia's own handling whenever anything goes wrong.
    ///
    /// **It never refuses.** A link in the wrong profile is a nuisance; a link that does
    /// not open is a broken machine.
    @discardableResult
    static func open(_ url: String, rules: [Rule]) -> Outcome {
        let decision = decide(url, against: rules)
        let wanted: String
        switch decision.verdict {
        case .profile(let p): wanted = p.diaProfileName
        case .native: wanted = ""
        }

        var outcome = run(url: url, wanted: wanted)

        // A routed url with nowhere to go: ask Dia for a window, then try once more.
        // `windows` is read-only in Dia's dictionary, so a window cannot be made directly.
        if outcome == .noWindow, !wanted.isEmpty {
            launchDia(with: nil)
            for _ in 0..<30 where !hasWindow() { usleep(100_000) }
            outcome = run(url: url, wanted: wanted)
        }

        switch outcome {
        case .focused, .created:
            return outcome
        default:
            // `nomatch` on an unrouted url is the ordinary path, not a failure: Dia opens
            // it wherever it would have.
            launchDia(with: url)
            return outcome
        }
    }

    private static func hasWindow() -> Bool {
        execute(#"tell application "Dia" to return (count of windows) as text"#) == "0" ? false : true
    }

    private static func launchDia(with url: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = url.map { ["-a", "Dia", $0] } ?? ["-a", "Dia"]
        try? task.run()
        task.waitUntilExit()
    }

    private static func run(url: String, wanted: String) -> Outcome {
        let result = execute(script(url: url, wanted: wanted)) ?? ""
        return Outcome(rawValue: result) ?? .failed
    }

    /// AppleScript is a string, so the two values are escaped into literals rather than
    /// interpolated raw — a url carrying a quote would otherwise rewrite the script.
    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func script(url: String, wanted: String) -> String {
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
            if wanted is "" then return "nomatch"
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
                -- meet: the name is the lookup key and Dia lets it be edited.
                return "failed"
            end try
        end tell

        -- A trailing slash is not a different page. Nothing else is normalised away: a
        -- fragment and a query each name somewhere specific, so a link to one comment on a
        -- pull request must not be answered by focusing the tab showing the whole thread.
        on strip(u)
            set u to u as text
            if (count of u) > 1 and u ends with "/" then set u to text 1 thru -2 of u
            return u
        end strip
        """
    }

    private static func execute(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
