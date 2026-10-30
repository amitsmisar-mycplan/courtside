import SwiftData
import SwiftUI

/// Edits a game's details. Every field is optional; Save writes them all at once.
struct GameInfoEditor: View {
    let game: Game
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var opponent: String
    @State private var name: String
    @State private var date: Date
    @State private var ourScore: String
    @State private var theirScore: String
    @State private var notes: String
    @FocusState private var focus: Field?

    private enum Field { case opponent, ourScore, theirScore }

    init(game: Game, modelContext: ModelContext) {
        self.game = game
        self.modelContext = modelContext
        _opponent = State(initialValue: game.opponent ?? "")
        _name = State(initialValue: game.label)
        _date = State(initialValue: game.recordedAt)
        _ourScore = State(initialValue: game.ourScore.map(String.init) ?? "")
        _theirScore = State(initialValue: game.theirScore.map(String.init) ?? "")
        _notes = State(initialValue: game.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Opponent", text: $opponent)
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .opponent)
                        .submitLabel(.next)
                        .onSubmit { focus = .ourScore }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Score") {
                    HStack(spacing: 12) {
                        scoreField("Us", text: $ourScore, field: .ourScore)
                        Text("–").foregroundStyle(.secondary)
                        scoreField("Them", text: $theirScore, field: .theirScore)
                    }
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    TextField("Name", text: $name)
                } footer: {
                    Text("Optional. Shown when there's no opponent.")
                }
            }
            .navigationTitle("Game Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .onAppear {
                // Straight to typing when the opponent is the missing piece.
                if game.opponent == nil { focus = .opponent }
            }
        }
    }

    private func scoreField(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField(title, text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.title2.weight(.semibold).monospacedDigit())
            .focused($focus, equals: field)
            .onChange(of: text.wrappedValue) { _, value in
                // Digits only, at most three.
                let digits = String(value.filter(\.isNumber).prefix(3))
                if digits != value { text.wrappedValue = digits }
            }
    }

    private func save() {
        game.opponent = opponent.trimmed.isEmpty ? nil : opponent.trimmed
        game.label = name.trimmed
        // The picker changes only the day, so the time of day is kept.
        game.recordedAt = date
        game.ourScore = Int(ourScore)
        game.theirScore = Int(theirScore)
        game.notes = notes.trimmed.isEmpty ? nil : notes.trimmed
        try? modelContext.save()
        dismiss()
    }
}
