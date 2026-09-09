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
    @State private var adding = false

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
        .sheet(isPresented: $adding) {
            RuleEditor { model.add($0) }
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
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("Add a rule")
                Button { model.remove(selection); selection = [] } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected rules")
                Spacer()
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
