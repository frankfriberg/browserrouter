import AppKit
import ApplicationServices
import SQLite3

/// **⌘T in Dia, answered here instead.** Dia is a Chromium, and Chromium keeps ⌘T for
/// itself: no extension can bind it, so there is no way to do this from inside the
/// browser at all. What is left is the key itself — a session event tap that swallows ⌘T
/// while Dia is in front, and a panel that searches the tabs Dia already has open.
///
/// **It never swallows more than it can answer.** Anything this does not handle — no
/// query, no match, the tap not installed, Dia not in front — ends with the browser
/// getting its own ⌘T back, because a key that does nothing is worse than no feature.

// MARK: - The tabs

/// One open tab, addressed the way that browser's AppleScript can find it again.
///
/// **The indices are a snapshot and are treated as one.** A tab moved or closed between
/// the panel opening and a row being picked would make them point at a different page, so
/// `url` is carried too and checked before anything is focused.
///
/// **`container` is a different thing in each family and deliberately unnamed.** It is a
/// profile in Dia, a space in Arc, and nothing at all in Chrome or Safari, where windows
/// hold tabs directly and it is always 1. Naming it `profile` would have made the
/// Chromium path read as though a profile were being addressed when none can be.
struct BrowserTab: Identifiable {
    let browser: Browser
    let window: Int
    let container: Int
    let tabIndex: Int
    let profile: String
    let url: String
    let title: String

    var id: String { "\(browser.rawValue).\(window).\(container).\(tabIndex).\(url)" }

    /// The url as it is typed rather than as it is stored: no scheme, no `www.`, no
    /// trailing slash. **This is the string the query is matched against**, because
    /// nobody looking for a tab types `https://`.
    var compact: String { BrowserTabs.compact(url) }
}

/// **A background app cannot show you what went wrong**, so it writes it down. One line
/// per read of Dia, at ~/Library/Logs/BrowserRouter.log, which is the only way to see
/// what the panel saw after the panel has gone.
enum Diagnostics {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BrowserRouter.log")

    static func note(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp)\t\(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

enum BrowserTabs {
    /// **Off the main thread, and on one thread of its own.** Reading every tab is a
    /// round trip through Apple events; on the main queue it would freeze the panel it is
    /// filling, and `NSAppleScript` is not something to hand to a concurrent queue.
    private static let queue = DispatchQueue(label: "com.frankfriberg.diarouter.tabs")

    /// **nil is not the same answer as none.** An empty list means Dia has no tabs; a
    /// refused script means Dia never answered, which is almost always the Automation
    /// grant — and the two look identical in a panel that only knows how to say "nothing
    /// matches", which is how an hour goes into the matching code of a feature whose
    /// permission was the problem.
    static func snapshot(_ browser: Browser,
                         _ done: @escaping (Result<[BrowserTab], Failure>) -> Void) {
        queue.async {
            asking = browser
            let answer = run(listScript(browser))
            let result: Result<[BrowserTab], Failure>
            switch answer {
            case .success(let text) where text == "nowindow": result = .failure(.noWindow(browser))
            case .success(let text): result = .success(parse(text, browser))
            case .failure(let failure): result = .failure(failure)
            }
            switch (answer, result) {
            case (.success(let text), .success(let tabs)):
                Diagnostics.note("read \(tabs.count) \(browser.label) tabs from \(text.count) characters: "
                    + text.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))
            case (.failure(let failure), _), (_, .failure(let failure)):
                Diagnostics.note("read failed: \(failure.sentence)")
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Why Dia did not answer, in the words the panel has to put on screen. **An error
    /// number is not a diagnosis but it is the only thing that separates a permission
    /// from a script that is wrong**, and without one on screen the two are guessed at.
    enum Failure: Error {
        case noWindow(Browser)
        case notPermitted(Browser)
        case script(code: Int, message: String)

        var sentence: String {
            switch self {
            case .noWindow(let browser):
                return "\(browser.label) has no window open."
            case .notPermitted(let browser):
                return "\(browser.label) would not answer. Allow BrowserRouter under System "
                     + "Settings → Privacy & Security → Automation."
            case .script(let code, let message):
                return "The browser answered with an error (\(code)). \(message)"
            }
        }
    }

    /// **Whether this browser can be asked what it has open at all.** Firefox and Zen
    /// ship the boilerplate Cocoa suite with no tab class in it, so there is nothing to
    /// list and nothing to focus — the same reason ``Router`` can never reuse a tab in
    /// one. ⌘T is left alone in those.
    static func supports(_ browser: Browser) -> Bool {
        if case .gecko = browser.mechanism { return false }
        return browser.installedAt != nil
    }

    /// The browser a keystroke belongs to, or nil when the app in front is not one this
    /// can drive.
    static func frontmost() -> Browser? {
        guard let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return nil }
        return Browser.allCases.first { $0.bundleIDs.contains(identifier) && supports($0) }
    }

    /// Bring a tab forward. **The indices are verified against the url before use**: if
    /// the tab has moved, the whole thing falls back to the router, which searches every
    /// tab for that url and focuses it wherever it now is.
    static func focus(_ tab: BrowserTab) {
        queue.async {
            if execute(focusScript(tab)) == "focused" { return }
            DispatchQueue.main.async { Router.open(tab.url, Store.load(), secondChance: false) }
        }
    }

    /// Load a url into whatever pane is focused right now.
    ///
    /// **Measured: this lands on a freshly opened split pane and is ignored by a tab that
    /// is already split.** Dia takes the write when the focused pane is a new one and
    /// silently drops it otherwise, which is exactly the shape the split command needs
    /// and the reason nothing else here navigates a tab this way.
    static func setFrontURL(_ browser: Browser, _ url: String) {
        queue.async {
            // Safari's front tab is `current tab`; everything else here calls it `active
            // tab`, and neither word is understood by the other.
            let front: String
            if case .none = browser.mechanism { front = "current tab" } else { front = "active tab" }
            _ = execute("""
            tell application "\(browser.scriptingName)"
                if (count of windows) is 0 then return "nowindow"
                set URL of \(front) of window 1 to \(literal(url))
                return "set"
            end tell
            """)
        }
    }

    /// Move the focused tab to another profile — the one rearrangement Dia's dictionary
    /// does expose, and the one that is genuinely awkward by hand.
    static func moveFrontTab(toProfile profile: String) {
        queue.async {
            // Dia only: `move` is its verb, and no other browser here publishes one.
            _ = execute("""
            tell application "Dia"
                if (count of windows) is 0 then return "nowindow"
                set t to active tab of window 1
                set p to (first profile of window 1 whose name is \(literal(profile)))
                move t to p
                return "moved"
            end tell
            """)
        }
    }

    /// Split the tab in front and open the page it is already showing in the new pane —
    /// the same url twice, side by side.
    ///
    /// **The url has to be read before the split, not after.** A tab's `URL` follows
    /// whichever pane is focused, and the pane the split opens is the new empty one, so
    /// asking afterwards answers `missing value` and duplicates nothing.
    static func duplicateIntoSplit(_ browser: Browser) {
        queue.async {
            let front: String
            if case .none = browser.mechanism { front = "current tab" } else { front = "active tab" }
            let url = execute("""
            tell application "\(browser.scriptingName)"
                if (count of windows) is 0 then return ""
                return (get URL of \(front) of window 1) as text
            end tell
            """)
            guard let url, !url.isEmpty, url != "missing value" else {
                Diagnostics.note("duplicate into split: no url on the tab in front")
                return
            }
            DispatchQueue.main.async {
                AppMenu.press(browser, "Open Split Pane")
                // The new pane exists a beat after the split; `set URL` lands on it only
                // once it is the focused one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { setFrontURL(browser, url) }
            }
        }
    }

    /// Close every tab in the profile in front. **Through the dictionary, not the menu**:
    /// `close` is a verb Dia actually publishes, so this is a send that either works or
    /// says why, rather than a menu item pressed at arm's length and hoped for.
    ///
    /// Counted backwards, because closing a tab renumbers the ones after it.
    static func closeFrontTabs(_ browser: Browser) {
        queue.async {
            // **What "all" means is what the browser groups tabs by.** Dia has profiles
            // inside a window and Arc has spaces, so closing "all" there means the one
            // you are in; a Chromium or Safari window holds its tabs directly, so it
            // means that window.
            let scope: String
            switch browser.mechanism {
            case .dia: scope = "active profile of window 1"
            case .arc: scope = "front window"
            default: scope = "window 1"
            }
            let answer = run("""
            tell application "\(browser.scriptingName)"
                if (count of windows) is 0 then return "nowindow"
                set p to \(scope)
                set n to (count of tabs of p)
                repeat with i from n to 1 by -1
                    try
                        close (item i of (tabs of p))
                    end try
                end repeat
                return "closed " & n
            end tell
            """)
            switch answer {
            case .success(let text): Diagnostics.note("close all tabs: \(text)")
            case .failure(let failure): Diagnostics.note("close all tabs: \(failure.sentence)")
            }
        }
    }

    /// Every profile in the front window, in their own order: what `move` can be given.
    static func profiles(_ tabs: [BrowserTab]) -> [String] {
        var seen: [String] = []
        for tab in tabs where !tab.profile.isEmpty && !seen.contains(tab.profile) {
            seen.append(tab.profile)
        }
        return seen
    }

    // MARK: Scripts

    /// The enumeration, one shape per family. **Every browser here answers a different
    /// dictionary and none of the four spellings survives a move to another**, which is
    /// the same split ``Browser/Mechanism`` already draws for routing.
    ///
    /// All of them emit the same seven fields, so only the asking differs:
    /// `window, container, tab, container name, url, is this the one in front, title`.
    private static func listScript(_ browser: Browser) -> String {
        switch browser.mechanism {
        case .dia: return diaList
        case .arc: return arcList
        case .chromium: return flatList(browser, title: "title", active: "active tab index of window 1")
        case .none: return safariList
        // Never asked: `supports` refuses these before a panel is ever opened.
        case .gecko: return ""
        }
    }

    /// Dia: profiles are objects inside a window and a tab lives in one.
    ///
    /// **The separators are made outside the tell block, and that is the whole reason
    /// this works.** Inside `tell application "Dia"` the word `tab` is Dia's *tab class*,
    /// not AppleScript's tab character: the script compiles, runs, returns a perfectly
    /// healthy string, and every field in it is joined by the literal word "tab".
    private static let diaList = """
    set fieldMark to (character id 9)
    set rowMark to (character id 10)
    tell application "Dia"
        if (count of windows) is 0 then return "nowindow"
        set out to ""
        -- **The tab you are looking at, so it can be left out of the list.** Focusing it
        -- is the one row in here that would do nothing at all. `isFocused` is true of one
        -- tab per profile, so the front window's active tab is asked for by id instead.
        set activeID to ""
        try
            set activeID to (id of active tab of window 1) as text
        end try
        repeat with wi from 1 to (count of windows)
            set ps to profiles of window wi
            repeat with pi from 1 to (count of ps)
                set p to item pi of ps
                set pn to ""
                try
                    set pn to (name of p) as text
                end try
                set us to {}
                set ns to {}
                set tl to {}
                -- Separately, because a title the dictionary will not give up must not
                -- cost the urls as well: a row with no title is still a row you can find.
                try
                    set us to (get URL of every tab of p)
                end try
                try
                    set ns to (get title of every tab of p)
                end try
                try
                    set tl to tabs of p
                end try
                repeat with i from 1 to (count of us)
                    set u to ""
                    try
                        set u to (item i of us) as text
                    end try
                    set t to ""
                    try
                        if i is less than or equal to (count of ns) then set t to (item i of ns) as text
                    end try
                    if u is not "" then
                        set isCurrent to "0"
                        try
                            if ((id of (item i of tl)) as text) is activeID then set isCurrent to "1"
                        end try
                        set out to out & wi & fieldMark & pi & fieldMark & i & fieldMark & pn ¬
                            & fieldMark & u & fieldMark & isCurrent & fieldMark & t & rowMark
                    end if
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """

    /// Arc: Dia's idea with none of Dia's spelling. **A space is `title`, never `name`**,
    /// and the list has to be read with `get … of every`, both measured in ``Router/arc``
    /// against Arc's own refusals.
    private static let arcList = """
    set fieldMark to (character id 9)
    set rowMark to (character id 10)
    tell application "Arc"
        if (count of windows) is 0 then return "nowindow"
        set out to ""
        set activeID to ""
        try
            set activeID to (id of active tab of window 1) as text
        end try
        repeat with wi from 1 to (count of windows)
            set ts to (get title of every space of window wi)
            repeat with si from 1 to (count of ts)
                set sn to ""
                try
                    set sn to (item si of ts) as text
                end try
                set us to {}
                set ns to {}
                set tl to {}
                try
                    set us to (get URL of every tab of space si of window wi)
                end try
                try
                    set ns to (get title of every tab of space si of window wi)
                end try
                try
                    set tl to tabs of space si of window wi
                end try
                repeat with i from 1 to (count of us)
                    set u to ""
                    try
                        set u to (item i of us) as text
                    end try
                    set t to ""
                    try
                        if i is less than or equal to (count of ns) then set t to (item i of ns) as text
                    end try
                    if u is not "" then
                        set isCurrent to "0"
                        try
                            if ((id of (item i of tl)) as text) is activeID then set isCurrent to "1"
                        end try
                        set out to out & wi & fieldMark & si & fieldMark & i & fieldMark & sn ¬
                            & fieldMark & u & fieldMark & isCurrent & fieldMark & t & rowMark
                    end if
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """

    /// Chrome, Brave, Edge and Vivaldi: **no containers at all.** A Chromium's dictionary
    /// has never heard of profiles — each one is a separate window and nothing in the
    /// scripting says which — so the container is always 1 and the chip is left empty
    /// rather than filled with a guess.
    private static func flatList(_ browser: Browser, title: String, active: String) -> String {
        """
        set fieldMark to (character id 9)
        set rowMark to (character id 10)
        tell application "\(browser.scriptingName)"
            if (count of windows) is 0 then return "nowindow"
            set out to ""
            set activeIndex to -1
            try
                set activeIndex to \(active)
            end try
            repeat with wi from 1 to (count of windows)
                set us to {}
                set ns to {}
                -- A tab that has never loaded answers `missing value` for its URL, which
                -- is not a string and cannot be compared.
                try
                    set us to (get URL of every tab of window wi)
                end try
                try
                    set ns to (get \(title) of every tab of window wi)
                end try
                repeat with i from 1 to (count of us)
                    set u to ""
                    try
                        set u to (item i of us) as text
                    end try
                    set t to ""
                    try
                        if i is less than or equal to (count of ns) then set t to (item i of ns) as text
                    end try
                    if u is not "" then
                        set isCurrent to "0"
                        if wi is 1 and i is activeIndex then set isCurrent to "1"
                        set out to out & wi & fieldMark & 1 & fieldMark & i & fieldMark & "" ¬
                            & fieldMark & u & fieldMark & isCurrent & fieldMark & t & rowMark
                    end if
                end repeat
            end repeat
            return out
        end tell
        """
    }

    /// Safari: tabs like a Chromium's, but **a tab is named `name`, not `title`**, and the
    /// one in front is an object rather than an index — so it is recognised by its url.
    private static let safariList = """
    set fieldMark to (character id 9)
    set rowMark to (character id 10)
    tell application "Safari"
        if (count of windows) is 0 then return "nowindow"
        set out to ""
        set activeURL to ""
        try
            set activeURL to (get URL of current tab of window 1) as text
        end try
        repeat with wi from 1 to (count of windows)
            set us to {}
            set ns to {}
            try
                set us to (get URL of every tab of window wi)
            end try
            try
                set ns to (get name of every tab of window wi)
            end try
            repeat with i from 1 to (count of us)
                set u to ""
                try
                    set u to (item i of us) as text
                end try
                set t to ""
                try
                    if i is less than or equal to (count of ns) then set t to (item i of ns) as text
                end try
                if u is not "" then
                    set isCurrent to "0"
                    if wi is 1 and u is activeURL then set isCurrent to "1"
                    set out to out & wi & fieldMark & 1 & fieldMark & i & fieldMark & "" ¬
                        & fieldMark & u & fieldMark & isCurrent & fieldMark & t & rowMark
                end if
            end repeat
        end repeat
        return out
    end tell
    """

    /// Bringing one forward, which is the other half each dictionary spells its own way:
    /// Dia focuses a tab, Arc selects one, a Chromium sets an index, and Safari is handed
    /// the tab object itself.
    private static func focusScript(_ tab: BrowserTab) -> String {
        let name = tab.browser.scriptingName
        switch tab.browser.mechanism {
        case .dia:
            return """
            tell application "\(name)"
                activate
                if (count of windows) < \(tab.window) then return "gone"
                set ps to profiles of window \(tab.window)
                if (count of ps) < \(tab.container) then return "gone"
                set p to item \(tab.container) of ps
                set tl to tabs of p
                if (count of tl) < \(tab.tabIndex) then return "gone"
                set t to item \(tab.tabIndex) of tl
                -- The snapshot may be stale by now; the url is what says whether it is.
                if ((get URL of t) as text) is not \(literal(tab.url)) then return "gone"
                focus t
                return "focused"
            end tell
            """
        case .arc:
            return """
            tell application "\(name)"
                activate
                if (count of windows) < \(tab.window) then return "gone"
                set sp to space \(tab.container) of window \(tab.window)
                if (count of tabs of sp) < \(tab.tabIndex) then return "gone"
                if ((get URL of tab \(tab.tabIndex) of sp) as text) is not \(literal(tab.url)) then return "gone"
                -- `select`, not `focus`: focus is the space's verb, select is the tab's,
                -- and selecting brings the space along with it.
                select tab \(tab.tabIndex) of sp
                return "focused"
            end tell
            """
        case .chromium:
            return """
            tell application "\(name)"
                activate
                if (count of windows) < \(tab.window) then return "gone"
                if (count of tabs of window \(tab.window)) < \(tab.tabIndex) then return "gone"
                if ((get URL of tab \(tab.tabIndex) of window \(tab.window)) as text) is not \(literal(tab.url)) then return "gone"
                set active tab index of window \(tab.window) to \(tab.tabIndex)
                set index of window \(tab.window) to 1
                return "focused"
            end tell
            """
        case .none:
            return """
            tell application "\(name)"
                activate
                if (count of windows) < \(tab.window) then return "gone"
                if (count of tabs of window \(tab.window)) < \(tab.tabIndex) then return "gone"
                if ((get URL of tab \(tab.tabIndex) of window \(tab.window)) as text) is not \(literal(tab.url)) then return "gone"
                -- Safari's tabs are objects you assign, not an index you set.
                set current tab of window \(tab.window) to tab \(tab.tabIndex) of window \(tab.window)
                set index of window \(tab.window) to 1
                return "focused"
            end tell
            """
        case .gecko:
            return ""
        }
    }

    private static func parse(_ text: String, _ browser: Browser) -> [BrowserTab] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 7,
                  let window = Int(fields[0]),
                  let container = Int(fields[1]),
                  let tabIndex = Int(fields[2])
            else { return nil }
            // **`missing value` is a real answer here, not a failure.** An empty split
            // pane has no url, and it arrives as those two words because the script
            // coerces to text; matched as a string it would look like a tab called
            // "missing value" that can never be focused.
            guard fields[4] != "missing value" else { return nil }
            // **The tab in front is not an answer to "which tab".** It is already the one
            // on screen, so it is dropped here rather than offered and then doing nothing.
            guard fields.count >= 7, fields[5] != "1" else { return nil }
            // A title with a tab in it is still one title.
            let title = fields[6...].joined(separator: "\t")
            return BrowserTab(browser: browser, window: window, container: container,
                              tabIndex: tabIndex, profile: fields[3], url: fields[4], title: title)
        }
    }

    /// What both a url and a typed query are reduced to before they are compared.
    static func compact(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where t.hasPrefix(scheme) {
            t.removeFirst(scheme.count)
        }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        if t.count > 1, t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Whether every character of `query` appears in `haystack` in order, and how well.
    /// **Lower is better, and nil is no match at all.** A run of characters that sit
    /// together scores better than the same characters scattered, and a character that
    /// starts a word — after a dot, slash, dash or space — is treated as though it were
    /// adjacent, which is what makes `lh5001` find `localhost:5001` and `ghpr` find a
    /// pull request on github.
    static func fuzzy(_ query: String, _ haystack: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let boundaries: Set<Character> = [".", "/", ":", "-", "_", " ", "?", "&", "="]
        var score = 0
        var index = haystack.startIndex
        var previous: String.Index?
        for character in query {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            if let previous {
                let gap = haystack.distance(from: previous, to: found) - 1
                if gap > 0 {
                    // A jump that lands on the start of a word is what the typist meant;
                    // a jump into the middle of one is a coincidence and is charged for.
                    let before = haystack[haystack.index(before: found)]
                    score += boundaries.contains(before) ? 1 : gap + 2
                }
            } else {
                // How far in the first character sits: an answer that starts with what
                // was typed is nearly always the one meant.
                score += haystack.distance(from: haystack.startIndex, to: found)
            }
            previous = found
            index = haystack.index(after: found)
        }
        return score
    }

    /// **Prefix first, then anywhere — and the prefix is read in both directions.**
    /// `localhost:5100` is the start of a url rather than a word inside one, so a tab
    /// whose url begins with it outranks one that merely mentions it. The other direction
    /// is the one that matters more often than it should: **Dia answers with a discarded
    /// tab's entry url, not the page it is actually showing**, so a tab sitting on
    /// `localhost:5001/accounts/…` is reported as plain `localhost:5001` and could not
    /// otherwise be found by the url on its own screen. A query that starts with what the
    /// tab claims is treated as a match for it.
    static func matches(_ query: String, in tabs: [BrowserTab]) -> [BrowserTab] {
        ranked(query, in: tabs).map(\.0)
    }

    /// The same search, with the strength of each match kept. **A strong match and a
    /// fuzzy one are not the same answer**: one is the page you asked for, the other is a
    /// page that happens to contain those letters in that order, and only the first of
    /// them should outrank "open what I typed".
    static func ranked(_ query: String, in tabs: [BrowserTab]) -> [(BrowserTab, Int)] {
        let q = compact(query)
        // Nothing typed matches everything, and every match is as good as every other.
        guard !q.isEmpty else { return tabs.map { ($0, 0) } }
        let words = q.split(separator: " ").map(String.init)
        return tabs.compactMap { tab -> (BrowserTab, Int, Int)? in
            let haystack = tab.compact + " " + tab.title.lowercased()
            let rank: Int
            if tab.compact.hasPrefix(q) { rank = 0 }
            // Only past the host, so that `l` does not match every localhost tab there is
            // and `github.com/a` does not answer with the whole of github.
            else if q.hasPrefix(tab.compact), tab.compact.contains("/") || q.count > tab.compact.count + 1 { rank = 1 }
            else if tab.compact.contains(q) { rank = 2 }
            else if words.allSatisfy({ haystack.contains($0) }) { rank = 3 }
            // **Last, and only last.** Fuzzy matching finds everything eventually, so it
            // is what answers when nothing above did rather than something that competes
            // with a real prefix.
            else if let score = fuzzy(q.replacingOccurrences(of: " ", with: ""), haystack) {
                return (tab, 4, score)
            }
            else { return nil }
            return (tab, rank, tab.compact.count)
        }
        // Shorter url first inside a rank: `localhost:5100` itself before the page six
        // levels down inside it.
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .map { ($0.0, $0.1) }
    }

    /// Whether what was typed is a place rather than a search: a scheme, a host with a
    /// dot in it, or a port on localhost. **This is what decides that ↩ opens something**
    /// rather than focusing whichever tab the letters happened to fuzzy-match.
    static func looksLikeURL(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.contains(" "), q.count > 3 else { return false }
        if q.contains("://") { return true }
        if q.hasPrefix("localhost") { return true }
        guard let dot = q.firstIndex(of: "."), dot != q.startIndex else { return false }
        // Something after the dot, and not a sentence: `example.com`, not `etc.`
        return q.index(after: dot) < q.endIndex
    }

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func execute(_ source: String) -> String? {
        try? run(source).get()
    }

    /// The browser a script is being sent to right now, for the one error that has to
    /// name it: "Safari would not answer" is a permission to grant, and "the browser
    /// would not answer" is a shrug.
    private static var asking: Browser = .dia

    private static func run(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.script(code: 0, message: "The script would not compile."))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            // -1743 is "not authorised to send Apple events", which is the Automation
            // switch and nothing else.
            return .failure(code == -1743 ? .notPermitted(asking) : .script(code: code, message: message))
        }
        return .success(result.stringValue ?? "")
    }
}

/// **Dia's profile colours, read from the file Chromium keeps them in.** The AppleScript
/// dictionary has no colour on `profile` — only a name and an index — so the one place
/// they exist is `Local State`, where a Chromium writes `profile_color_seed` as a signed
/// ARGB integer beside each profile's name.
///
/// Read once per panel and never written to. A missing file, a renamed key or a profile
/// this build has never seen all end the same way: no colour, and the panel uses its own.
enum ProfileColours {
    static func load(_ browser: Browser) -> [String: NSColor] {
        guard let file = BrowserHistory.userData(browser)?
                .appendingPathComponent("Local State"),
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profile"] as? [String: Any],
              let cache = profiles["info_cache"] as? [String: Any]
        else { return [:] }
        var colours: [String: NSColor] = [:]
        for (_, value) in cache {
            guard let profile = value as? [String: Any],
                  let name = profile["name"] as? String,
                  let seed = profile["profile_color_seed"] as? Int
            else { continue }
            // Pale seeds are dropped here rather than at every place they would be used.
            colours[name] = colour(seed).vivid
        }
        return colours
    }

    /// Chromium stores an `SkColor` — 0xAARRGGBB — in a signed 32-bit field, so the value
    /// on disk is negative for every colour that is not transparent.
    private static func colour(_ seed: Int) -> NSColor {
        let argb = UInt32(bitPattern: Int32(truncatingIfNeeded: seed))
        return NSColor(srgbRed: CGFloat((argb >> 16) & 255) / 255,
                       green: CGFloat((argb >> 8) & 255) / 255,
                       blue: CGFloat(argb & 255) / 255,
                       alpha: 1)
    }
}

/// A page that is not open: somewhere Dia has been, read out of the history a Chromium
/// keeps in SQLite beside each profile.
struct HistoryPage: Identifiable {
    let title: String
    let url: String
    let profile: String
    /// When it was last open. **Chromium counts microseconds from 1601**, which is the
    /// Windows epoch and 11,644,473,600 seconds before Unix's.
    let lastVisit: Date?

    var id: String { profile + url }
    var compact: String { BrowserTabs.compact(url) }

    /// How long ago, in the words a person would use. **Relative, not a date**: the
    /// question a history row answers is "was this this morning or last month", and a
    /// timestamp makes that a subtraction the reader has to do.
    var when: String {
        guard let lastVisit else { return "" }
        let seconds = Date().timeIntervalSince(lastVisit)
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        case ..<172_800: return "yesterday"
        case ..<604_800: return "\(Int(seconds / 86_400))d ago"
        default:
            let format = DateFormatter()
            // No year until it is a different one: "3 Sep" beats "03/09/2026" at a glance.
            format.setLocalizedDateFormatFromTemplate(
                Calendar.current.isDate(lastVisit, equalTo: Date(), toGranularity: .year)
                    ? "d MMM" : "MMM yyyy")
            return format.string(from: lastVisit)
        }
    }
}

/// **Dia's history, read directly and never written to.** There is no scripting for it —
/// the dictionary knows about windows, profiles and tabs and nothing else — but the file
/// is an ordinary Chromium `History` database, one per profile.
enum BrowserHistory {
    /// Where a browser keeps the profile directories that hold its history.
    ///
    /// **Every Chromium keeps the same shape in a different place**, and the support
    /// directory is already written down per browser for the profile picker — Dia and Arc
    /// put theirs under `User Data`, the rest are the support directory itself. Safari and
    /// the Firefox family have neither this shape nor this schema, so they have no
    /// history here.
    static func userData(_ browser: Browser) -> URL? {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        switch browser.mechanism {
        case .dia: return support.appendingPathComponent("Dia/User Data")
        case .arc: return support.appendingPathComponent("Arc/User Data")
        case .chromium(let directory): return support.appendingPathComponent(directory)
        case .none, .gecko: return nil
        }
    }

    /// The directories holding a profile's own data, by the name that profile shows.
    private static func profileDirectories(_ browser: Browser) -> [(name: String, url: URL)] {
        guard let userData = userData(browser),
              let data = try? Data(contentsOf: userData.appendingPathComponent("Local State")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profile"] as? [String: Any],
              let cache = profiles["info_cache"] as? [String: Any]
        else { return [] }
        return cache.compactMap { directory, value in
            guard let profile = value as? [String: Any],
                  let name = profile["name"] as? String else { return nil }
            return (name, userData.appendingPathComponent(directory, isDirectory: true))
        }
    }

    /// Pages matching `query`, the most visited first.
    ///
    /// **Opened `immutable=1`, which is what makes this safe while Dia is running.** The
    /// database is locked by the browser; asking SQLite for a normal read-only handle
    /// fails or waits, and asking for an immutable one reads the file as it stands
    /// without taking a lock or writing a journal. The cost is that a page visited in the
    /// last moment may not be there yet, which for a history search is no cost at all.
    static func search(_ browser: Browser, _ query: String, limit: Int32 = 6) -> [HistoryPage] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }
        let pattern = "%" + text.replacingOccurrences(of: " ", with: "%") + "%"
        var pages: [HistoryPage] = []
        for profile in profileDirectories(browser) {
            let file = profile.url.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var database: OpaquePointer?
            let path = "file:" + file.path.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)! + "?immutable=1"
            guard sqlite3_open_v2(path, &database,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
            else { sqlite3_close(database); continue }
            defer { sqlite3_close(database) }
            // `hidden` skips the redirects and subframes nobody typed or clicked.
            let sql = """
            SELECT url, title, last_visit_time FROM urls
            WHERE hidden = 0 AND (url LIKE ?1 OR title LIKE ?1)
            ORDER BY visit_count DESC, last_visit_time DESC LIMIT ?2
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(statement, 2, limit)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let url = sqlite3_column_text(statement, 0) else { continue }
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let stamp = sqlite3_column_int64(statement, 2)
                let visited = stamp > 0
                    ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600)
                    : nil
                pages.append(HistoryPage(title: title, url: String(cString: url),
                                         profile: profile.name, lastVisit: visited))
            }
        }
        return pages
    }
}

extension Browser.Mechanism {
    /// Whether tabs live in something inside a window — a Dia profile, an Arc space —
    /// rather than in the window itself.
    var groupsTabs: Bool {
        switch self {
        case .dia, .arc: return true
        default: return false
        }
    }
}

extension NSColor {
    /// The colour, or nothing when it is too pale to be one. **Dia's "Personal" seed is
    /// `#E3E6EC`** — a near-white that tints a highlight to no visible difference and a
    /// chip to a smudge, so a profile carrying one is better left uncoloured than
    /// coloured invisibly.
    var vivid: NSColor? {
        guard let colour = usingColorSpace(.sRGB) else { return nil }
        guard colour.saturationComponent >= 0.18, colour.brightnessComponent <= 0.92 else { return nil }
        return colour
    }
}

// MARK: - Dia's own menus

/// **Everything Dia can do that its dictionary cannot say.** Split panes and pinned pages
/// are absent from the sdef entirely — `focus`, `close`, `move`, `make` and a JavaScript
/// command gated behind a launch flag are the whole of it — but they are all in the menu
/// bar, and a menu item can be pressed through Accessibility.
///
/// **Pressed in-process rather than through System Events.** The tap already costs an
/// Accessibility grant; going via System Events would cost an Apple-events grant for it
/// as well, and a second prompt for something the app can do itself.
enum AppMenu {
    /// Every item of every top-level menu, by title, with the menu it sits in.
    ///
    /// **Scanned whole rather than asked menu by menu, because the menus are not the same
    /// two browsers running.** Dia keeps its tab commands under "Tabs", Chrome under
    /// "Tab", Safari spreads them between "Window" and "File". Searching by the item's own
    /// title is what lets one catalogue serve all of them — and what makes the palette
    /// offer exactly what the browser in front actually has.
    static func index(_ browser: Browser) -> [(title: String, bar: AXUIElement, item: AXUIElement)] {
        guard let app = application(browser),
              let menubar = attribute(app, kAXMenuBarAttribute as String)
        else { return [] }
        // swiftlint:disable:next force_cast
        var found: [(String, AXUIElement, AXUIElement)] = []
        for bar in children(menubar as! AXUIElement) {
            guard let menu = children(bar).first else { continue }
            for item in children(menu) {
                let name = title(item)
                guard !name.isEmpty else { continue }
                found.append((name, bar, item))
            }
        }
        return found
    }

    /// Just the titles — what the palette checks a command against.
    static func titles(_ browser: Browser) -> [String] { index(browser).map(\.title) }

    /// Press an item by its exact title, or by its start — **"Return to github.com" names
    /// the site it goes back to**, so the pinned command can only ever match a prefix.
    ///
    /// **The shortcut first, when the item has one.** A menu item that publishes a key
    /// equivalent can be had by sending that key to the browser: no menu opens, nothing
    /// flashes. Measured in Dia: Open Split Pane is ⌃V, and the pane commands are ⌃L
    /// and ⌃H.
    ///
    /// **Otherwise the menu is opened first, and that is not decoration.** Pressing an
    /// item in a closed menu returns `.success` and does nothing at all: a Chromium wires
    /// its items to their actions only while their menu is on screen. Measured: "Clean Up
    /// Tabs" answered success on every press and tidied nothing.
    static func press(_ browser: Browser, _ titleOrPrefix: String) {
        guard let match = index(browser).first(where: {
            $0.title == titleOrPrefix || $0.title.hasPrefix(titleOrPrefix)
        }) else {
            Diagnostics.note("\(browser.label) menu → \(titleOrPrefix): no such item")
            return
        }
        if let stroke = shortcut(match.item) {
            send(stroke, to: browser)
            Diagnostics.note("\(browser.label) menu → \(titleOrPrefix): sent its shortcut")
            return
        }
        AXUIElementPerformAction(match.bar, kAXPressAction as CFString)
        // The menu opens on the browser's own run loop, so the item is pressed after it
        // has had a moment rather than in the same breath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard attribute(match.item, kAXEnabledAttribute as String) as? Bool ?? true else {
                Diagnostics.note("\(browser.label) menu → \(titleOrPrefix): disabled")
                if let menu = children(match.bar).first {
                    AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                }
                return
            }
            let code = AXUIElementPerformAction(match.item, kAXPressAction as CFString)
            Diagnostics.note("\(browser.label) menu → \(titleOrPrefix): \(code.rawValue)")
        }
    }

    private static func application(_ browser: Browser) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: browser.bundleIDs[0]).first
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// The key equivalent an item publishes, as a key code and the flags to send with it.
    ///
    /// **`AXMenuItemCmdModifiers` is a mask of what to *add*, with one bit inverted**: bit
    /// 3 means "no Command", which is why ⌃V arrives here as 12 rather than as 4.
    private static func shortcut(_ item: AXUIElement) -> (CGKeyCode, CGEventFlags)? {
        guard let character = (attribute(item, "AXMenuItemCmdChar") as? String)?.lowercased().first,
              let code = keyCodes[character]
        else { return nil }
        let mask = attribute(item, "AXMenuItemCmdModifiers") as? Int ?? 0
        var flags: CGEventFlags = []
        if mask & 1 != 0 { flags.insert(.maskShift) }
        if mask & 2 != 0 { flags.insert(.maskAlternate) }
        if mask & 4 != 0 { flags.insert(.maskControl) }
        if mask & 8 == 0 { flags.insert(.maskCommand) }
        return (code, flags)
    }

    private static func send(_ stroke: (code: CGKeyCode, flags: CGEventFlags), to browser: Browser) {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: browser.bundleIDs[0]).first
        else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: stroke.code, keyDown: down) else { continue }
            event.flags = stroke.flags
            // Stamped like the ⌘T this app hands back, so its own tap lets it through.
            event.setIntegerValueField(.eventSourceUserData, value: Hotkey.passThrough)
            event.postToPid(app.processIdentifier)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    private static func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute as String) as? String ?? ""
    }

    /// **The ANSI layout, because a key code is a position and not a letter.** Only the
    /// keys a menu shortcut is ever built from are here; anything else falls back to
    /// opening the menu, which needs no mapping at all.
    private static let keyCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
    ]
}

// MARK: - The key

/// The event tap. **A tap is the only way to see ⌘T at all** — a global hotkey API cannot
/// register a combination the frontmost app has already claimed, and Dia claims this one.
enum Hotkey {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?

    /// Stamped on the ⌘T this app posts back to Dia, and skipped when it comes past the
    /// tap. **Without it the pass-through is an infinite loop**: the event we post is an
    /// event we see.
    static let passThrough: Int64 = 0x44_49_41_54

    private static let keyT: Int64 = 17

    /// Whether Accessibility has been granted. **Asked every time rather than
    /// remembered**: the grant can be taken away in System Settings, and a stored yes
    /// would then describe a tap that is not running.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The system's own prompt, which is the only one that can lead anywhere: an app
    /// cannot grant itself Accessibility.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static var isInstalled: Bool { tap != nil }

    /// **The grant arrives long after it is asked for, and nothing announces it.** The
    /// prompt sends the user to System Settings, the switch is flipped there, and the app
    /// is never told — so the install is retried the next time a browser comes to the
    /// front, which is the moment before the first ⌘T that could possibly matter.
    static func retryWhenBrowserAppears() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                guard tap == nil, !Store.load().tabSwitcher.isEmpty, isTrusted else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let identifier = app?.bundleIdentifier ?? ""
                guard Browser.allCases.contains(where: { $0.bundleIDs.contains(identifier) })
                else { return }
                install(true)
            }
    }

    /// The pane the grant is given in. Deep-linked, because the list it is in is four
    /// levels down and named after something else.
    static func openAccessibilitySettings() {
        guard let pane = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(pane)
    }

    /// Start or stop intercepting. Returns false when the tap could not be made, which in
    /// practice means Accessibility has not been granted.
    @discardableResult
    static func install(_ on: Bool) -> Bool {
        if !on {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            source = nil
            tap = nil
            return true
        }
        if tap != nil { return true }
        guard isTrusted else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Hotkey.handle(type, event) },
            userInfo: nil)
        else { return false }
        let loop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = loop
        return true
    }

    /// **On the main run loop, so this runs on the main thread** — and must return at
    /// once. Everything the panel does is dispatched rather than done here: a tap that
    /// takes too long is a tap the system switches off mid-keystroke.
    private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // **The system disables a tap it thinks is slow, and says so exactly once.**
        // Without re-enabling here, ⌘T silently goes back to Dia for ever.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != passThrough,
              event.getIntegerValueField(.keyboardEventKeycode) == keyT
        else { return Unmanaged.passUnretained(event) }
        // ⌘⇧T is reopen-closed-tab and ⌥⌘T is somebody else's: only the bare combination
        // is taken.
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard flags == .maskCommand else { return Unmanaged.passUnretained(event) }
        // **Whichever browser is in front, if it is one this can drive and one the
        // settings name.** The tap sees every ⌘T on the machine; everything else's stays
        // its own.
        guard let browser = BrowserTabs.frontmost(),
              Store.load().tabSwitcher.contains(browser)
        else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { SwitcherPanel.shared.show(browser) }
        return nil
    }

    /// Hand ⌘T back to the browser — the answer to every case this panel decides it
    /// cannot answer. Stamped, so the tap above lets it through.
    static func passThroughTab(to browser: Browser) {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: browser.bundleIDs[0]).first
        else { return }
        app.activate(options: [])
        // A beat, because the key has to arrive after Dia is actually in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: CGKeyCode(keyT), keyDown: down) else { continue }
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: passThrough)
                event.postToPid(app.processIdentifier)
            }
        }
    }
}

// MARK: - The commands

/// One line in the palette: a verb to type, and the thing it does to the tab in front.
struct PaletteCommand: Identifiable {
    let verb: String
    /// The other words that mean this command. **Typed, not prefixed**: a command has to
    /// be findable by the word someone would actually reach for — "unsplit", "tidy",
    /// "reset" — because a palette you have to know the vocabulary of is a menu.
    let keywords: [String]
    /// An SF Symbol. **The one thing that says this row is a verb and not a page**, now
    /// that commands and tabs share a list.
    let symbol: String
    let title: String
    let hint: String
    /// Whether the rest of the line is a url this command loads. Everything else ignores
    /// what follows its verb rather than refusing it.
    let takesURL: Bool
    let run: (String) -> Void

    var id: String { verb + title }
}

/// **The palette is built from Dia's menus every time it opens, not written down once.**
/// Dia changes its own menu with the state of the tab in front — "Separate Tabs" exists
/// only while a tab is split, "Return to …" only on a pinned one — so reading the menu is
/// how a command that could not work is left out instead of offered and failing.
enum Palette {
    /// A command that is a menu item somewhere in the browser's menu bar. **The title is
    /// the key and the menu is not**: browsers file the same command under different
    /// menus, and several of these exist in one browser and not the next.
    private struct Entry {
        let item: String
        let verb: String
        let keywords: [String]
        let symbol: String
        let title: String
        let hint: String
        /// True when `item` is the start of the real title rather than the whole of it.
        var isPrefix = false
    }

    /// **Everything worth offering that any of these browsers can do from a menu.** What
    /// a browser does not have simply never matches, so this is one list rather than one
    /// list per browser — and a browser that grows a split view tomorrow gets the command
    /// with no change here.
    private static let catalogue: [Entry] = [
        Entry(item: "Open Split Pane", verb: "split", keywords: ["pane", "side by side", "beside"],
              symbol: "rectangle.split.2x1", title: "Split this tab",
              hint: "Type a url after it to open one in the new pane"),
        Entry(item: "Focus Next Split Pane", verb: "next", keywords: ["pane", "switch", "other"],
              symbol: "arrow.right.to.line", title: "Focus the next pane", hint: ""),
        Entry(item: "Focus Previous Split Pane", verb: "previous",
              keywords: ["pane", "switch", "other", "back"],
              symbol: "arrow.left.to.line", title: "Focus the previous pane", hint: ""),
        Entry(item: "Separate Tabs", verb: "separate", keywords: ["unsplit", "split", "apart"],
              symbol: "rectangle.split.2x1.slash", title: "Separate the panes into tabs",
              hint: "Undoes the split"),
        Entry(item: "Close Tab", verb: "close", keywords: ["quit", "pane"],
              symbol: "xmark", title: "Close this tab", hint: ""),
        Entry(item: "Reopen Closed Tab", verb: "reopen", keywords: ["undo", "restore", "back"],
              symbol: "arrow.uturn.left", title: "Reopen the last closed tab", hint: ""),
        Entry(item: "Return to ", verb: "pinned", keywords: ["reset", "return", "home", "pin"],
              symbol: "arrow.uturn.backward", title: "Return to the pinned page",
              hint: "Back to what this tab is pinned to", isPrefix: true),
        Entry(item: "Edit Pinned Page", verb: "pin", keywords: ["pinned", "edit"],
              symbol: "pin", title: "Edit the pinned page", hint: "Pin this tab here instead"),
        Entry(item: "Pin Tab", verb: "pin", keywords: ["pinned"], symbol: "pin",
              title: "Pin this tab", hint: ""),
        Entry(item: "Pin", verb: "pin", keywords: ["pinned"], symbol: "pin",
              title: "Pin this tab", hint: ""),
        Entry(item: "Duplicate Tab", verb: "duplicate", keywords: ["copy", "clone", "same"],
              symbol: "plus.square.on.square", title: "Duplicate this tab", hint: ""),
        Entry(item: "Duplicate", verb: "duplicate", keywords: ["copy", "clone", "same"],
              symbol: "plus.square.on.square", title: "Duplicate this tab", hint: ""),
        Entry(item: "Move Tab to New Window", verb: "detach", keywords: ["window", "out", "pop"],
              symbol: "macwindow.on.rectangle", title: "Move this tab to a new window", hint: ""),
        Entry(item: "Merge All Windows", verb: "merge", keywords: ["windows", "gather", "one"],
              symbol: "square.stack", title: "Merge every window into one", hint: ""),
        Entry(item: "Mute Site", verb: "mute", keywords: ["sound", "audio", "silence"],
              symbol: "speaker.slash", title: "Mute this site", hint: ""),
        Entry(item: "Mute Tab", verb: "mute", keywords: ["sound", "audio", "silence"],
              symbol: "speaker.slash", title: "Mute this tab", hint: ""),
    ]

    /// **Read while the browser is still frontmost**, in the moment the panel opens: a
    /// menu belongs to the app in front, and this is what its state is being read for.
    ///
    /// The menus are the capability list — "Separate Tabs" is in Dia only while a tab is
    /// split, "Return to …" only on a pinned one — so a command that could not work is
    /// left out rather than offered and failing.
    static func commands(_ browser: Browser) -> [PaletteCommand] {
        let menu = AppMenu.titles(browser)
        let has = { (entry: Entry) in
            entry.isPrefix ? menu.contains { $0.hasPrefix(entry.item) } : menu.contains(entry.item)
        }
        var seen = Set<String>()
        var out: [PaletteCommand] = []
        for entry in catalogue where has(entry) && seen.insert(entry.verb + entry.title).inserted {
            // "Close Tab" closes the focused half while a tab is split, which is the whole
            // of Dia's answer to "close the split": there is no menu item for it.
            let split = menu.contains("Separate Tabs")
            let title = entry.verb == "close" && split ? "Close this pane" : entry.title
            let hint = entry.verb == "close" && split ? "Leaves the other half of the split" : entry.hint
            let item = entry.item
            out.append(PaletteCommand(
                verb: entry.verb, keywords: entry.keywords, symbol: entry.symbol,
                title: title, hint: hint, takesURL: entry.verb == "split") { url in
                    AppMenu.press(browser, item)
                    guard entry.verb == "split", !url.isEmpty else { return }
                    // **The new pane has to exist before it can be given a url**, and the
                    // only signal that it does is that it is now the focused one.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        BrowserTabs.setFrontURL(browser, Palette.url(url))
                    }
                })
        }
        if menu.contains("Open Split Pane") {
            out.append(PaletteCommand(
                verb: "duplicate", keywords: ["compare", "clone", "same", "side", "split"],
                symbol: "rectangle.split.2x1.fill",
                title: "Duplicate this tab into a split",
                hint: "The same page beside itself, for comparing",
                takesURL: false) { _ in BrowserTabs.duplicateIntoSplit(browser) })
        }
        // **Sent through the dictionary rather than the menu**, so it does not depend on a
        // menu being open — and it is the one command here that throws something away, so
        // it says so plainly rather than hiding behind a word like tidy.
        out.append(PaletteCommand(
            verb: "clean", keywords: ["cleanup", "tidy", "empty", "all"],
            symbol: "trash", title: "Close all tabs",
            hint: browser.mechanism.groupsTabs ? "Every tab in this profile" : "Every tab in this window",
            takesURL: false) { _ in BrowserTabs.closeFrontTabs(browser) })
        return out
    }

    /// **One line per profile rather than a profile to type.** Dia only: `move` is its
    /// verb and no other browser here publishes one — a Chromium cannot even say which
    /// profile a window belongs to.
    static func moveCommands(_ browser: Browser, profiles: [String]) -> [PaletteCommand] {
        guard case .dia = browser.mechanism else { return [] }
        return profiles.map { profile in
            PaletteCommand(verb: "move", keywords: ["profile", "space", profile.lowercased()],
                           symbol: "arrow.right.square", title: "Move this tab to \(profile)",
                           hint: "", takesURL: false) { _ in
                BrowserTabs.moveFrontTab(toProfile: profile)
            }
        }
    }

    /// Always last, and always there: the one command that needs nothing of the browser.
    static let open = PaletteCommand(
        verb: "open", keywords: ["new", "go", "url", "tab"], symbol: "arrow.up.forward.app",
        title: "Open a url", hint: "Through the rules, like any other link",
        takesURL: true) { url in
            guard !url.isEmpty else { return }
            Router.open(Palette.url(url), Store.load(), secondChance: false)
        }

    /// What is typed is a url without a scheme far more often than not.
    static func url(_ typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        return t.contains("://") ? t : "https://\(t)"
    }

    /// **What was typed, split into the word that might be a verb and the rest.** There
    /// is no prefix to type any more: `split localhost:3000` is a command and
    /// `localhost:3000` is a tab, and the only difference is whether the first word is a
    /// verb this palette knows. A leading `>` still works, and means commands only.
    static func parse(_ query: String) -> (head: String, rest: String) {
        var text = query.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(">") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard let space = text.firstIndex(of: " ") else { return (text.lowercased(), "") }
        return (String(text[text.startIndex..<space]).lowercased(),
                String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    /// A command, how directly it was asked for, and the url typed after it.
    ///
    /// **Rank is the whole of how commands and tabs share one list.** A word that is a
    /// verb — `split`, `close`, `pin` — is an instruction and goes above the tabs; a word
    /// that merely appears somewhere in a command's wording is a guess and goes below
    /// them, where it cannot get in the way of finding a page.
    static func matches(_ query: String, in commands: [PaletteCommand]) -> [(PaletteCommand, Int, String)] {
        let (head, rest) = parse(query)
        guard !head.isEmpty else { return [] }
        let words = (head + " " + rest).split(separator: " ").map(String.init)
        return commands.compactMap { command in
            let vocabulary = ([command.verb] + command.keywords + [command.title.lowercased()])
                .joined(separator: " ")
            let rank: Int
            if command.verb.hasPrefix(head) { rank = 0 }
            else if command.keywords.contains(where: { $0.hasPrefix(head) }) { rank = 1 }
            // Everything typed has to be in there, or `split github.com` would offer
            // every command in the palette alongside the one that was asked for.
            else if words.allSatisfy({ vocabulary.contains($0) }) { rank = 2 }
            else if BrowserTabs.fuzzy(head, command.verb) != nil { rank = 3 }
            else { return nil }
            return (command, rank, command.takesURL ? rest : "")
        }
        .sorted { ($0.1, $0.0.verb) < ($1.1, $1.0.verb) }
    }
}

// MARK: - The panel

/// **Borderless and non-activating in style, but it does take key.** An accessory app has
/// no menu bar to lose and nothing else on screen, so the simplest thing that can read a
/// keystroke is a panel that becomes key and hands Dia back the front when it closes.
final class SwitcherWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// **⌘V is a menu item, and this app has no menu.** The editing shortcuts everyone
    /// expects in a text field are not built into the field: they are key equivalents on
    /// the Edit menu, which an accessory app only has while its rules window is open. A
    /// search field you cannot paste a url into is the one thing this panel must not be,
    /// so the handful that matter are dispatched here instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // ⌘↩ never reaches `doCommandBy:`, so it is caught here with the rest.
        if key == "\r" {
            SwitcherPanel.shared.openTyped()
            return true
        }
        let action: Selector?
        switch key {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(("undo:"))
        default: action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

final class SwitcherPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate,
                           NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SwitcherPanel()

    private var window: SwitcherWindow?
    private var field: NSTextField!
    private var table: NSTableView!
    /// **One highlight for the whole list, moved rather than redrawn.** A selection each
    /// row paints for itself can only ever appear and disappear; a single view can travel
    /// between them, which is what makes holding an arrow key read as movement instead of
    /// as flicker.
    private let highlight = NSView()
    /// Whether the next move of it is a journey or a jump. Typing rebuilds the list
    /// underneath the selection, and sliding the highlight across a list that has just
    /// changed is a lie about where it came from.
    private var slideHighlight = false
    private var hint: NSTextField!
    private var action: ActionBadge!
    private var tabs: [BrowserTab] = []
    /// Dia's own colour for each profile, read when the panel opens. **The selection is
    /// tinted with the colour of the profile the row lives in**, so the highlight says
    /// where a tab is as well as which one it is.
    private var profileColours: [String: NSColor] = [:]
    /// What the last read of Dia actually did: still running, answered, or refused.
    private var read: Read = .reading
    private enum Read { case reading, answered, failed(BrowserTabs.Failure) }
    private var commands: [PaletteCommand] = []
    private var shown: [Row] = []
    /// **A command that has been chosen and is waiting for its url.** Splitting with
    /// nothing is a blank pane and a second trip to the address bar, so the command asks
    /// first: the panel stays open, the list becomes the tabs you could split with, and
    /// what you type or pick is what the new pane opens.
    private var pending: PaletteCommand?
    /// **The browser the keystroke was taken from.** ⌘T is swallowed in whichever
    /// supported browser is in front, so the panel is not about one browser — everything
    /// it reads, lists and presses belongs to this one.
    private var browser: Browser = .dia
    /// Pages found in Dia's history for what is typed now, and the keystroke they belong
    /// to. **The search runs off the main thread and the answer can arrive late**, so it
    /// is thrown away unless the field still says what it said when it was asked.
    private var history: [HistoryPage] = []
    private var historyFor = ""
    /// **What was typed last time, offered again.** A panel that opens empty makes you
    /// retype a url you were halfway through when something interrupted; selected whole,
    /// so the next keystroke replaces it and nothing is in the way.
    private static var lastQuery = ""

    /// **Three kinds of line in one list**, because they are reached by typing rather than
    /// by a mode anyone has to remember: a url-ish thing finds a tab, a verb finds a
    /// command, and a heading says which is which without anyone reading a row.
    private enum Row {
        case section(String)
        case tab(BrowserTab)
        /// Somewhere Dia has been but is not now.
        case page(HistoryPage)
        /// The url typed after the verb travels with the row, so running it does not have
        /// to re-read the field and guess at it again.
        case command(PaletteCommand, argument: String)

        /// Headings are scenery: arrow keys go past them and ↩ cannot land on one.
        var isSelectable: Bool {
            if case .section = self { return false }
            return true
        }
    }

    private static let searchPrompt = "Search your open tabs, or type a command"

    private enum Metric {
        static let width: CGFloat = 720
        static let height: CGFloat = 440
        static let corner: CGFloat = 14
        static let gutter: CGFloat = 18
        static let searchHeight: CGFloat = 56
        static let footerHeight: CGFloat = 40
        static let row: CGFloat = 42
        static let section: CGFloat = 28
    }

    func show(_ browser: Browser) {
        let window = window ?? build()
        self.window = window
        self.browser = browser
        field.stringValue = Self.lastQuery
        field.placeholderString = Self.searchPrompt
        pending = nil
        history = []
        historyFor = ""
        tabs = []
        read = .reading
        shown = []
        // **Read before the panel is on screen**, while Dia is still the frontmost app
        // and its menu bar is the one the state belongs to.
        commands = Palette.commands(browser) + [Palette.open]
        profileColours = ProfileColours.load(browser)
        table.reloadData()
        hint.stringValue = "Reading \(browser.label)’s tabs…"
        action.set(nil)
        place(window)
        // Above everything, including Dia's own windows, since Dia stays visible behind it.
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        BrowserTabs.snapshot(browser) { [weak self] result in
            guard let self, self.window?.isVisible == true else { return }
            switch result {
            case .success(let tabs):
                self.read = .answered
                self.tabs = tabs
            case .failure(let failure):
                self.read = .failed(failure)
                self.tabs = []
            }
            // **The menus are not read again here.** Dia is behind the panel by now and
            // a menu read from behind can answer differently; only the part that came
            // from the tabs is added.
            self.commands = self.commands.filter { $0.verb != "open" }
                + Palette.moveCommands(browser, profiles: BrowserTabs.profiles(self.tabs))
                + [Palette.open]
            self.refilter()
        }
    }

    /// **Where a panel like this belongs is above the middle, not in it.** Centred
    /// vertically it sits over the page you are reading; a third of the way down is where
    /// every other one of these opens, and it leaves the list room to grow downwards.
    private func place(_ window: SwitcherWindow) {
        guard let screen = NSScreen.main?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2 + screen.height * 0.12))
    }

    /// A rounded rectangle that can be stretched to any size without its corners
    /// stretching with it — the cap insets are what keep the radius constant.
    private static func corners(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func build() -> SwitcherWindow {
        let window = SwitcherWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metric.width, height: Metric.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // **The system's appearance, and a material that survives both of them.** Pinning
        // the panel dark made it wrong on a light desktop; what was actually wrong was
        // the material. See `blur.material` below.
        window.hasShadow = true
        window.delegate = self
        window.hidesOnDeactivate = false

        let blur = NSVisualEffectView()
        // **`.menu`, because it is the one material that is legible in both
        // appearances.** `.hudWindow` is built for a dark overlay: in the light
        // appearance it comes out a flat mid-grey and takes the text down with it, which
        // is the dimness a light system showed over a dark page. The menu material stays
        // translucent, brightens in light and darkens in dark, and keeps its contrast
        // against whatever page is behind it.
        blur.material = .menu
        blur.state = .active
        blur.blendingMode = .behindWindow
        // **Rounded by a mask image, not by a clipped layer.** `cornerRadius` on a
        // vibrancy view rounds what it draws and not what it samples: the corners keep a
        // pale fringe of the window's own backing, which is the white showing through the
        // edges. A mask image is what AppKit gives vibrancy for a non-rectangular shape,
        // and it cuts the blur itself.
        blur.maskImage = Self.corners(radius: Metric.corner)
        window.contentView = blur

        let glass = NSImageView()
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.contentTintColor = .tertiaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false

        field = NSTextField()
        field.placeholderString = Self.searchPrompt
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        // **The banding was the table's own doing.** Alternating row colours are on by
        // default in some styles, and over a blur they read as stripes rather than as
        // rows: the only background this list wants is the one behind the panel.
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // **The selection is drawn by the row, not by the table** — but the table must
        // still say there is one. `.none` here does not mean "draw it yourself": it turns
        // the drawing off entirely, row views included, and the list loses its highlight
        // altogether while the arrow keys go on moving something invisible.
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pick)
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.isHidden = true
        // Under the rows, in the table's own coordinates, so it scrolls with them.
        table.addSubview(highlight, positioned: .below, relativeTo: nil)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        // The clip view has a background of its own, and it is white by default: over a
        // blur that is a pale block sitting where the list scrolls.
        scroll.contentView.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false

        action = ActionBadge()
        action.translatesAutoresizingMaskIntoConstraints = false

        // **No rules across the panel.** The search row, the list and the footer are
        // held apart by the space around them; a line through a blur is the one thing
        // that makes it look like a window with panes in it.
        for view in [glass, field, scroll, hint, action] as [NSView] {
            blur.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Metric.gutter),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16),
            glass.heightAnchor.constraint(equalToConstant: 16),

            field.topAnchor.constraint(equalTo: blur.topAnchor, constant: 17),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Metric.gutter),

            scroll.topAnchor.constraint(equalTo: blur.topAnchor, constant: Metric.searchHeight),
            scroll.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: blur.bottomAnchor,
                                           constant: -Metric.footerHeight),

            hint.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Metric.gutter),
            hint.centerYAnchor.constraint(equalTo: action.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -12),

            action.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            action.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -8),
        ])
        return window
    }

    // MARK: Filtering

    func controlTextDidChange(_ notification: Notification) {
        searchHistory()
        refilter()
    }

    /// Ask the history for what is in the field, and fold the answer in when it lands.
    private func searchHistory() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let browser = self.browser
        guard pending == nil, !query.hasPrefix(">"), query.count >= 2 else {
            history = []
            historyFor = ""
            return
        }
        guard query != historyFor else { return }
        historyFor = query
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pages = BrowserHistory.search(browser, query)
            DispatchQueue.main.async {
                guard let self, self.historyFor == query else { return }
                self.history = pages
                self.refilter()
            }
        }
    }

    private func refilter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let matched = Palette.matches(query, in: commands)
        let asked = matched.prefix { $0.1 <= 1 }.count
        let rows = { (slice: ArraySlice<(PaletteCommand, Int, String)>) in
            slice.map { Row.command($0.0, argument: $0.2) }
        }
        let found = BrowserTabs.ranked(query, in: tabs)
        // A page that starts with, contains, or is contained by what was typed is the one
        // asked for; anything found only by fuzzy matching is a suggestion.
        let sure = found.filter { $0.1 <= 2 }.map { Row.tab($0.0) }
        let loose = found.filter { $0.1 > 2 }.map { Row.tab($0.0) }
        // **The url row carries the whole query as its argument.** `open` takes what
        // follows its verb, and a url typed on its own has no verb in front of it.
        let opens = BrowserTabs.looksLikeURL(query)
            ? [Row.command(Palette.open, argument: query)] : []

        shown = []
        if pending != nil {
            // No commands while one is being completed: the only thing a second verb
            // could do here is replace the first one halfway through.
            shown = section("Split with an open tab", query.isEmpty
                ? tabs.map(Row.tab) : BrowserTabs.matches(query, in: tabs).map(Row.tab))
        } else if query.hasPrefix(">") {
            shown = section("Commands", rows(matched[...]))
        } else if query.isEmpty {
            // **Nothing typed is a tab list, not a menu.** ⌘T then ↩ is the fastest thing
            // this panel does and a command sitting in that path would break it.
            shown = section("Open tabs", tabs.map(Row.tab))
        } else {
            // A verb above the pages; the page you typed out in full above the pages that
            // merely resemble it; a chance resemblance below them all.
            // A page already open is a tab, not a memory: the history rows are only the
            // ones you cannot simply be taken to.
            let openNow = Set(tabs.map(\.compact))
            let visited = history
                .filter { !openNow.contains($0.compact) }
                .map(Row.page)
            shown = section("Commands", rows(matched.prefix(asked)))
                + section("Open tabs", sure)
                + section("Open", opens)
                + section(sure.isEmpty ? "Open tabs" : "Also matching", loose)
                + section("History", visited)
                + section("Other commands", rows(matched.dropFirst(asked)))
        }
        table.reloadData()
        slideHighlight = false
        selectFirst()
        moveHighlight()
        describe(query)
    }

    /// A heading and its rows, or nothing at all when there are no rows to head.
    private func section(_ title: String, _ rows: [Row]) -> [Row] {
        rows.isEmpty ? [] : [.section(title)] + rows
    }

    private func describe(_ query: String) {
        if let pending {
            action.set(pending.verb == "split" ? "Split here" : "Go")
            hint.stringValue = "esc to go back · ↩ with nothing splits an empty pane"
            return
        }
        action.set(self.selected.map {
            switch $0 {
            case .tab: return "Focus tab"
            case .page: return "Open"
            case .command(let command, _): return command.verb == "open" ? "Open" : "Run"
            case .section: return ""
            }
        })
        switch read {
        case .reading where shown.isEmpty:
            hint.stringValue = "Reading \(browser.label)’s tabs…"
        // **Named, not swallowed.** Dia refusing to be asked is a permission to grant,
        // and it is nothing at all like a query that found no page.
        case .failed(let failure):
            hint.stringValue = failure.sentence
        default:
            if !shown.isEmpty {
                hint.stringValue = "↑↓ to choose · ⌘↩ opens what you typed · esc to clear"
            } else if query.isEmpty {
                hint.stringValue = "No open tabs. ↩ hands ⌘T back to \(browser.label)."
            } else {
                hint.stringValue = "Nothing matches. ↩ opens \(query)."
            }
        }
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            pick()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // **Escape backs out of the command before it closes the panel.** Having to
            // start again from ⌘T because the url was mistyped would make the second step
            // cost more than the address bar it replaces.
            if pending != nil {
                pending = nil
                field.stringValue = ""
                field.placeholderString = Self.searchPrompt
                refilter()
                return true
            }
            // **Escape empties the field before it closes the panel.** A search you want
            // to start over is a keystroke, not a reopen — and the panel remembers what
            // was typed, so closing on a cleared field is what says "nothing, thanks".
            if !field.stringValue.isEmpty {
                field.stringValue = ""
                searchHistory()
                refilter()
                return true
            }
            dismiss(returningToBrowser: true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        default:
            return false
        }
    }

    private var selected: Row? {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return nil }
        return shown[row]
    }

    private func selectFirst() {
        guard let first = shown.firstIndex(where: { $0.isSelectable }) else {
            highlight.isHidden = true
            return
        }
        table.selectRowIndexes([first], byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    /// Put the highlight where the selection is — sliding there when the arrow keys sent
    /// it, arriving instantly when the list underneath it has just been rebuilt.
    private func moveHighlight() {
        let slide = slideHighlight
        slideHighlight = false
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { highlight.isHidden = true; return }
        let frame = table.rect(ofRow: row).insetBy(dx: 8, dy: 2)
        // The neutral highlight, with the profile's colour laid over it where there is
        // one — the same two coats the rows used to paint, in one view.
        var colour = NSColor.labelColor.withAlphaComponent(0.12)
        switch shown[row] {
        case .tab(let tab):
            if let tint = profileColours[tab.profile] { colour = tint.withAlphaComponent(0.30) }
        case .page(let page):
            if let tint = profileColours[page.profile] { colour = tint.withAlphaComponent(0.30) }
        default: break
        }
        let appear = highlight.isHidden
        highlight.isHidden = false
        if slide, !appear {
            NSAnimationContext.runAnimationGroup { context in
                // **Short enough to keep up with a held arrow key.** Anything longer and
                // the highlight is still travelling when the next press arrives, so the
                // list feels slower than the key repeat rather than in step with it.
                context.duration = 0.06
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                highlight.animator().frame = frame
                highlight.layer?.backgroundColor = colour.cgColor
            }
        } else {
            // **No implicit animation on the jump.** A layer changes its colour over a
            // quarter-second by default, which is long enough to see the old profile's
            // colour on the new list.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.frame = frame
            highlight.layer?.backgroundColor = colour.cgColor
            CATransaction.commit()
        }
    }

    /// **Headings are stepped over, not stopped on.** Moving down onto one and needing a
    /// second press would make the arrow keys lie about how far one press goes.
    private func move(by delta: Int) {
        guard !shown.isEmpty else { return }
        slideHighlight = true
        var row = table.selectedRow
        repeat {
            row += delta
            guard row >= 0, row < shown.count else { return }
        } while !shown[row].isSelectable
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        describe(field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        moveHighlight()
        describe(field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// **Three answers, and the last of them is Dia's.** A row focuses that tab or runs
    /// that command; a query with nothing behind it is routed like any other link, so the
    /// text typed is not thrown away; an empty query is ⌘T, handed back.
    @objc private func pick() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        // A command waiting for a url takes the tab that is selected, or the url typed,
        // and an empty line still means "split with nothing" rather than nothing at all.
        if let pending {
            var url = query
            if case .tab(let tab)? = selected, !tab.url.isEmpty { url = tab.url }
            if case .page(let page)? = selected { url = page.url }
            self.pending = nil
            dismiss(returningToBrowser: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pending.run(url.isEmpty ? "" : Palette.url(url))
            }
            return
        }
        if let selected {
            switch selected {
            case .section:
                return
            case .tab(let tab):
                dismiss(returningToBrowser: false)
                BrowserTabs.focus(tab)
            case .page(let page):
                dismiss(returningToBrowser: false)
                Router.open(page.url, Store.load(), secondChance: false)
            case .command(let command, let argument):
                // A command that opens a url and was given none asks for one rather than
                // guessing.
                if command.takesURL, argument.isEmpty, command.verb != "open" {
                    begin(command)
                    return
                }
                // **Dia has to be in front before a menu item is pressed**: the menu
                // belongs to the app that owns it, and the split it opens belongs to
                // whichever window is frontmost.
                dismiss(returningToBrowser: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { command.run(argument) }
            }
            return
        }
        dismiss(returningToBrowser: false)
        guard !query.hasPrefix(">") else { return }
        guard !query.isEmpty else { Hotkey.passThroughTab(to: browser); return }
        Router.open(Palette.url(query), Store.load(), secondChance: false)
    }

    /// Hand the panel over to a command that still needs a url.
    private func begin(_ command: PaletteCommand) {
        pending = command
        field.stringValue = ""
        field.placeholderString = "\(command.title) — type a url, or pick a tab"
        refilter()
    }

    private func dismiss(returningToBrowser: Bool) {
        Self.lastQuery = field.stringValue
        window?.orderOut(nil)
        guard returningToBrowser else { return }
        NSRunningApplication
            .runningApplications(withBundleIdentifier: browser.bundleIDs[0])
            .first?.activate(options: [])
    }

    /// Clicking anywhere else is a cancel, the same as escape.
    func windowDidResignKey(_ notification: Notification) {
        Self.lastQuery = field.stringValue
        window?.orderOut(nil)
    }

    /// **⌘↩ means the url, whatever is selected.** Typing `google.com` finds every open
    /// tab with google in it, and the one thing those rows cannot do is take you to
    /// google.com; this is the way past them without arrowing down to the Open row.
    func openTyped() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if let pending {
            self.pending = nil
            dismiss(returningToBrowser: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pending.run(Palette.url(query)) }
            return
        }
        dismiss(returningToBrowser: false)
        Router.open(Palette.url(query), Store.load(), secondChance: false)
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        shown[row].isSelectable ? Metric.row : Metric.section
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        shown[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SelectionRow()
        view.backgroundColor = .clear
        switch shown[row] {
        case .tab(let tab): view.tint = profileColours[tab.profile]
        case .page(let page): view.tint = profileColours[page.profile]
        default: break
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch shown[row] {
        case .section(let title):
            let identifier = NSUserInterfaceItemIdentifier("section")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SectionView
                ?? SectionView(identifier: identifier)
            view.fill(title)
            return view
        case .tab(let tab):
            // A tab that has never had a title is named by its url rather than by nothing.
            return cell(tableView).filled(
                title: tab.title.isEmpty ? tab.compact : tab.title,
                detail: tab.compact, trailing: tab.profile,
                tint: profileColours[tab.profile], symbol: "globe", isCommand: false)
        case .page(let page):
            return cell(tableView).filled(
                title: page.title.isEmpty ? page.compact : page.title,
                detail: page.compact, trailing: page.profile,
                tint: profileColours[page.profile], symbol: "clock", isCommand: false,
                when: page.when)
        case .command(let command, let argument):
            // The url typed after the verb is shown on the row that will use it, so
            // `split localhost:3000` reads as the thing it is about to do.
            return cell(tableView).filled(
                title: command.title, detail: argument.isEmpty ? command.hint : argument,
                trailing: "Command", tint: nil, symbol: command.symbol, isCommand: true)
        }
    }

    private func cell(_ tableView: NSTableView) -> RowView {
        let identifier = NSUserInterfaceItemIdentifier("row")
        return tableView.makeView(withIdentifier: identifier, owner: self) as? RowView
            ?? RowView(identifier: identifier)
    }

    /// **The selection, drawn inset and rounded.** It is the one piece of chrome the eye
    /// tracks while typing, so it is a shape rather than the full-width system bar.
    private final class SelectionRow: NSTableRowView {
        /// The profile's own colour, when the row belongs to one.
        var tint: NSColor?

        /// The blur behind the panel is the background; a row painting its own is what
        /// put stripes over it.
        override func drawBackground(in dirtyRect: NSRect) {}

        /// **Drawn by the panel's one moving highlight, not here.** A row that painted
        /// its own selection would leave a second, stationary one behind the travelling
        /// view every time the arrow keys moved.
        override func drawSelection(in dirtyRect: NSRect) {}

        /// **Emphasis is what makes the system tint a selection blue**, and this one is
        /// drawn by hand: saying no here keeps it the same shade whether or not the panel
        /// is the key window.
        override var isEmphasized: Bool {
            get { false }
            set {}
        }
    }

    /// A heading: small, quiet, and never in the way of a row.
    private final class SectionView: NSTableCellView {
        private let label = NSTextField(labelWithString: "")

        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            self.identifier = identifier
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.gutter),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func fill(_ text: String) { label.stringValue = text }
    }

    private final class RowView: NSTableCellView {
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        /// When, for a history row. Sits between the url and the profile chip, where the
        /// eye is already going on its way to the end of the line.
        private let meta = NSTextField(labelWithString: "")
        private let trailing = Chip()
        /// **What tells a verb from a page at a glance.** Both kinds of row are in one
        /// list now, and the symbol is the only difference that does not need reading.
        private let icon = NSImageView()

        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            self.identifier = identifier
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            // **The detail gives way first.** A url is long and a title is not, so the
            // thing that truncates when the panel runs out of room is the url — from the
            // middle, where a path can lose its way without losing its host.
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            icon.imageScaling = .scaleProportionallyUpOrDown

            meta.font = .systemFont(ofSize: 11)
            meta.textColor = .tertiaryLabelColor
            meta.alignment = .right
            meta.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            let stack = NSStackView(views: [icon, title, detail, NSView(), meta, trailing])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.setCustomSpacing(12, after: icon)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 17),
                icon.heightAnchor.constraint(equalToConstant: 17),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.gutter),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.gutter),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        @discardableResult
        func filled(title text: String, detail note: String, trailing kind: String,
                    tint: NSColor?, symbol: String, isCommand: Bool, when: String = "") -> RowView {
            title.stringValue = text
            detail.stringValue = note
            detail.isHidden = note.isEmpty
            meta.stringValue = when
            meta.isHidden = when.isEmpty
            trailing.fill(kind, tint: tint)
            // **A symbol this build does not have is no symbol at all**, not a blank box:
            // the names below are ordinary ones, but the list moves between releases.
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = isCommand ? .controlAccentColor : .secondaryLabelColor
            return self
        }
    }

    /// **The profile a tab lives in, worn as a chip.** A word on its own at the end of a
    /// row reads as more of the url; a chip reads as a label, and it is where a profile's
    /// own colour can be shown without tinting the whole row.
    private final class Chip: NSView {
        private let label = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 5
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func fill(_ text: String, tint: NSColor?) {
            isHidden = text.isEmpty
            label.stringValue = text
            guard let tint else {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                label.textColor = .tertiaryLabelColor
                return
            }
            layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor
            // Pulled towards the text colour so it stays readable in either appearance;
            // the chip behind it is what carries the profile's hue.
            label.textColor = tint.blended(withFraction: 0.45, of: .labelColor) ?? tint
        }
    }

    /// What ↩ will do to whatever is selected, in the corner where the eye ends up.
    private final class ActionBadge: NSView {
        private let label = NSTextField(labelWithString: "")
        private let key = NSTextField(labelWithString: "↩")

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            key.font = .systemFont(ofSize: 11, weight: .semibold)
            key.textColor = .secondaryLabelColor
            key.alignment = .center
            key.wantsLayer = true
            key.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            key.layer?.cornerRadius = 4

            let stack = NSStackView(views: [label, key])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                key.widthAnchor.constraint(equalToConstant: 18),
                key.heightAnchor.constraint(equalToConstant: 16),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Nothing selected is nothing to promise, so the badge goes away rather than
        /// offering an action that has no row to act on.
        func set(_ text: String?) {
            isHidden = text?.isEmpty ?? true
            label.stringValue = text ?? ""
        }
    }
}
