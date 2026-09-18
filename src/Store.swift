import Foundation

/// Everything on disk: the rules, in the order they are consulted, and where a link goes
/// when none of them claims it.
struct Settings {
    /// **The order is the meaning.** First match wins, so this is a list and not a set, and
    /// the file's line order is load-bearing — a hand-edit that moves a line changes where
    /// links go.
    var rules: [Rule] = []
    /// Where a url goes when no rule claims it, stored as a `default<TAB>target` line.
    ///
    /// **This has to be a setting now.** While Dia was the only browser, "no rule matched"
    /// could mean "let Dia decide"; with the router sitting where the default browser used
    /// to be, there is nothing behind it, so the fallback is named.
    var fallback: Target = .dia
}

/// The rules on disk, at ~/.browser-router/rules.tsv.
///
/// **Tab-separated text rather than a plist or JSON**, because the file stays hand-editable
/// and greppable: this app is the editor, not the only way in.
///
/// **The whole file is rewritten on save**, header and all, so a comment added by hand
/// anywhere but the header does not survive a save made in the app. Preserving arbitrary
/// interleaved comments would mean tracking each rule's line, and a rule reordered by
/// specificity has no line to go back to.
enum Store {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".browser-router", isDirectory: true)
    static let file = directory.appendingPathComponent("rules.tsv")

    /// Where the file lived when this routed to one browser. **Moved, not copied**: two
    /// files with the same rules in them is one file being edited and another being read,
    /// and no way to tell from the outside which is which.
    private static let legacyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dia-router/rules.tsv")

    private static let header = """
    # Which browser, and which profile inside it, a url opens in. Edited by BrowserRouter —
    # open it from Spotlight.
    #
    # target<TAB>kind<TAB>pattern
    #
    # **The first rule that matches wins, so the order of these lines is what decides.**
    # Move a line up to give it priority. New rules written in the app are inserted by how
    # specific they are — narrow above broad — so a rule added later does not shadow one
    # that was already there.
    #
    # A `default<TAB>target` line is where a url goes when no rule claims it.
    #
    # A target is a browser, optionally with a profile after a colon:
    #
    #   dia:Work    chrome:Personal    arc:Side project    safari    firefox:default
    #
    # Browsers: dia, arc, chrome, brave, edge, vivaldi, safari, firefox, zen. Safari has no
    # way to be told which profile to use, so a profile written after it is ignored.
    #
    # Or an app, which skips the browser entirely:
    #
    #   app:linear    app:spotify    app:bear    app:things
    #
    # Any name works. linear, figma, notion, slack, teams, asana, discord, zoom and spotify
    # are rewritten the way each app actually wants; anything else swaps the scheme for the
    # name and keeps the path, which is what most apps expect. A link the app has no place
    # for — zoom.us/pricing is a web page — falls through to the next rule that matches.
    #
    #   host      a domain and its subdomains             example.com
    #   prefix    a url starting with this                github.com/acme
    #   pathhas   a host, then a word in its path         linear.app:acme
    #   regex     a raw regular expression                ^https?://foo\\.com/(a|b)
    #
    # Saving in the app rewrites this file, so comments added below are not kept.

    """

    static func load() -> Settings {
        adoptLegacyFile()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Settings() }
        var settings = Settings()
        var legacyApps: [Rule] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // **The old `app<TAB>linear` line, expanded into the rules it always meant.**
            // A handoff used to be a checkbox consulted before the table, so to keep a file
            // routing exactly as it did, its rules go to the *top* of the list — which is
            // what "before any rule below is looked at" means once everything is a rule.
            if fields.first == "app" {
                // **Deduped, because the old format could not tell you it had duplicates.**
                // Handoffs were a set, so a file listing `app figma` twice read as one
                // checkbox and looked fine; expanded literally it becomes two identical
                // rules, the second of which can never be reached.
                if fields.count >= 2, let app = Handoff(rawValue: fields[1]) {
                    for rule in app.suggestedRules
                    where !legacyApps.contains(where: { $0.target == rule.target && $0.pattern == rule.pattern }) {
                        legacyApps.append(rule)
                    }
                }
                continue
            }
            // **A `default` line naming a browser this build does not know is left alone**,
            // rather than quietly becoming Dia: the fallback is every unmatched link, so
            // getting it wrong is worse than the rest of the file put together.
            if fields.first == "default" {
                if fields.count >= 2, let target = Target(token: fields[1]) { settings.fallback = target }
                continue
            }
            guard fields.count >= 3,
                  let target = Target(token: fields[0]),
                  let kind = Kind(rawValue: fields[1])
            else { continue }
            let pattern = fields[2...].joined(separator: "\t")
            guard !pattern.isEmpty else { continue }
            settings.rules.append(Rule(target: target, kind: kind, pattern: pattern))
        }
        // A file written before the list was ordered has no order worth keeping — it was
        // sorted by specificity every time it was read — so it is seeded that way, with the
        // old handoffs above it where they used to sit.
        if !legacyApps.isEmpty {
            settings.rules = legacyApps + Rule.sortedBySpecificity(settings.rules)
        }
        return settings
    }

    /// Run before every read rather than once at launch: the router is resident, and the
    /// rename lands under a process that has been running since login.
    private static func adoptLegacyFile() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path), fm.fileExists(atPath: legacyFile.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.moveItem(at: legacyFile, to: file)
    }

    @discardableResult
    static func save(_ settings: Settings) -> Bool {
        // **Written in list order, never sorted.** Sorting here would quietly undo every
        // drag the user made, and the order is the only place that intent is recorded.
        let fallback = ["default\t\(settings.fallback.token)"]
        let rules = settings.rules.map { "\($0.target.token)\t\($0.kind.rawValue)\t\($0.pattern)" }
        let text = header + (fallback + rules).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
