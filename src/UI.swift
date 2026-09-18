import SwiftUI

// **`ObservableObject`, not `@Observable`.** The macro is macOS 14 only, and the whole
// app is otherwise happy on Ventura; one property wrapper per stored field is a cheaper
// price than an OS version.
final class Model: ObservableObject {
    @Published var settings: Settings = Store.load()
    @Published var probe: String = ""

    var rules: [Rule] { settings.rules }

    var decision: Decision? {
        let u = probe.trimmingCharacters(in: .whitespaces)
        guard u.contains("://") else { return nil }
        return decide(u, against: settings.rules, handingOff: settings.apps,
                      fallback: settings.fallback)
    }

    var fallback: Target { settings.fallback }

    func setFallback(_ target: Target) {
        settings.fallback = target
        Store.save(settings)
    }

    func add(_ rule: Rule) {
        settings.rules.append(rule)
        Store.save(settings)
    }

    func remove(_ ids: Set<Rule.ID>) {
        settings.rules.removeAll { ids.contains($0.id) }
        Store.save(settings)
    }

    func hands(to app: Handoff) -> Bool { settings.apps.contains(app) }

    func setHandoff(_ app: Handoff, _ on: Bool) {
        if on { settings.apps.insert(app) } else { settings.apps.remove(app) }
        Store.save(settings)
    }
}

extension Browser {
    /// **One dot per browser, not per profile.** A profile's colour is the browser's own
    /// business and it can be changed there; what the table needs is to make "Chrome" and
    /// "Dia" distinguishable at a glance down a column, and the browser is the part of a
    /// target that is fixed.
    var tint: Color {
        switch self {
        case .dia: return Color(red: 0.90, green: 0.35, blue: 0.50)
        case .arc: return Color(red: 0.45, green: 0.40, blue: 0.85)
        case .chrome: return Color(red: 0.25, green: 0.52, blue: 0.96)
        case .brave: return Color(red: 0.98, green: 0.45, blue: 0.20)
        case .edge: return Color(red: 0.10, green: 0.65, blue: 0.75)
        case .vivaldi: return Color(red: 0.92, green: 0.24, blue: 0.28)
        case .safari: return Color(red: 0.20, green: 0.60, blue: 0.90)
        case .firefox: return Color(red: 0.95, green: 0.55, blue: 0.10)
        case .zen: return Color(red: 0.62, green: 0.55, blue: 0.95)
        }
    }
}

extension Target {
    var tint: Color { browser.tint }
}

/// The browsers a rule can point at: the installed ones, plus whatever the rule being
/// edited already names, so an uninstalled browser in an existing rule is visible rather
/// than silently swapped for another.
func selectableBrowsers(including current: Browser?) -> [Browser] {
    Browser.allCases.filter { $0.installedAt != nil || $0 == current }
}

struct RulesWindow: View {
    @StateObject private var model = Model()
    @State private var selection: Set<Rule.ID> = []
    // **One sheet slot, not one flag per sheet.** Two `.sheet` modifiers on the same view
    // only ever show one of them, and which one is not the one you asked for.
    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable {
        case welcome, add
        var id: String { rawValue }
    }

    private var ordered: [Rule] { Rule.sortedBySpecificity(model.rules) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            table
            Divider()
            handoffs
            Divider()
            fallbackRow
            Divider()
            tester
        }
        // **Sized for the longest pattern, not for the shortest.** At 560 the pattern
        // column truncates `github.com/acme-solutions`, which is the one column whose
        // whole job is to be read exactly.
        .frame(minWidth: 680, idealWidth: 720, minHeight: 720, idealHeight: 820)
        .sheet(item: $sheet) { which in
            switch which {
            case .welcome: WelcomeSheet { Setup.hasBeenOffered = true; sheet = nil }
            case .add: RuleEditor { model.add($0) }
            }
        }
        // **Offered once, and only while there is something to offer.** A window that opens
        // onto a setup panel every time is a window you stop reading.
        .onAppear {
            if !Setup.hasBeenOffered, !Setup.isComplete { sheet = .welcome }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Where a link opens")
                .font(.title3.weight(.semibold))
            // **The precedence is stated where the rules are listed.** A list read top to
            // bottom implies the first line wins, and someone would go hunting for a bug
            // when it does not.
            Text("The most specific rule wins, whatever order these are in. Anything unmatched goes to the default below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(ordered, selection: $selection) {
                TableColumn("Opens in") { rule in
                    HStack(spacing: 6) {
                        Circle().fill(rule.target.tint).frame(width: 8, height: 8)
                        Text(rule.target.label).help(rule.target.token)
                    }
                }
                .width(min: 150, ideal: 190)
                TableColumn("Match") { rule in
                    Text(rule.kind.rawValue).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
                TableColumn("Pattern") { rule in
                    Text(rule.pattern)
                        .font(.system(.body, design: .monospaced))
                        .help(rule.pattern)
                }
                .width(min: 260, ideal: 340)
            }
            // Sonoma's own striping; before it, a plain table, which is what every
            // other list on that OS looks like anyway.
            .modifier(AlternatingRows())

            HStack(spacing: 8) {
                Button { sheet = .add } label: { Image(systemName: "plus") }
                    .help("Add a rule")
                Button { model.remove(selection); selection = [] } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected rules")
                Spacer()
                // The way back to the panel once it has had its one chance, for the day
                // another browser takes the default back.
                Button("Setup") { sheet = .welcome }
                    .buttonStyle(.link)
                Button("Reveal rules.tsv") {
                    NSWorkspace.shared.activateFileViewerSelecting([Store.file])
                }
                .buttonStyle(.link)
            }
            .padding(10)
        }
    }

    /// **A checkbox, not a rule.** These sites have their own app, and which one you want
    /// is the whole question — there is no pattern to write and nothing to rank. An app
    /// that is not installed is shown anyway, greyed, so the list reads the same on every
    /// Mac and turning one on after installing it is where you would already be looking.
    private var handoffs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skip the browser").font(.callout.weight(.medium))
            Text("These links go straight to the app, before any rule above is looked at.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(Handoff.allCases) { app in
                    HandoffToggle(app: app,
                                  on: model.hands(to: app),
                                  set: { model.setHandoff(app, $0) })
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Where everything else goes, named rather than implied.** The moment this app
    /// became the default browser there stopped being a browser behind it, so an unmatched
    /// link has to be pointed somewhere explicitly or it has nowhere at all to land.
    private var fallbackRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything else").font(.callout.weight(.medium))
            Text("Where a link goes when no rule above claims it.")
                .font(.callout).foregroundStyle(.secondary)
            TargetPicker(label: "Opens in",
                         target: Binding(get: { model.fallback },
                                         set: { model.setFallback($0) }))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tester: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test a url").font(.callout.weight(.medium))
            TextField("https://", text: $model.probe)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let d = model.decision {
                HStack(spacing: 8) {
                    if case .target(let t) = d.verdict {
                        Circle().fill(t.tint).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                    Text(d.summary).fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text(d.reason).foregroundStyle(.secondary)
                        .font(.system(.callout, design: .monospaced))
                }
            } else {
                Text("Paste a url to see which profile it would open in, and which rule decides.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HandoffToggle: View {
    let app: Handoff
    let on: Bool
    let set: (Bool) -> Void

    // Read once when the row is built rather than on every redraw: it is a LaunchServices
    // lookup, and the answer does not change while a sheet is open.
    @State private var installed: Bool?

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            HStack(spacing: 5) {
                Text(app.label)
                if installed == false {
                    Text("not installed").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(installed == false)
        .help(app.blurb)
        .onAppear { if installed == nil { installed = app.installedAt != nil } }
    }
}

/// **A rule that cannot fire is refused rather than stored.** The reason sits under the
/// field as it is typed, so nobody saves a half-written `pathhas` and wonders why nothing
/// routes.
struct RuleEditor: View {
    let add: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var target = Target(.dia)
    @State private var kind: Kind = .prefix
    @State private var pattern = ""

    private var candidate: Rule { Rule(target: target, kind: kind, pattern: pattern) }
    private var defect: String? { pattern.isEmpty ? nil : candidate.defect }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a rule").font(.title3.weight(.semibold))

            TargetPicker(label: "Opens in", target: $target)

            Picker("Match", selection: $kind) {
                ForEach(Kind.allCases) { Text("\($0.rawValue) — \($0.blurb)").tag($0) }
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField(kind.example, text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let defect {
                    Text(defect).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("For example \(kind.example)")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add(candidate); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pattern.isEmpty || candidate.defect != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

final class SetupModel: ObservableObject {
    @Published var isDefault = false
    @Published var atLogin = false
    @Published var error: Setup.Refusal?
    @Published var working = false

    var isComplete: Bool { isDefault && atLogin }

    func refresh() {
        isDefault = Setup.isDefaultBrowser
        atLogin = Setup.isLoginAgentInstalled
    }

    func makeDefault() {
        working = true
        error = nil
        Setup.makeDefaultBrowser { [self] failure in
            working = false
            error = failure
            refresh()
            // **LaunchServices answers the question before it has finished changing its
            // mind.** The reading taken immediately after the dialog is dismissed is often
            // still the old handler, so it is taken again once the dust settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in refresh() }
        }
    }

    func startAtLogin() {
        working = true
        error = nil
        error = Setup.installLoginAgent().map { Setup.Refusal(message: $0, needsSystemSettings: false) }
        working = false
        refresh()
    }
}

/// **Shown once, on the first open that still needs something.** Neither step can be done
/// from a build script — one is a user decision macOS insists on asking about, the other
/// needs the path the app was actually dragged to — so they are asked for here, where the
/// answer is a click instead of a trip through System Settings.
struct WelcomeSheet: View {
    @StateObject private var setup = SetupModel()
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Two things to set up").font(.title3.weight(.semibold))
                Text("BrowserRouter only sees a link if macOS hands it one, and it only opens it instantly if it is already running.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupRow(
                done: setup.isDefault,
                title: "Make BrowserRouter the default browser",
                detail: "Every link in every app arrives here first, and leaves for the right browser and profile.",
                doneDetail: "Links come here first.",
                action: "Make default",
                busy: setup.working
            ) { setup.makeDefault() }

            SetupRow(
                done: setup.atLogin,
                title: "Start it at login",
                detail: "Keeps the router running, so the first link of the day does not wait for a cold start.",
                doneDetail: "Running now, and from every login.",
                action: "Start at login",
                busy: setup.working
            ) { setup.startAtLogin() }

            if let error = setup.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error.message).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    // **Only offered when the button cannot do it.** A link to System
                    // Settings beside a button that works is a second way to do the same
                    // thing, and the slower one.
                    if error.needsSystemSettings {
                        Button("Open System Settings") { Setup.openDefaultBrowserSettings() }
                    }
                }
            }

            HStack {
                // The first routed link raises the Automation prompt on its own, so it is
                // announced here rather than given a button that cannot exist.
                Text("The first link into each browser asks for permission to control it.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(setup.isComplete ? "Done" : "Not now") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { setup.refresh() }
        // Escape leaves the panel the same way the button does; a sheet that only closes
        // one way is a sheet that traps ⌘Q behind it.
        .onExitCommand { close() }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String
    let doneDetail: String
    let action: String
    let busy: Bool
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(done ? doneDetail : detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !done {
                Button(action, action: run).disabled(busy)
            }
        }
    }
}


/// `.alternatingRowBackgrounds()` arrived in macOS 14, and a `Table` is perfectly legible
/// without it, so it is applied where it exists and skipped where it does not.
private struct AlternatingRows: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.alternatingRowBackgrounds()
        } else {
            content
        }
    }
}


/// A browser, and a profile inside it. **One control, used in both places** — the rule
/// editor and the fallback row ask exactly the same question, and a second spelling of it
/// is a second thing to keep right.
///
/// The profile side changes shape per browser because the browsers do: a discovered list
/// where the profiles can be read, a text field where they cannot, and a sentence where
/// there is nothing to ask.
struct TargetPicker: View {
    let label: String
    @Binding var target: Target

    /// Read when the browser changes rather than on every redraw: for Chromium it is a
    /// json file, and for Dia and Arc it is an Apple event, which is not a thing to send
    /// on the way through a layout pass.
    @State private var discovered: [String] = []

    private var browser: Browser { target.browser }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(label, selection: Binding(get: { browser },
                                             set: { target = Target($0, nil) })) {
                ForEach(selectableBrowsers(including: browser)) { b in
                    HStack(spacing: 6) {
                        Circle().fill(b.tint).frame(width: 8, height: 8)
                        Text(b.installedAt == nil ? "\(b.label) (not installed)" : b.label)
                    }
                    .tag(b)
                }
            }

            if !browser.hasProfiles {
                // Said once, here, rather than left as a field that accepts a name and
                // then ignores it.
                Text("Safari gives no way to choose a profile, so links open in whichever one is in front.")
                    .font(.callout).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if discovered.isEmpty {
                // Nothing could be read — the browser has never run, or it is Dia or Arc
                // and not open right now. A name typed by hand routes exactly as well.
                TextField("\(browser.profileNoun) name, or blank for whichever is in front",
                          text: Binding(get: { target.profile ?? "" },
                                        set: { target = Target(browser, $0) }))
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker(browser.profileNoun,
                       selection: Binding(get: { target.profile ?? "" },
                                          set: { target = Target(browser, $0) })) {
                    Text("Whichever is in front").tag("")
                    ForEach(discovered, id: \.self) { Text($0).tag($0) }
                    // A rule can name a profile that has since been renamed away. Kept in
                    // the list so opening the editor does not silently repoint the rule.
                    if let current = target.profile, !discovered.contains(current) {
                        Text("\(current) (missing)").tag(current)
                    }
                }
            }
        }
        .task(id: browser) { discovered = browser.profiles }
    }
}
