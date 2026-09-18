import Foundation

/// Where a url ends up. **`app` means it never reaches a browser at all**; everything
/// else is a browser and, where the browser has them, a profile inside it.
///
/// There is no `native` case any more. Once this app is the system default browser there
/// is no browser behind it to fall through to, so "nothing matched" is a ``Target`` like
/// any other — the one in ``Settings/fallback`` — and it is chosen rather than implied.
enum Verdict: Equatable {
    case app(Handoff)
    case target(Target)
}

/// A site whose links its own desktop app can open, and the deep link that gets them there.
///
/// **These are toggled, not written as rules**, because there is nothing to write: the host
/// and the deep-link shape are properties of the app, not of anyone's setup. A toggle is
/// also the honest control — the only question is whether you want that app or a browser.
///
/// **A handoff is decided before any rule is**, in ``decide(_:against:handingOff:)``. The
/// rules table answers "which browser profile", and an app that isn't a browser cannot be
/// ranked against it: routing a Linear link into the Linear app is the same answer whether
/// the link is work or personal.
///
/// Adding one is adding a case. The deep link is measured against the app, never guessed —
/// each shape below was checked against the scheme the app actually declares.
enum Handoff: String, CaseIterable, Identifiable, Hashable {
    case linear, figma, notion, slack, teams, asana, discord, zoom, spotify

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .figma: return "Figma"
        case .notion: return "Notion"
        case .slack: return "Slack"
        case .teams: return "Microsoft Teams"
        case .asana: return "Asana"
        case .discord: return "Discord"
        case .zoom: return "Zoom"
        case .spotify: return "Spotify"
        }
    }

    /// **A list, because an app can ship under more than one identifier.** Teams did
    /// exactly that: the rewritten app took a new one and left the old bundle installed
    /// beside it. The first one present wins.
    var bundleIDs: [String] {
        switch self {
        case .linear: return ["com.linear"]
        case .figma: return ["com.figma.Desktop"]
        case .notion: return ["notion.id"]
        case .slack: return ["com.tinyspeck.slackmacgap"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .asana: return ["com.electron.asana"]
        case .discord: return ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]
        case .zoom: return ["us.zoom.xos"]
        case .spotify: return ["com.spotify.client"]
        }
    }

    /// The web hosts it takes links for, each matched like a `host` rule: the domain and
    /// its subdomains, so `www.figma.com` and `open.spotify.com` need one entry between
    /// them. **A list, because a share link and a canonical link are not always on the
    /// same domain** — `discord.gg` is the one people paste and `discord.com` is the one
    /// it redirects to.
    var hosts: [String] {
        switch self {
        case .linear: return ["linear.app"]
        case .figma: return ["figma.com"]
        case .notion: return ["notion.so"]
        case .slack: return ["slack.com"]
        case .teams: return ["teams.microsoft.com"]
        case .asana: return ["asana.com"]
        case .discord: return ["discord.com", "discord.gg"]
        case .zoom: return ["zoom.us"]
        case .spotify: return ["spotify.com"]
        }
    }

    /// What the toggle says it will do, in the one line there is room for.
    var blurb: String {
        switch self {
        case .linear: return "Issues, projects and views open in the Linear app."
        case .figma: return "Files and prototypes open in the Figma app."
        case .notion: return "Pages and databases open in the Notion app."
        case .slack: return "A channel or dm link opens in the Slack app."
        case .teams: return "A meeting or chat link opens in the Teams app."
        case .asana: return "Tasks, projects and portfolios open in the Asana app."
        case .discord: return "Channels and invites open in the Discord app."
        case .zoom: return "A meeting link joins in the Zoom app instead of the join page."
        case .spotify: return "Tracks, albums and playlists open in the Spotify app."
        }
    }

    private var expressions: [NSRegularExpression] {
        hosts.compactMap {
            try? NSRegularExpression(
                pattern: "^https?://([a-z0-9_-]+\\.)*\(NSRegularExpression.escapedPattern(for: $0))([/?#:]|$)",
                options: [.caseInsensitive])
        }
    }

    func matches(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return expressions.contains { $0.firstMatch(in: url, options: [], range: range) != nil }
    }

    /// The deep link for a url on this host, or nil when the app has no place for it.
    ///
    /// **Nil is a real answer, not a failure.** `zoom.us/pricing` is a web page and always
    /// was; handing it to the Zoom app would open a meeting joiner onto nothing. Returning
    /// nil sends it back down the ordinary browser path.
    ///
    /// The percent-encoded components are the ones read, not `path` and `query`: those are
    /// decoded, and re-encoding a Figma file name by hand is how a link acquires a stray
    /// space.
    func deepLink(for url: String) -> URL? {
        guard let parts = URLComponents(string: url), let host = parts.host else { return nil }
        let path = parts.percentEncodedPath
        var tail = path
        if let q = parts.percentEncodedQuery { tail += "?" + q }
        if let f = parts.percentEncodedFragment { tail += "#" + f }
        // Every shape below wants the path without its leading slash; the scheme supplies
        // the separator itself.
        let rest = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
        let segments = path.split(separator: "/").map(String.init)

        switch self {
        case .linear, .figma:
            // A plain scheme swap: the web host carries no meaning the app needs.
            guard !rest.isEmpty else { return nil }
            return URL(string: "\(rawValue)://\(rest)")
        case .notion:
            // **Notion keeps the host.** `notion://page` opens the app onto nothing; it is
            // `notion://www.notion.so/page` that resolves.
            guard !rest.isEmpty else { return nil }
            return URL(string: "notion://\(host)/\(rest)")
        case .slack:
            // **Only the `app.slack.com/client/...` form converts**, because it is the
            // only one carrying the workspace *id*. A `<name>.slack.com/archives/...`
            // link names the workspace the way a human does, and the app wants `T0…`;
            // there is nothing here to turn one into the other, so it goes to a browser
            // and Slack's own page does the handoff.
            guard host.lowercased() == "app.slack.com",
                  segments.count >= 2, segments[0].lowercased() == "client",
                  segments[1].hasPrefix("T") || segments[1].hasPrefix("E")
            else { return nil }
            let team = segments[1]
            guard segments.count >= 3 else { return URL(string: "slack://open?team=\(team)") }
            return URL(string: "slack://channel?team=\(team)&id=\(segments[2])")
        case .asana:
            // **`asanadesktop:`, not `asana:`** — the mac app and the iOS app do not share
            // a scheme, and the iOS one is the one everybody writes down. The path keeps
            // its own leading slash under an empty host, exactly as the app's own
            // `/-/desktop_app_link` page produces it.
            guard host.lowercased() == "app.asana.com", !rest.isEmpty else { return nil }
            return URL(string: "asanadesktop:///app/\(rest)")
        case .discord:
            // Discord keeps the host, like Notion. A `discord.gg` link is the short form
            // of an invite and redirects to `discord.com/invite/<code>`, so it is rewritten
            // to what it would have become rather than handed over as-is.
            if host.lowercased().hasSuffix("discord.gg") {
                guard let code = segments.first else { return nil }
                return URL(string: "discord://discord.com/invite/\(code)")
            }
            guard !rest.isEmpty else { return nil }
            return URL(string: "discord://\(host)/\(rest)")
        case .teams:
            // Teams' own deep links are the web path under `msteams:`, with one slash:
            // `msteams:/l/meetup-join/...`. Only `/l/...` is one of them; the rest of
            // teams.microsoft.com is the web client and belongs in a browser.
            guard segments.first == "l" else { return nil }
            return URL(string: "msteams:/\(rest)")
        case .zoom:
            // Only a join link converts. `/j/<id>` and `/w/<id>` are meetings; a passcode
            // rides along in `pwd` and is the difference between joining and being asked
            // for it again.
            guard segments.count >= 2, ["j", "w", "s"].contains(segments[0].lowercased()) else { return nil }
            var deep = "zoommtg://\(host)/join?confno=\(segments[1])"
            if let pwd = parts.queryItems?.first(where: { $0.name == "pwd" })?.value,
               let encoded = pwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                deep += "&pwd=" + encoded
            }
            return URL(string: deep)
        case .spotify:
            // Spotify's own uri is colon-separated, not a path: `spotify:track:<id>`. A
            // locale segment (`/intl-de/track/<id>`) is web-only and is dropped.
            var parts = segments
            if let first = parts.first, first.hasPrefix("intl-") { parts.removeFirst() }
            guard parts.count >= 2 else { return nil }
            return URL(string: "spotify:" + parts.prefix(2).joined(separator: ":"))
        }
    }
}

/// A browser, and optionally a profile inside it.
///
/// **The profile is a string, not a case.** Every browser here lets its profiles be
/// renamed, and yours already disagree with themselves — Dia's per-profile prefs call the
/// work one "Work" while AppleScript reports "All Gravy". The name the *routing* mechanism
/// answers to is the one stored, because that is the one that places the tab.
///
/// A nil profile means "wherever this browser would have put it", which is the only thing
/// Safari can be asked for and a perfectly ordinary thing to want from the others.
struct Target: Hashable {
    var browser: Browser
    var profile: String?

    init(_ browser: Browser, _ profile: String? = nil) {
        self.browser = browser
        // An empty string is a profile nobody can have, and it arrives from a text field
        // that has been cleared. Stored as nil so it cannot be looked up and missed.
        let trimmed = profile?.trimmingCharacters(in: .whitespaces)
        self.profile = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    static let dia = Target(.dia)

    /// How the target is written in rules.tsv: `chrome`, or `chrome:Work`.
    ///
    /// **Split on the first colon only**, because a profile may contain one and a browser
    /// name never does.
    var token: String { profile.map { "\(browser.rawValue):\($0)" } ?? browser.rawValue }

    /// The label the editor and the `--explain` output both use.
    var label: String { profile.map { "\(browser.label) — \($0)" } ?? browser.label }

    init?(token: String) {
        // **The two names the file used to hold.** Rules written before there was more
        // than one browser said `work` and `personal`, and those files are still on disk
        // and still hand-edited; they are read as what they always meant.
        switch token {
        case "work": self.init(.dia, "All Gravy"); return
        case "personal": self.init(.dia, "Personal"); return
        default: break
        }
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let browser = Browser(rawValue: String(parts[0]).lowercased()) else { return nil }
        self.init(browser, parts.count > 1 ? String(parts[1]) : nil)
    }
}

/// How a pattern is matched. **The order of these cases is the precedence**, most specific
/// first — see ``Rule/sortedBySpecificity(_:)``.
enum Kind: String, CaseIterable, Identifiable, Hashable {
    case regex, prefix, pathhas, host
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .host: return "a domain and its subdomains"
        case .prefix: return "a url starting with this"
        case .pathhas: return "a host, then a word anywhere in its path"
        case .regex: return "a raw regular expression"
        }
    }

    var example: String {
        switch self {
        case .host: return "example.com"
        case .prefix: return "github.com/acme"
        case .pathhas: return "linear.app:acme"
        case .regex: return #"^https?://example\.com/(a|b)"#
        }
    }
}

struct Rule: Identifiable, Hashable {
    var id = UUID()
    var target: Target
    var kind: Kind
    var pattern: String

    /// The regex this rule matches with, or nil for a `regex` rule that does not compile.
    ///
    /// **A pattern is a literal for every kind but `regex`.** Unescaped, a host rule for
    /// `example.com` also matches `exampleXcom`, which is the kind of bug nobody sees
    /// because the wrong answer is still a plausible one.
    var expression: NSRegularExpression? {
        let source: String
        switch kind {
        case .host:
            source = "^https?://([a-z0-9_-]+\\.)*\(Self.quote(pattern))([/?#:]|$)"
        case .prefix:
            source = "^https?://(www\\.)?\(Self.quote(pattern))([/?#]|$)"
        case .pathhas:
            guard let colon = pattern.firstIndex(of: ":") else { return nil }
            let host = String(pattern[pattern.startIndex..<colon])
            let needle = String(pattern[pattern.index(after: colon)...])
            guard !host.isEmpty, !needle.isEmpty else { return nil }
            source = "^https?://(www\\.)?\(Self.quote(host))/[^?#]*\(Self.quote(needle))"
        case .regex:
            source = pattern
        }
        return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    func matches(_ url: String) -> Bool {
        guard let expression else { return false }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return expression.firstMatch(in: url, options: [], range: range) != nil
    }

    /// Why this rule can never match, or nil when it can. Shown where a rule is written,
    /// so a pattern that cannot fire is refused rather than stored and puzzled over later.
    var defect: String? {
        if pattern.trimmingCharacters(in: .whitespaces).isEmpty { return "A rule needs a pattern." }
        if pattern.contains("\t") { return "A pattern cannot contain a tab." }
        switch kind {
        case .pathhas:
            guard let colon = pattern.firstIndex(of: ":"),
                  !pattern[pattern.startIndex..<colon].isEmpty,
                  !pattern[pattern.index(after: colon)...].isEmpty
            else { return "A pathhas pattern is a host and a word joined by a colon, as in linear.app:acme." }
            return nil
        case .regex:
            return expression == nil ? "That is not a valid regular expression." : nil
        default:
            return nil
        }
    }

    private static func quote(_ s: String) -> String {
        NSRegularExpression.escapedPattern(for: s)
    }

    /// **Specificity decides which rule wins, never the order rules are stored in.** A
    /// `prefix github.com/acme` beats a `host github.com` on its own, so adding a broad
    /// rule cannot shadow a narrow one that someone forgot to keep above it.
    static func sortedBySpecificity(_ rules: [Rule]) -> [Rule] {
        let rank: [Kind: Int] = [.regex: 0, .prefix: 1, .pathhas: 2, .host: 3]
        return rules.sorted {
            let a = rank[$0.kind] ?? 9, b = rank[$1.kind] ?? 9
            if a != b { return a < b }
            return $0.pattern.count > $1.pattern.count
        }
    }
}

/// The verdict for a url and the rule that produced it.
struct Decision {
    var verdict: Verdict
    var rule: Rule?

    var summary: String {
        switch verdict {
        case .app(let a): return "The \(a.label) app"
        case .target(let t): return t.label
        }
    }

    var reason: String {
        if case .app(let a) = verdict { return "\(a.rawValue) handoff" }
        guard let rule else { return "no rule matched" }
        return "\(rule.kind.rawValue) \(rule.pattern)"
    }
}

/// **Handoffs are asked first and rules are not consulted at all when one answers.** They
/// are not more specific rules, they are a different question — see ``Handoff``.
func decide(_ url: String, against rules: [Rule], handingOff apps: Set<Handoff> = [],
            fallback: Target = .dia) -> Decision {
    for app in Handoff.allCases where apps.contains(app) && app.matches(url) {
        if app.deepLink(for: url) != nil { return Decision(verdict: .app(app), rule: nil) }
    }
    for rule in Rule.sortedBySpecificity(rules) where rule.matches(url) {
        return Decision(verdict: .target(rule.target), rule: rule)
    }
    return Decision(verdict: .target(fallback), rule: nil)
}
