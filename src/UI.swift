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
        return decide(u, against: settings.rules, fallback: settings.fallback)
    }

    var fallback: Target { settings.fallback }

    func setFallback(_ target: Target) {
        settings.fallback = target
        Store.save(settings)
    }

    var secondClick: Bool { settings.secondClick }

    func setSecondClick(_ on: Bool) {
        settings.secondClick = on
        Store.save(settings)
    }

    var tabSwitcher: Bool { !settings.tabSwitcher.isEmpty }

    /// The browsers the panel can actually be taken over in: installed, and with tabs
    /// something can read. Firefox and Zen never appear — they have no tab scripting at
    /// all, so ⌘T there is Firefox's and stays Firefox's.
    var switchableBrowsers: [Browser] { Browser.allCases.filter(BrowserTabs.supports) }

    func switches(_ browser: Browser) -> Bool { settings.tabSwitcher.contains(browser) }

    /// One browser on or off, without disturbing the others.
    func setSwitches(_ browser: Browser, _ on: Bool) {
        if on { settings.tabSwitcher.insert(browser) } else { settings.tabSwitcher.remove(browser) }
        Store.save(settings)
        if on, !Hotkey.isTrusted { Hotkey.requestTrust() }
        switcherLive = Hotkey.install(!settings.tabSwitcher.isEmpty) && !settings.tabSwitcher.isEmpty
    }
    /// Whether the tap is actually running, which is not the same as the setting: the
    /// setting is a wish and Accessibility is the answer to it.
    @Published var switcherLive: Bool = Hotkey.isInstalled

    /// **Turning it on asks for Accessibility, once.** The grant lands after the app is
    /// restarted by System Settings or after the user flips the switch there, so a failed
    /// install is not an error — it is the state the row below describes.
    func setTabSwitcher(_ on: Bool) {
        // The checkbox is every browser that can be driven; the individual ones are then
        // turned off one at a time underneath it.
        settings.tabSwitcher = on ? Set(switchableBrowsers) : []
        Store.save(settings)
        if on, !Hotkey.isTrusted { Hotkey.requestTrust() }
        switcherLive = Hotkey.install(on) && on
    }

    /// Re-asked whenever the window comes back, because the grant is given somewhere else
    /// entirely and nothing tells the app when it arrives.
    func refreshSwitcher() {
        guard !settings.tabSwitcher.isEmpty else { switcherLive = false; return }
        switcherLive = Hotkey.install(true)
    }

    /// **Inserted by specificity, never appended.** First match wins, so appending a broad
    /// rule to the bottom would look harmless and do nothing, and appending it to the top
    /// would shadow everything narrower. Placed where it would have ranked, it is right
    /// without anyone thinking about it — and can still be dragged anywhere afterwards.
    func add(_ rule: Rule) {
        settings.rules.insert(rule, at: Rule.insertionIndex(for: rule, into: settings.rules))
        Store.save(settings)
    }

    /// A preset adds ordinary rules, and skips the ones already there — clicking Linear
    /// twice should not give you two identical lines.
    func addPreset(_ app: Handoff) {
        for rule in app.suggestedRules
        where !settings.rules.contains(where: { $0.target == rule.target && $0.pattern == rule.pattern }) {
            settings.rules.insert(rule, at: Rule.insertionIndex(for: rule, into: settings.rules))
        }
        Store.save(settings)
    }

    func has(_ app: Handoff) -> Bool {
        app.suggestedRules.allSatisfy { r in
            settings.rules.contains { $0.target == r.target && $0.pattern == r.pattern }
        }
    }

    /// **Replaced where it sits, not re-inserted.** Position is the user's decision now,
    /// and an edit is not a reason to overrule it — changing a rule's pattern must not
    /// silently move it above or below the rules it was competing with.
    func update(_ rule: Rule) {
        guard let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.rules[index] = rule
        Store.save(settings)
    }

    func rule(_ id: Rule.ID?) -> Rule? {
        settings.rules.first { $0.id == id }
    }

    func remove(_ ids: Set<Rule.ID>) {
        settings.rules.removeAll { ids.contains($0.id) }
        Store.save(settings)
    }

    /// Move the selected rules one place up or down, keeping them together and in order.
    /// **Buttons rather than dragging**: `Table` has no `onMove`, and `draggable` is macOS
    /// 13 while this app runs on 12.
    func move(_ ids: Set<Rule.ID>, by offset: Int) {
        let indices = settings.rules.indices.filter { ids.contains(settings.rules[$0].id) }
        guard !indices.isEmpty else { return }
        guard let first = indices.first, let last = indices.last else { return }
        if offset < 0 { guard first > 0 else { return } }
        if offset > 0 { guard last < settings.rules.count - 1 else { return } }
        for i in (offset < 0 ? indices : indices.reversed()) {
            settings.rules.swapAt(i, i + offset)
        }
        Store.save(settings)
    }

    func canMove(_ ids: Set<Rule.ID>, by offset: Int) -> Bool {
        let indices = settings.rules.indices.filter { ids.contains(settings.rules[$0].id) }
        guard let first = indices.first, let last = indices.last else { return false }
        return offset < 0 ? first > 0 : last < settings.rules.count - 1
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
    /// **Apps get one colour between them**, deliberately: the column's job is to say at a
    /// glance "this one does not open a browser at all", and which app it is is written
    /// beside the dot anyway.
    var tint: Color {
        switch self {
        case .browser(let b, _): return b.tint
        case .app: return Color(red: 0.35, green: 0.75, blue: 0.45)
        }
    }
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

    private enum Sheet: Identifiable {
        case welcome, add
        case edit(Rule)

        var id: String {
            switch self {
            case .welcome: return "welcome"
            case .add: return "add"
            // The rule's own id, so opening the editor on a different row while one is
            // already open replaces the sheet rather than being ignored as "same item".
            case .edit(let rule): return "edit-\(rule.id)"
            }
        }
    }

    /// The one selected rule, or nil when none or several are. Editing is a single-row
    /// operation: there is no sensible meaning to changing three patterns at once.
    private var selected: Rule? {
        guard selection.count == 1 else { return nil }
        return model.rule(selection.first)
    }

    /// **No sort anywhere.** The list is what the user arranged, and reordering it for
    /// display would mean the numbers in the tester point at rows that are not there.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // **The table takes whatever height is going.** It is the thing being edited;
            // the three sections under it are fixed-size and would otherwise squeeze it to
            // six visible rows, which is fewer rules than a real setup has.
            table.layoutPriority(1)
            Divider()
            fallbackRow
            Divider()
            tester
        }
        // **Sized for the longest pattern, not for the shortest.** At 560 the pattern
        // column truncates `github.com/acme-solutions`, which is the one column whose
        // whole job is to be read exactly.
        .frame(minWidth: 680, idealWidth: 760, minHeight: 720, idealHeight: 900)
        .sheet(item: $sheet) { which in
            switch which {
            case .welcome: WelcomeSheet { Setup.hasBeenOffered = true; sheet = nil }
            case .add: RuleEditor { model.add($0) }
            case .edit(let rule): RuleEditor(editing: rule) { model.update($0) }
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
            // **The precedence is stated where the rules are listed**, and it is now the
            // one a list read top to bottom already implies.
            Text("The first rule that matches wins, so order decides. New rules are placed narrowest first; move one up to give it priority. Anything unmatched goes to the default below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **One size for every control in the row.** A symbol's own bounds are its glyph's,
    /// so a chevron and a minus produce buttons of different heights unless the label is
    /// given a frame; this is that frame, in one place.
    private var toolbarIcon: (width: CGFloat, height: CGFloat) { (13, 11) }

    private func toolbarButton(_ symbol: String, _ help: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: toolbarIcon.width, height: toolbarIcon.height)
        }
        .disabled(!enabled)
        .help(help)
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(model.rules, selection: $selection) {
                // The position, because with an ordered list it is half of every answer —
                // and it is what `--explain` and the tester below both point back at.
                TableColumn("#") { rule in
                    Text("\((model.rules.firstIndex { $0.id == rule.id } ?? 0) + 1)")
                        .foregroundStyle(.tertiary)
                        .font(.system(.callout, design: .monospaced))
                }
                .width(min: 24, ideal: 28)
                TableColumn("Opens in") { rule in
                    HStack(spacing: 6) {
                        Circle().fill(rule.target.tint).frame(width: 8, height: 8)
                        Text(rule.target.label)
                            .font(rule.target.isTemplate
                                  ? .system(.body, design: .monospaced) : .body)
                            .help(rule.target.token)
                    }
                }
                .width(min: 180, ideal: 250)
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
                // **The presets live in here now**, rather than in a row of checkboxes
                // under the table. They were never a separate kind of thing — each one
                // adds ordinary rules to the list above — and a menu on the add button is
                // where you already are when you want one.
                Menu {
                    Button("New rule…") { sheet = .add }
                    Divider()
                    Menu("Skip the browser") {
                        ForEach(Handoff.allCases) { app in
                            Button(app.label) { model.addPreset(app) }
                                .disabled(model.has(app) || app.installedAt == nil)
                        }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: toolbarIcon.width, height: toolbarIcon.height)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a rule, or one of the presets")

                toolbarButton("minus", "Delete the selected rules", enabled: !selection.isEmpty) {
                    model.remove(selection); selection = []
                }
                toolbarButton("pencil", "Edit the selected rule", enabled: selected != nil) {
                    if let rule = selected { sheet = .edit(rule) }
                }
                toolbarButton("chevron.up", "Move up, so this rule is tried sooner",
                              enabled: model.canMove(selection, by: -1)) {
                    model.move(selection, by: -1)
                }
                toolbarButton("chevron.down", "Move down, so this rule is tried later",
                              enabled: model.canMove(selection, by: 1)) {
                    model.move(selection, by: 1)
                }
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
                                         set: { model.setFallback($0) }),
                         allowsApp: false)
            Divider().padding(.vertical, 4)
            Toggle("Clicking the same link twice opens it in a browser",
                   isOn: Binding(get: { model.secondClick },
                                 set: { model.setSecondClick($0) }))
            Text("The way past a rule that sends a link to an app, without editing the rule.")
                .font(.callout).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Toggle("⌘T searches the tabs you already have open",
                   isOn: Binding(get: { model.tabSwitcher },
                                 set: { model.setTabSwitcher($0) }))
            if model.tabSwitcher {
                // **Per browser, because ⌘T is not this app's to take everywhere.** The
                // ones that cannot be read at all — Firefox, Zen — are not listed rather
                // than listed and disabled: there is nothing to decide about them.
                HStack(spacing: 12) {
                    ForEach(model.switchableBrowsers) { browser in
                        Toggle(browser.label,
                               isOn: Binding(get: { model.switches(browser) },
                                             set: { model.setSwitches(browser, $0) }))
                    }
                }
                .padding(.leading, 20)
            }
            if model.tabSwitcher, !model.switcherLive {
                HStack(spacing: 6) {
                    Text("Needs Accessibility — BrowserRouter has to see the keystroke before Dia does.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Accessibility") {
                        Hotkey.openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                }
            } else {
                Text("Type part of a url — localhost:5100 — and pick a tab, or a verb like split or close.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .onAppear { model.refreshSwitcher() }
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
                    Circle().fill(d.target.tint).frame(width: 8, height: 8)
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

/// **A rule that cannot fire is refused rather than stored.** The reason sits under the
/// field as it is typed, so nobody saves a half-written `pathhas` and wonders why nothing
/// routes.
struct RuleEditor: View {
    /// The rule being changed, or nil when one is being written. **The same sheet either
    /// way**: the questions are identical, and a second editor that drifts from the first
    /// is how a validation rule ends up applying to new rules and not to edited ones.
    private let existing: Rule?
    private let save: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var target: Target
    @State private var kind: Kind
    @State private var pattern: String

    init(editing: Rule? = nil, save: @escaping (Rule) -> Void) {
        self.existing = editing
        self.save = save
        _target = State(initialValue: editing?.target ?? .dia)
        _kind = State(initialValue: editing?.kind ?? .prefix)
        _pattern = State(initialValue: editing?.pattern ?? "")
    }

    /// **The id is kept when editing**, because that is what the model replaces by — a new
    /// id would append a second rule and leave the old one in place.
    private var candidate: Rule {
        Rule(id: existing?.id ?? UUID(), target: target, kind: kind, pattern: pattern)
    }
    private var defect: String? { pattern.isEmpty ? nil : candidate.defect }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add a rule" : "Edit rule").font(.title3.weight(.semibold))

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
                Button(existing == nil ? "Add" : "Save") { save(candidate); dismiss() }
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


/// Where a link goes. **One control, used in three places** — the rule editor, the
/// fallback row, and nothing else has to learn the shape of a target.
///
/// Three panes, because there are three answers: a browser with a profile picked from a
/// discovered list, the same with a typed name where the list cannot be read, and an app,
/// which is just a scheme.
struct TargetPicker: View {
    let label: String
    @Binding var target: Target
    /// The fallback cannot be an app: an app that declines a link would leave it nowhere,
    /// and "nowhere" is the one answer this app must never give.
    var allowsApp: Bool = true

    /// Read when the browser changes rather than on every redraw: for Chromium it is a
    /// json file, and for Dia and Arc it is an Apple event, which is not a thing to send
    /// on the way through a layout pass.
    @State private var discovered: [String] = []

    private enum Sort: Hashable { case browser(Browser), app }

    private var sort: Sort {
        switch target {
        case .browser(let b, _): return .browser(b)
        case .app: return .app
        }
    }

    private var appName: String {
        if case .app(let name) = target { return name }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(label, selection: Binding(get: { sort }, set: { pick($0) })) {
                ForEach(selectableBrowsers(including: target.browser)) { b in
                    HStack(spacing: 6) {
                        Circle().fill(b.tint).frame(width: 8, height: 8)
                        Text(b.installedAt == nil ? "\(b.label) (not installed)" : b.label)
                    }
                    .tag(Sort.browser(b))
                }
                if allowsApp {
                    Divider()
                    HStack(spacing: 6) {
                        Circle().fill(Target.app("").tint).frame(width: 8, height: 8)
                        Text("An app, not a browser")
                    }
                    .tag(Sort.app)
                }
            }

            switch sort {
            case .app:
                // **A url scheme, typed.** Which is all an app handoff has ever been: the
                // nine with measured rewrites are shortcuts, not the boundary.
                TextField("url scheme, as in linear, spotify, bear, things",
                          text: Binding(get: { appName }, set: { target = .app($0.lowercased()) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text(hint).font(.callout).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

            case .browser(let browser):
                if !browser.hasProfiles {
                    // Said once, here, rather than left as a field that accepts a name and
                    // then ignores it.
                    Text("Safari gives no way to choose a profile, so links open in whichever one is in front.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if discovered.isEmpty {
                    // Nothing could be read — the browser has never run, or it is Dia or
                    // Arc and not open right now. A name typed by hand routes exactly as
                    // well.
                    TextField("\(browser.profileNoun) name, or blank for whichever is in front",
                              text: Binding(get: { target.profile ?? "" },
                                            set: { target = .browser(browser, $0) }))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker(browser.profileNoun,
                           selection: Binding(get: { target.profile ?? "" },
                                              set: { target = .browser(browser, $0) })) {
                        Text("Whichever is in front").tag("")
                        ForEach(discovered, id: \.self) { Text($0).tag($0) }
                        // A rule can name a profile that has since been renamed away. Kept
                        // in the list so opening the editor does not silently repoint it.
                        if let current = target.profile, !discovered.contains(current) {
                            Text("\(current) (missing)").tag(current)
                        }
                    }
                }
            }
        }
        .task(id: sort) {
            if case .browser(let b) = sort { discovered = b.profiles } else { discovered = [] }
        }
    }

    private var hint: String {
        guard !appName.isEmpty else {
            return "Any app that registers a url scheme. The link keeps its path: https://example.com/a/b becomes scheme://a/b."
        }
        if let built = Handoff(rawValue: appName) { return built.blurb }
        return "https://example.com/a/b will open as \(appName)://a/b."
    }

    private func pick(_ sort: Sort) {
        switch sort {
        case .browser(let b): target = .browser(b, nil)
        case .app: target = .app(appName)
        }
    }
}
