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

    /// **The rules this preset adds — and they are the whole of what it knows.** There is
    /// no rewrite in Swift any more: a pattern and a template say it, and say it somewhere
    /// the user can read, copy and correct.
    ///
    /// `$1` is the first capture. That is why these are regex rules and not `host` ones:
    /// the capture is how a piece of the web url reaches the app url, and nothing simpler
    /// can carry it.
    ///
    /// **A pattern that does not match is an app that declines**, which is the whole of
    /// the old "this link has no place in the app" logic. `zoom.us/pricing` is not a
    /// meeting, does not match, and falls through to whatever rule is next — for free,
    /// rather than through a special case.
    ///
    /// Every pair below reproduces the rewrite that was measured against the app itself.
    var suggestedRules: [Rule] {
        rewrites.map { Rule(target: .app($0.template), kind: .link, pattern: $0.pattern) }
    }

    /// Ordered, because more than one can match and the narrower must be tried first — a
    /// Zoom link with a passcode has to beat the one without, or the passcode is dropped,
    /// and Spotify's locale segment has to be recognised before the form without it.
    ///
    /// Each pair reproduces a rewrite that was measured against the app itself, and each
    /// is written in the same vocabulary anyone else would use — see
    /// ``Rule/compileLink(_:)``.
    var rewrites: [(pattern: String, template: String)] {
        switch self {
        case .linear:
            return [("linear.app/{rest...}", "linear://{rest}")]
        case .figma:
            return [("figma.com/{rest...}", "figma://{rest}")]
        case .notion:
            // **Notion keeps the host.** `notion://page` opens the app onto nothing; it is
            // `notion://www.notion.so/page` that resolves.
            return [("notion.so/{rest...}", "notion://{host}/{rest}")]
        case .slack:
            // **Only the `app.slack.com/client/...` form converts**, because it is the only
            // one carrying the workspace *id*. A `<name>.slack.com/archives/...` link names
            // the workspace the way a human does and the app wants `T0…`; nothing here can
            // turn one into the other, so it goes to a browser and Slack's page hands off.
            // The channel form first: without a trailing anchor the shorter pattern would
            // match a channel url too and drop the channel.
            return [("app.slack.com/client/{team}/{channel}", "slack://channel?team={team}&id={channel}"),
                    ("app.slack.com/client/{team}", "slack://open?team={team}")]
        case .teams:
            // Only `/l/...` is a deep link; the rest of teams.microsoft.com is the web
            // client and belongs in a browser. One slash after the scheme, not two.
            return [("teams.microsoft.com/l/{rest...}", "msteams:/l/{rest}")]
        case .asana:
            // **`asanadesktop:`, not `asana:`** — the mac app and the iOS app do not share a
            // scheme, and the iOS one is the one everybody writes down. Three slashes: the
            // path keeps its own under an empty host, as Asana's own desktop_app_link page
            // produces it.
            return [("app.asana.com/{rest...}", "asanadesktop:///app/{rest}")]
        case .discord:
            // A `discord.gg` link is the short form of an invite and redirects to
            // `discord.com/invite/<code>`, so it is rewritten to what it would have become.
            return [("discord.gg/{code}", "discord://discord.com/invite/{code}"),
                    ("discord.com/{rest...}", "discord://{host}/{rest}")]
        case .zoom:
            // A passcode rides along in `pwd` and is the difference between joining and
            // being asked for it again, so that form is tried first. `/w/` and `/s/` are
            // the webinar and personal-link forms of the same thing.
            return [("zoom.us/j/{id}?pwd={pwd}", "zoommtg://{host}/join?confno={id}&pwd={pwd}"),
                    ("zoom.us/j/{id}", "zoommtg://{host}/join?confno={id}"),
                    ("zoom.us/w/{id}", "zoommtg://{host}/join?confno={id}"),
                    ("zoom.us/s/{id}", "zoommtg://{host}/join?confno={id}")]
        case .spotify:
            // Spotify's own uri is colon-separated, not a path. A locale segment is
            // web-only and is dropped, and has to be looked for first or it would be read
            // as the type.
            return [("spotify.com/intl-{locale}/{type}/{id}", "spotify:{type}:{id}"),
                    ("spotify.com/{type}/{id}", "spotify:{type}:{id}")]
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
        // **A template is shown as itself.** It is the answer to "where does this go",
        // written in the only language that says it exactly, and hiding it behind a pretty
        // name would undo the reason for having it in the file.
        case .app(let spec):
            if isTemplate { return spec }
            return (Handoff(rawValue: spec)?.label ?? spec) + " app"
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

    /// **A bare name means the plain rewrite**, kept because it is the common case and
    /// nobody should need a regex to say "Bear opens Bear links": the scheme is swapped for
    /// the name and the path is left alone. Anything with a colon or a slash in it is a
    /// template instead, and templates are expanded in ``Rule/deepLink(for:)``, which is
    /// where the captures are.
    var isTemplate: Bool {
        guard case .app(let spec) = self else { return false }
        return spec.contains(":") || spec.contains("/")
    }
}

/// How a pattern is matched. The order of these cases is how specific each kind is, most
/// specific first — see ``Rule/sortedBySpecificity(_:)``, which is now only where a rule is
/// *placed*, not which one wins.
enum Kind: String, CaseIterable, Identifiable, Hashable {
    case regex, link, prefix, pathhas, host
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .host: return "a domain and its subdomains"
        case .prefix: return "a url starting with this"
        case .pathhas: return "a host, then a word anywhere in its path"
        case .link: return "a url with {placeholders} the target reuses"
        case .regex: return "a raw regular expression"
        }
    }

    var example: String {
        switch self {
        case .host: return "example.com"
        case .prefix: return "github.com/acme"
        case .pathhas: return "linear.app:acme"
        case .link: return "zoom.us/j/{id}"
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
    /// **`{id}` compiled into a capture, and nothing more clever than that.** The nine
    /// presets used to be Swift nobody could read or correct; written as
    /// `zoom.us/j/{id}` → `zoommtg://{host}/join?confno={id}` they are two strings in a
    /// file, and the shape is obvious enough to copy for an app nobody has heard of.
    ///
    /// The vocabulary is deliberately four things:
    ///
    /// - `{name}` — one path segment.
    /// - `{name...}` — the rest of the url, slashes and all.
    /// - `{host}` — the host that matched, always available and never declared, because
    ///   several apps want their own domain back in the deep link.
    /// - `?key={name}` — a query parameter, matched wherever it actually appears rather
    ///   than where it was written, since nothing controls the order of a query string.
    ///
    /// Everything else in the pattern is a literal, escaped. There is no way to write
    /// something surprising, which is the point: ``Kind/regex`` is still there for the day
    /// this is not enough.
    static func compileLink(_ pattern: String) -> (regex: NSRegularExpression, names: [String])? {
        var body = pattern
        // A scheme is allowed but ignored; people write one out of habit and it would only
        // ever be http or https here.
        if let range = body.range(of: "://") { body = String(body[range.upperBound...]) }
        guard !body.isEmpty else { return nil }

        // The query is matched by lookahead so that ?a=1&b=2 and ?b=2&a=1 behave the same.
        let queryStart = body.firstIndex(of: "?")
        let pathPart = queryStart.map { String(body[body.startIndex..<$0]) } ?? body
        let queryPart = queryStart.map { String(body[body.index(after: $0)...]) } ?? ""

        let slash = pathPart.firstIndex(of: "/")
        let host = slash.map { String(pathPart[pathPart.startIndex..<$0]) } ?? pathPart
        let path = slash.map { String(pathPart[$0...]) } ?? ""
        guard !host.isEmpty, !host.contains("{") else { return nil }

        var names: [String] = []
        // Group 1 is always the host, so a template can ask for it without the pattern
        // having to name it.
        var source = "^https?://((?:[a-z0-9_-]+\\.)*\(NSRegularExpression.escapedPattern(for: host)))"

        func expand(_ text: String, into source: inout String) -> Bool {
            var literal = ""
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "{") {
                literal += rest[rest.startIndex..<open]
                guard let close = rest[open...].firstIndex(of: "}") else { return false }
                var name = String(rest[rest.index(after: open)..<close])
                let greedy = name.hasSuffix("...")
                if greedy { name = String(name.dropLast(3)) }
                guard !name.isEmpty, name != "host", !names.contains(name) else { return false }
                source += NSRegularExpression.escapedPattern(for: literal)
                literal = ""
                names.append(name)
                source += greedy ? "(.*)" : "([^/?#]+)"
                rest = rest[rest.index(after: close)...]
            }
            literal += rest
            source += NSRegularExpression.escapedPattern(for: literal)
            return true
        }

        guard expand(path, into: &source) else { return nil }

        for pair in queryPart.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { return nil }
            let key = NSRegularExpression.escapedPattern(for: String(halves[0]))
            let value = String(halves[1])
            if value.hasPrefix("{"), value.hasSuffix("}") {
                let name = String(value.dropFirst().dropLast())
                guard !name.isEmpty, name != "host", !names.contains(name) else { return nil }
                names.append(name)
                source += "(?=[?&]\(key)=([^&]*))"
            } else {
                source += "(?=[?&]\(key)=\(NSRegularExpression.escapedPattern(for: value))([&]|$))"
                names.append("")
            }
        }
        guard let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
        else { return nil }
        return (regex, names)
    }

    var expression: NSRegularExpression? {
        if kind == .link { return Rule.compileLink(pattern)?.regex }
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
        case .link:
            return nil // handled above
        }
        return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    func matches(_ url: String) -> Bool {
        guard let expression else { return false }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return expression.firstMatch(in: url, options: [], range: range) != nil
    }

    /// The url to hand the app, or nil when this rule cannot produce one.
    ///
    /// **Nil is a real answer, not a failure**, and with templates it is mostly free: a
    /// pattern that does not match cannot rewrite, so `zoom.us/pricing` declines by simply
    /// not being a meeting url. The link carries on down the list.
    ///
    /// **The rewrite is done on the raw url string, not on parsed components.** That is
    /// what keeps `%3A` a `%3A`: re-encoding a path that was already encoded is how a link
    /// acquires a stray space, and there is nothing here that decodes it in the first
    /// place.
    func deepLink(for url: String) -> URL? {
        guard case .app(let spec) = target else { return nil }
        guard let expression else { return nil }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        guard let match = expression.firstMatch(in: url, options: [], range: range) else { return nil }
        if kind == .link {
            guard let compiled = Rule.compileLink(pattern) else { return nil }
            func group(_ i: Int) -> String {
                let r = match.range(at: i)
                guard r.location != NSNotFound, let rr = Range(r, in: url) else { return "" }
                return String(url[rr])
            }
            var out = spec.replacingOccurrences(of: "{host}", with: group(1))
            for (i, name) in compiled.names.enumerated() where !name.isEmpty {
                out = out.replacingOccurrences(of: "{\(name)}", with: group(i + 2))
            }
            // A placeholder the pattern never bound would be left sitting in the url as
            // literal braces, which resolves to nothing. Refused instead.
            guard !out.contains("{") else { return nil }
            return URL(string: out)
        }
        if target.isTemplate {
            let rewritten = expression.replacementString(for: match, in: url, offset: 0, template: spec)
            return URL(string: rewritten)
        }
        // The plain rewrite: everything after the host, under the app's own scheme.
        guard let parts = URLComponents(string: url) else { return nil }
        var tail = parts.percentEncodedPath
        if let q = parts.percentEncodedQuery { tail += "?" + q }
        if let f = parts.percentEncodedFragment { tail += "#" + f }
        let rest = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
        guard !rest.isEmpty else { return nil }
        return URL(string: "\(spec)://\(rest)")
    }

    /// Why this rule can never match, or nil when it can. Shown where a rule is written,
    /// so a pattern that cannot fire is refused rather than stored and puzzled over later.
    var defect: String? {
        if pattern.trimmingCharacters(in: .whitespaces).isEmpty { return "A rule needs a pattern." }
        if pattern.contains("\t") { return "A pattern cannot contain a tab." }
        // **$1 can only come from a capture, and only a regex rule has any.** Under any
        // other kind the template would expand to an empty string and the link would open
        // somewhere that is not quite anywhere, which is worse than being refused.
        if target.isTemplate, case .app(let spec) = target, spec.contains("$"), kind != .regex {
            return "A rewrite using $1 needs a regex rule, because that is where the captures come from."
        }
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
        let rank: [Kind: Int] = [.regex: 0, .link: 1, .prefix: 2, .pathhas: 3, .host: 4]
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
        if case .app = rule.target, rule.deepLink(for: url) == nil { continue }
        return Decision(verdict: .target(rule.target), rule: rule, position: index + 1)
    }
    return Decision(verdict: .target(fallback), rule: nil, position: nil)
}
