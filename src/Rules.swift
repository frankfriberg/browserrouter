import Foundation

/// Which Dia profile a url opens in. **`native` is not a profile** — it means hand the url
/// to Dia untouched, so it opens exactly where it would have with no router in the way.
enum Verdict: Equatable {
    case profile(Profile)
    case native
}

enum Profile: String, CaseIterable, Identifiable, Hashable {
    case work, personal
    var id: String { rawValue }

    /// The Dia profile's own name, which is the lookup key AppleScript uses.
    ///
    /// **Dia lets these be renamed and yours already disagree with themselves** — the
    /// per-profile prefs call the work one "Work" while AppleScript reports "All Gravy".
    /// AppleScript's name is the one that matters, because AppleScript is what places the tab.
    var diaProfileName: String {
        switch self {
        case .work: return "All Gravy"
        case .personal: return "Personal"
        }
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
        case .host: return "allgravy.com"
        case .prefix: return "github.com/buttersolutions"
        case .pathhas: return "linear.app:all-gravy"
        case .regex: return #"^https?://example\.com/(a|b)"#
        }
    }
}

struct Rule: Identifiable, Hashable {
    var id = UUID()
    var profile: Profile
    var kind: Kind
    var pattern: String

    /// The regex this rule matches with, or nil for a `regex` rule that does not compile.
    ///
    /// **A pattern is a literal for every kind but `regex`.** Unescaped, a host rule for
    /// `allgravy.com` also matches `allgravyXcom`, which is the kind of bug nobody sees
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
            else { return "A pathhas pattern is a host and a word joined by a colon, as in linear.app:all-gravy." }
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
    /// `prefix github.com/buttersolutions` beats a `host github.com` on its own, so adding a
    /// broad rule cannot shadow a narrow one that someone forgot to keep above it.
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
        case .profile(let p): return p.diaProfileName
        case .native: return "Dia's own default profile, untouched"
        }
    }

    var reason: String {
        guard let rule else { return "no rule matched" }
        return "\(rule.kind.rawValue) \(rule.pattern)"
    }
}

func decide(_ url: String, against rules: [Rule]) -> Decision {
    for rule in Rule.sortedBySpecificity(rules) where rule.matches(url) {
        return Decision(verdict: .profile(rule.profile), rule: rule)
    }
    return Decision(verdict: .native, rule: nil)
}
