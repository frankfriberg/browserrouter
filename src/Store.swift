import Foundation

/// Everything on disk: the rules, and which desktop apps get their own links.
///
/// The file holds both because they are read and written together — see ``Settings``.
struct Settings {
    var rules: [Rule] = []
    /// The desktop apps links are handed to, stored as `app<TAB>name` lines.
    var apps: Set<Handoff> = []
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
    # Which browser, and which profile inside it, a url opens in. Edited by BrowserRouter — open it from Spotlight.
    #
    # target<TAB>kind<TAB>pattern
    #
    # An `app<TAB>name` line hands that site's links to its desktop app instead, before any
    # rule below is looked at: app<TAB>linear, figma, notion, zoom, spotify.
    #
    # A `default<TAB>browser:profile` line is where a url goes when no rule claims it.
    #
    # A target is a browser, optionally with a profile after a colon:
    #
    #   dia:All Gravy    chrome:allgravy.com    arc:Work    safari    firefox:default
    #
    # Browsers: dia, arc, chrome, brave, edge, vivaldi, safari, firefox. Safari has no way
    # to be told which profile to use, so a profile written after it is ignored.
    #
    #   host      a domain and its subdomains             allgravy.com
    #   prefix    a url starting with this                github.com/buttersolutions
    #   pathhas   a host, then a word in its path         linear.app:all-gravy
    #   regex     a raw regular expression                ^https?://foo\\.com/(a|b)
    #
    # Specificity decides which rule wins, never the order of these lines: regex, then
    # prefix, then pathhas, then host, and the longer pattern first within a kind. A rule
    # for github.com/buttersolutions therefore beats one for github.com on its own.
    #
    # Saving in the app rewrites this file, so comments added below are not kept.

    """

    static func load() -> Settings {
        adoptLegacyFile()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Settings() }
        var settings = Settings()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // **An unknown app name is dropped, not kept.** A line written by hand for an
            // app this build has never heard of cannot be honoured, and keeping it would
            // mean writing it back out as something that still does nothing.
            if fields.first == "app" {
                if fields.count >= 2, let app = Handoff(rawValue: fields[1]) { settings.apps.insert(app) }
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
        // The app lines go first, because that is the order they are consulted in.
        let apps = Handoff.allCases.filter { settings.apps.contains($0) }.map { "app\t\($0.rawValue)" }
        let fallback = ["default\t\(settings.fallback.token)"]
        let rules = settings.rules.map { "\($0.target.token)\t\($0.kind.rawValue)\t\($0.pattern)" }
        let text = header + (apps + fallback + rules).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
