import Foundation

/// Where a url ends up. **`app` means it never reaches a browser at all**; everything
/// else is a browser and, where the browser has them, a profile inside it.
///
/// There is no `native` case any more. Once this app is the system default browser there
/// is no browser behind it to fall through to, so "nothing matched" is a ``Target`` like
/// any other — the one in ``Settings/fallback`` — and it is chosen rather than implied.
enum Verdict: Equatable {
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

    /// **The rules this preset adds, which are ordinary rules and nothing else.** They used
    /// to be a checkbox, and a checkbox says the list of apps is the whole world; a rule in
    /// the table says "this is the shape, write another one". `app:things host
    /// culturedcode.com` is a sentence anyone can copy once they have seen this.
    var suggestedRules: [Rule] {
        hosts.map { Rule(target: .app(rawValue), kind: .host, pattern: $0) }
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

/// Where a link ends up: a browser, or an app that is not a browser.
///
/// **The profile is a string, not a case.** Every browser here lets its profiles be
/// renamed, and yours already disagree with themselves — Dia's per-profile prefs call the
/// work one "Work" while AppleScript reports "All Gravy". The name the *routing* mechanism
/// answers to is the one stored, because that is the one that places the tab.
///
/// A nil profile means "wherever this browser would have put it", which is the only thing
/// Safari can be asked for and a perfectly ordinary thing to want from the others.
///
/// **`app` is a name, not a case**, and that is the whole point of it. A name this build
/// knows — `linear`, `zoom`, `spotify` — gets the rewrite that was measured against that
/// app. A name it has never heard of gets the plain one: the scheme swapped for the name
/// and the path left alone, which is what Linear and Figma turn out to need anyway. So
/// `app:bear` routes without anyone having taught this app about Bear.
enum Target: Hashable {
    case browser(Browser, profile: String?)
    case app(String)

    static let dia = Target.browser(.dia, profile: nil)

    static func browser(_ b: Browser, _ profile: String?) -> Target {
        // An empty string is a profile nobody can have, and it arrives from a text field
        // that has been cleared. Stored as nil so it cannot be looked up and missed.
        let trimmed = profile?.trimmingCharacters(in: .whitespaces)
        return .browser(b, profile: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    /// The browser this points at, or nil when it points at an app.
    var browser: Browser? {
        if case .browser(let b, _) = self { return b }
        return nil
    }

    var profile: String? {
        if case .browser(_, let p) = self { return p }
        return nil
    }

    /// The built-in this name refers to, or nil for one written by hand. **Nil is not a
    /// failure** — it is the ordinary case for any app nobody has measured.
    var handoff: Handoff? {
        if case .app(let name) = self { return Handoff(rawValue: name) }
        return nil
    }

    /// How the target is written in rules.tsv: `chrome`, `chrome:Work`, or `app:linear`.
    ///
    /// **Split on the first colon only**, because a profile may contain one and neither a
    /// browser name nor `app` ever does.
    var token: String {
        switch self {
        case .browser(let b, let p): return p.map { "\(b.rawValue):\($0)" } ?? b.rawValue
        case .app(let name): return "app:\(name)"
        }
    }

    /// The label the editor and the `--explain` output both use.
    var label: String {
        switch self {
        case .browser(let b, let p): return p.map { "\(b.label) — \($0)" } ?? b.label
        case .app(let name): return (Handoff(rawValue: name)?.label ?? name.capitalized) + " app"
        }
    }

    init?(token: String) {
        // **The two names the file used to hold.** Rules written before there was more
        // than one browser said `work` and `personal`, and those files are still on disk
        // and still hand-edited; they are read as what they always meant.
        switch token {
        case "work": self = .browser(.dia, "All Gravy"); return
        case "personal": self = .browser(.dia, "Personal"); return
        default: break
        }
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0]).lowercased()
        let tail = parts.count > 1 ? String(parts[1]) : nil
        if head == "app" {
            guard let name = tail?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            self = .app(name.lowercased())
            return
        }
        guard let browser = Browser(rawValue: head) else { return nil }
        self = .browser(browser, tail)
    }

    /// The url to hand the app, or nil when this app has no place for it.
    ///
    /// **Nil is a real answer, not a failure.** `zoom.us/pricing` is a web page and always
    /// was; handing it to the Zoom app would open a meeting joiner onto nothing. Returning
    /// nil is what sends the link back down the list to whatever rule matches next.
    func deepLink(for url: String) -> URL? {
        guard case .app(let name) = self else { return nil }
        if let built = Handoff(rawValue: name) { return built.deepLink(for: url) }
        // The plain rewrite: keep everything after the host, swap the scheme for the name.
        // Deliberately the same shape as Linear's and Figma's, which is the one that turns
        // out to be right whenever an app has not invented something of its own.
        guard let parts = URLComponents(string: url) else { return nil }
        var tail = parts.percentEncodedPath
        if let q = parts.percentEncodedQuery { tail += "?" + q }
        if let f = parts.percentEncodedFragment { tail += "#" + f }
        let rest = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
        guard !rest.isEmpty else { return nil }
        return URL(string: "\(name)://\(rest)")
    }
}

/// How a pattern is matched. The order of these cases is how specific each kind is, most
/// specific first — see ``Rule/sortedBySpecificity(_:)``, which is now only where a rule is
/// *placed*, not which one wins.
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

    /// How specific a rule is: a smaller number is narrower. Not a ranking any more — it
    /// decides where a new rule is *inserted*, which is a suggestion the user can drag
    /// away from.
    var specificity: (Int, Int) {
        let rank: [Kind: Int] = [.regex: 0, .prefix: 1, .pathhas: 2, .host: 3]
        return (rank[kind] ?? 9, -pattern.count)
    }

    /// **The list is ordered and the first match wins, so this is not what decides.** It is
    /// how an existing file is seeded and where a new rule lands, which between them mean
    /// the naive case is still correct without anyone thinking about order: a broad rule
    /// added later goes *below* the narrow one it would otherwise have shadowed.
    static func sortedBySpecificity(_ rules: [Rule]) -> [Rule] {
        rules.sorted { $0.specificity < $1.specificity }
    }

    /// Where a new rule belongs in a list that is otherwise in specificity order.
    static func insertionIndex(for rule: Rule, into rules: [Rule]) -> Int {
        rules.firstIndex { rule.specificity < $0.specificity } ?? rules.count
    }
}

/// The verdict for a url and the rule that produced it.
struct Decision {
    var verdict: Verdict
    var rule: Rule?
    /// Which line decided, counting from 1, or nil when nothing matched. **Shown, because
    /// with an ordered list the position is half the answer** — a rule that loses does so
    /// for a reason you can point at.
    var position: Int?

    var summary: String { target.label }

    var target: Target {
        if case .target(let t) = verdict { return t }
        return .dia
    }

    var reason: String {
        guard let rule else { return "no rule matched" }
        let where_ = position.map { "#\($0) " } ?? ""
        return "\(where_)\(rule.kind.rawValue) \(rule.pattern)"
    }
}

/// **The first rule that matches wins, and the list is in the order the user put it in.**
/// That is the model everyone already knows from firewall and routing tables, and it is
/// the only one in which "open Linear links in the Linear app, except the ones for this
/// team" can be said at all. The cost is that a broad rule placed above a narrow one
/// shadows it, which is why nothing ever *appends*: see ``Rule/insertionIndex(for:into:)``.
///
/// **A rule pointing at an app can decline.** `zoom.us/pricing` is a web page, and the Zoom
/// app has nowhere to put it; that rule is skipped and the search carries on down the list
/// rather than the link being handed somewhere it cannot open.
func decide(_ url: String, against rules: [Rule], fallback: Target = .dia) -> Decision {
    for (index, rule) in rules.enumerated() where rule.matches(url) {
        if case .app = rule.target, rule.target.deepLink(for: url) == nil { continue }
        return Decision(verdict: .target(rule.target), rule: rule, position: index + 1)
    }
    return Decision(verdict: .target(fallback), rule: nil, position: nil)
}
