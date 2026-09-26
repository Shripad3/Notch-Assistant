import NotchAssistantCore
import SwiftUI

/// Routines: a phrase ("I'm home") that runs several steps.
struct RoutinesPane: View {
    @State private var routines = Routines.all
    @State private var editing: Routine?

    var body: some View {
        Form {
            Section {
                if routines.isEmpty {
                    Text("No routines yet. Add one, or start from an example.")
                        .foregroundStyle(.secondary)
                }
                ForEach($routines) { $routine in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name.isEmpty ? "Untitled" : routine.name)
                            Text(Self.subtitle(routine))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editing = routine }
                        Toggle("", isOn: $routine.enabled).labelsHidden()
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { routines.removeAll { $0.id == routine.id } }
                    }
                }
            } header: {
                Text("Routines")
            } footer: {
                Text("Say a routine's phrase after “Alfred”, e.g. “Alfred, I'm home”. Steps run in order; if one fails, the rest still run. Lights and other Home scenes run through a shortcut you make in the Shortcuts app.")
            }
            Section {
                HStack {
                    Button("New Routine") {
                        editing = Routine(name: "", triggers: [""], steps: [])
                    }
                    Menu("Add Example") {
                        ForEach(Routines.examples, id: \.name) { example in
                            Button(example.name) {
                                var copy = example
                                copy.id = UUID()
                                copy.steps = copy.steps.map { RoutineStep($0.kind, text: $0.text, percent: $0.percent) }
                                editing = copy
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: routines) { Routines.all = routines }
        .sheet(item: $editing) { routine in
            RoutineEditor(routine: routine, others: routines.filter { $0.id != routine.id }) { saved in
                if let index = routines.firstIndex(where: { $0.id == saved.id }) {
                    routines[index] = saved
                } else {
                    routines.append(saved)
                }
                editing = nil
            } onDelete: {
                routines.removeAll { $0.id == routine.id }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    static func subtitle(_ routine: Routine) -> String {
        let phrases = routine.triggers.filter { !$0.isEmpty }.map { "“\($0)”" }.joined(separator: ", ")
        let steps = routine.steps.count == 1 ? "1 step" : "\(routine.steps.count) steps"
        return [phrases, steps].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct RoutineEditor: View {
    @State var routine: Routine
    let others: [Routine]
    let onSave: (Routine) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var triggerText = ""

    init(routine: Routine, others: [Routine], onSave: @escaping (Routine) -> Void, onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        _triggerText = State(initialValue: routine.triggers.filter { !$0.isEmpty }.joined(separator: "\n"))
        self.others = others
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    private var triggers: [String] {
        triggerText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A phrase another routine already uses would make one of them unreachable.
    private var clash: String? {
        for trigger in triggers {
            if let other = others.first(where: { Routines.match(trigger, in: [$0]) != nil }) {
                return "“\(trigger)” already starts “\(other.name)”"
            }
        }
        return nil
    }

    private var problem: String? {
        if routine.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name" }
        if triggers.isEmpty { return "Add at least one phrase" }
        if routine.steps.isEmpty { return "Add at least one step" }
        if let step = routine.steps.first(where: { $0.kind.textLabel != nil && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "“\(step.kind.title)” needs a \(step.kind.textLabel!.lowercased())"
        }
        return clash
    }

    private func move(_ id: RoutineStep.ID, by offset: Int) {
        guard let index = routine.steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard routine.steps.indices.contains(target) else { return }
        withAnimation { routine.steps.swapAt(index, target) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Routine") {
                    TextField("Name", text: $routine.name, prompt: Text("I'm home"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Phrases, one per line")
                        TextEditor(text: $triggerText)
                            .font(.body)
                            .frame(height: 60)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    }
                    TextField("Then say", text: $routine.response, prompt: Text("Welcome home (optional)"))
                }
                Section {
                    ForEach($routine.steps) { $step in
                        let index = routine.steps.firstIndex { $0.id == step.id } ?? 0
                        StepRow(
                            number: index + 1,
                            step: $step,
                            canMoveUp: index > 0,
                            canMoveDown: index < routine.steps.count - 1,
                            onMove: { offset in move(step.id, by: offset) },
                            onRemove: { routine.steps.removeAll { $0.id == step.id } }
                        )
                    }
                    Menu("Add Step") {
                        ForEach(RoutineStep.Kind.allCases, id: \.self) { kind in
                            Button(kind.title) { routine.steps.append(RoutineStep(kind)) }
                        }
                    }
                    .fixedSize()
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Steps run top to bottom; use the arrows to reorder. “Run shortcut” runs a shortcut from the Shortcuts app by name, e.g. one that turns on your lights.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if Routines.all.contains(where: { $0.id == routine.id }) {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = routine
                    saved.triggers = triggers
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(12)
        }
        .frame(width: 480, height: 540)
    }
}

private struct StepRow: View {
    let number: Int
    @Binding var step: RoutineStep
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Picker("", selection: $step.kind) {
                ForEach(RoutineStep.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if let label = step.kind.textLabel {
                TextField("", text: $step.text, prompt: Text(label))
                    .labelsHidden()
            } else if step.kind.takesPercent {
                Slider(value: Binding(get: { Double(step.percent) }, set: { step.percent = Int($0) }), in: 0...100, step: 5)
                Text("\(step.percent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
            } else {
                Spacer()
            }
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up")
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down")
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove step")
        }
    }
}
