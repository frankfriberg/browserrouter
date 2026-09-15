import SwiftUI

@Observable final class Model {
    var rules: [Rule] = Store.load()
    var probe: String = ""

    var decision: Decision? {
        let u = probe.trimmingCharacters(in: .whitespaces)
        guard u.contains("://") else { return nil }
        return decide(u, against: rules)
    }

    func add(_ rule: Rule) {
        rules.append(rule)
        Store.save(rules)
    }

    func remove(_ ids: Set<Rule.ID>) {
        rules.removeAll { ids.contains($0.id) }
        Store.save(rules)
    }
}

extension Profile {
    var tint: Color {
        switch self {
        case .work: return Color(red: 0.90, green: 0.35, blue: 0.50)
        case .personal: return Color.secondary
        }
    }
}

struct RulesWindow: View {
    @State private var model = Model()
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
            tester
        }
        // **Sized for the longest pattern, not for the shortest.** At 560 the pattern
        // column truncates `github.com/buttersolutions`, which is the one column whose
        // whole job is to be read exactly.
        .frame(minWidth: 680, idealWidth: 720, minHeight: 520, idealHeight: 560)
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
            Text("The most specific rule wins, whatever order these are in. Anything unmatched opens in Dia's own default profile.")
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
                        Circle().fill(rule.profile.tint).frame(width: 8, height: 8)
                        Text(rule.profile.diaProfileName)
                    }
                }
                .width(min: 110, ideal: 120)
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
            .alternatingRowBackgrounds()

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

    private var tester: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test a url").font(.callout.weight(.medium))
            TextField("https://", text: $model.probe)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let d = model.decision {
                HStack(spacing: 8) {
                    if case .profile(let p) = d.verdict {
                        Circle().fill(p.tint).frame(width: 8, height: 8)
                    } else {
                        Circle().strokeBorder(.secondary).frame(width: 8, height: 8)
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

/// **A rule that cannot fire is refused rather than stored.** The reason sits under the
/// field as it is typed, so nobody saves a half-written `pathhas` and wonders why nothing
/// routes.
struct RuleEditor: View {
    let add: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var profile: Profile = .work
    @State private var kind: Kind = .prefix
    @State private var pattern = ""

    private var candidate: Rule { Rule(profile: profile, kind: kind, pattern: pattern) }
    private var defect: String? { pattern.isEmpty ? nil : candidate.defect }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a rule").font(.title3.weight(.semibold))

            Picker("Opens in", selection: $profile) {
                ForEach(Profile.allCases) { Text($0.diaProfileName).tag($0) }
            }
            .pickerStyle(.segmented)

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

@Observable final class SetupModel {
    var isDefault = false
    var atLogin = false
    var error: String?
    var working = false

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
        error = Setup.installLoginAgent()
        working = false
        refresh()
    }
}

/// **Shown once, on the first open that still needs something.** Neither step can be done
/// from a build script — one is a user decision macOS insists on asking about, the other
/// needs the path the app was actually dragged to — so they are asked for here, where the
/// answer is a click instead of a trip through System Settings.
struct WelcomeSheet: View {
    @State private var setup = SetupModel()
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Two things to set up").font(.title3.weight(.semibold))
                Text("DiaRouter only sees a link if macOS hands it one, and it only opens it instantly if it is already running.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupRow(
                done: setup.isDefault,
                title: "Make DiaRouter the default browser",
                detail: "Every link in every app arrives here first, and leaves for the right Dia profile.",
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
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // The first routed link raises the Automation prompt on its own, so it is
                // announced here rather than given a button that cannot exist.
                Text("The first link you open will ask for permission to control Dia.")
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
