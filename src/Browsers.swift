import AppKit
import Foundation

/// A browser a link can be sent to, and the one thing that differs between them: how you
/// name a profile.
///
/// **There are five mechanisms here and no fewer.** Each browser family invented its own,
/// none of them talk to each other, and the differences are not cosmetic — they decide
/// whether a profile can be targeted at all, whether its name can be discovered, and
/// whether an already-open tab can be found. Everything below is keyed off that, so adding
/// a browser is picking a mechanism rather than writing a new router — except that Dia
/// and Arc, from the same company and with the same idea, needed one each.
enum Browser: String, CaseIterable, Identifiable, Hashable {
    case dia, arc, chrome, brave, edge, vivaldi, safari, firefox, zen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dia: return "Dia"
        case .arc: return "Arc"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .vivaldi: return "Vivaldi"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .zen: return "Zen"
        }
    }

    /// The name AppleScript uses, which is the *application* name and not always the label.
    var scriptingName: String {
        switch self {
        case .dia: return "Dia"
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave Browser"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .zen: return "Zen"
        }
    }

    /// **A list, because a browser can ship under more than one identifier** — the same
    /// reason ``Handoff/bundleIDs`` is one. Beta and developer channels are deliberately
    /// absent: they are a different browser with the same name, and a rule pointing at one
    /// when you meant the other is worse than a rule that does not resolve.
    var bundleIDs: [String] {
        switch self {
        case .dia: return ["company.thebrowser.dia"]
        case .arc: return ["company.thebrowser.Browser"]
        case .chrome: return ["com.google.Chrome"]
        case .brave: return ["com.brave.Browser"]
        case .edge: return ["com.microsoft.edgemac"]
        case .vivaldi: return ["com.vivaldi.Vivaldi"]
        case .safari: return ["com.apple.Safari"]
        case .firefox: return ["org.mozilla.firefox"]
        case .zen: return ["app.zen-browser.zen"]
        }
    }

    var installedAt: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// How this browser lets a profile be named, and what that costs.
    enum Mechanism {
        /// Dia's: profiles are scriptable objects inside a window, a tab can be made
        /// directly in one, and both are addressable by name.
        case dia
        /// **Arc's, which is Dia's with every detail different.** Same company, same idea,
        /// and not one line of the script survives the move: a space is named `title`, not
        /// `name`; `whose title is` cannot filter it; `make new tab at end of tabs of
        /// <space>` reports success and creates nothing; a tab answers `select`, not
        /// `focus`. What does work is to focus the space and make the tab on the *window*.
        case arc
        /// Chromium's: a command-line flag naming a *directory*, and a dictionary that has
        /// never heard of profiles. See ``ChromiumProfiles``.
        case chromium(support: String)
        /// Firefox's, and Zen's, which is a Firefox: `-P <name>` on the real binary, and
        /// no scripting worth the name — both ship the boilerplate Cocoa suite with no tab
        /// class in it, so nothing inside the browser can be seen or reused.
        case gecko(support: String, executable: String)
        /// Safari's: none. It has had profiles since Sonoma and exposes them to nothing —
        /// not the command line, not AppleScript. Links go to whichever profile is in
        /// front, which is Safari's own answer and not one this app can improve on.
        case none
    }

    var mechanism: Mechanism {
        switch self {
        case .dia: return .dia
        case .arc: return .arc
        case .chrome: return .chromium(support: "Google/Chrome")
        case .brave: return .chromium(support: "BraveSoftware/Brave-Browser")
        case .edge: return .chromium(support: "Microsoft Edge")
        case .vivaldi: return .chromium(support: "Vivaldi")
        case .firefox: return .gecko(support: "Firefox", executable: "firefox")
        case .zen: return .gecko(support: "zen", executable: "zen")
        case .safari: return .none
        }
    }

    /// Whether naming a profile means anything for this browser. A rule that names one
    /// where it does not is not refused — it is stored and ignored, which is a worse
    /// silence than saying so in the editor.
    var hasProfiles: Bool {
        if case .none = mechanism { return false }
        return true
    }

    /// Whether an already-open tab showing this url can be found and focused. Only
    /// AppleScript can answer that, so the Firefox family — which has none — always opens
    /// a new tab.
    var canFocusExistingTab: Bool {
        if case .gecko = mechanism { return false }
        return true
    }

    /// What the profile is called in this browser's own words, for the editor's label.
    var profileNoun: String {
        if case .arc = mechanism { return "Space" }
        return "Profile"
    }

    /// The profiles this browser has right now, in the order it lists them.
    ///
    /// **Discovery is best-effort and an empty answer is normal**, not an error: a
    /// Chromium browser that has never run has no `Local State`, and a scripted one has to
    /// be running and have granted Automation before it will say. The editor falls back to
    /// a plain text field, because a name typed by hand routes exactly as well as one
    /// picked from a list.
    var profiles: [String] {
        switch mechanism {
        case .dia: return scriptedProfiles(collection: "profiles", property: "name")
        // **`title`, not `name`.** Asking Arc for the name of a space fails to coerce and
        // takes the whole script with it — the error even says "name", which is what made
        // it look like Dia's dictionary with one word changed.
        case .arc: return scriptedProfiles(collection: "spaces", property: "title")
        case .chromium(let support): return ChromiumProfiles.load(support).map(\.name)
        case .gecko(let support, _): return GeckoProfiles.load(support)
        case .none: return []
        }
    }

    private func scriptedProfiles(collection: String, property: String) -> [String] {
        // Asked of every window and deduped, because a profile is a property of a window
        // here: one open in the second window and not the first still exists.
        //
        // **`get <property> of every <collection>`, never a property read per item.** The
        // per-item form builds a reference into a reference and answers -1700 for the
        // whole script — in Dia for the tab urls, in Arc for everything including a
        // space's own id.
        let source = """
        tell application "\(scriptingName)"
            if (count of windows) is 0 then return ""
            set out to ""
            repeat with wi from 1 to (count of windows)
                repeat with n in (get \(property) of every \(collection) of window wi)
                    try
                        set out to out & (n as text) & linefeed
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue else { return [] }
        var seen = Set<String>()
        return text.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
    }
}

/// Chromium's profile list, which is a json file rather than anything the browser will
/// tell you.
///
/// **The name on screen and the name on disk are different strings**, and the flag wants
/// the one on disk. `--profile-directory` takes `Profile 4`; the profile picker calls that
/// same profile `allgravy.com`. Nobody would write `Profile 4` in a rule, so the mapping is
/// read from `Local State` and the rule stores the readable one.
enum ChromiumProfiles {
    struct Entry { let directory: String; let name: String }

    static func load(_ support: String) -> [Entry] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(support, isDirectory: true)
            .appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }
        return cache.keys.sorted { lhs, rhs in
            // `Default` first, then `Profile 2`, `Profile 10` — numerically, so the list
            // does not read `Profile 10, Profile 2`.
            if lhs == "Default" || rhs == "Default" { return lhs == "Default" }
            return lhs.compare(rhs, options: .numeric) == .orderedAscending
        }.map { key in
            let name = (cache[key] as? [String: Any])?["name"] as? String
            return Entry(directory: key, name: name ?? key)
        }
    }

    /// The directory for a profile named on screen, or nil when no profile has that name.
    ///
    /// **Nil has to reach the caller rather than become `Default`.** A renamed profile
    /// would otherwise send every work link to the personal one silently, which is the
    /// exact failure the rule was written to prevent.
    static func directory(_ support: String, named name: String) -> String? {
        let all = load(support)
        if let exact = all.first(where: { $0.name == name }) { return exact.directory }
        if let insensitive = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return insensitive.directory
        }
        // A directory name written in by hand still works, for the file edited by someone
        // who read Chromium's own documentation rather than this app's.
        return all.first(where: { $0.directory == name })?.directory
    }
}

/// The Firefox family's profile list, which is an ini file. Zen is a Firefox fork and
/// keeps its own under `zen/`, in the same format.
enum GeckoProfiles {
    static func load(_ support: String) -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(support, isDirectory: true)
            .appendingPathComponent("profiles.ini")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Name=") else { return nil }
            return String(trimmed.dropFirst("Name=".count))
        }
    }
}
