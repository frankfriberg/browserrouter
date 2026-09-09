import Foundation

/// The rules on disk, at ~/.dia-router/rules.tsv.
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
        .appendingPathComponent(".dia-router", isDirectory: true)
    static let file = directory.appendingPathComponent("rules.tsv")

    private static let header = """
    # Which Dia profile a url opens in. Edited by DiaRouter — open it from Spotlight.
    #
    # profile<TAB>kind<TAB>pattern
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

    static func load() -> [Rule] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let profile = Profile(rawValue: fields[0].trimmingCharacters(in: .whitespaces)),
                  let kind = Kind(rawValue: fields[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            let pattern = fields[2...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return nil }
            return Rule(profile: profile, kind: kind, pattern: pattern)
        }
    }

    @discardableResult
    static func save(_ rules: [Rule]) -> Bool {
        let body = rules.map { "\($0.profile.rawValue)\t\($0.kind.rawValue)\t\($0.pattern)" }
            .joined(separator: "\n")
        let text = header + body + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
