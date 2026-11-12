import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ClipSettings.preRollKey) private var preRoll = ClipWindow.defaultPreRoll
    @AppStorage(ClipSettings.postRollKey) private var postRoll = ClipWindow.defaultPostRoll
    @AppStorage(ClipSettings.qualityKey) private var clipQuality = ClipQuality.hd1080
    @AppStorage(LabelSettings.myTeamKey) private var myTeam = ""
    @AppStorage(LabelSettings.exportLabelKey) private var exportLabel = ExportLabelMode.openAndClose
    @AppStorage(LabelSettings.labelledQualityKey) private var labelledQuality = LabelledExportQuality.hd1080
    @AppStorage(PlayerSettings.myPlayerKey) private var myPlayerRaw = ""
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Player.name) private var players: [Player]
    @State private var addingPlayer = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $preRoll, in: ClipWindow.preRollRange, step: 1) {
                        LabeledContent("Before tap", value: "\(Int(preRoll)) sec")
                    }
                    Stepper(value: $postRoll, in: ClipWindow.postRollRange, step: 1) {
                        LabeledContent("After tap", value: "\(Int(postRoll)) sec")
                    }
                } header: {
                    Text("Clip length")
                } footer: {
                    Text("You tap after the play happens, so most of each clip comes from before the tap. Changes apply to clips made from now on.")
                }
                Section {
                    Picker("Clip quality", selection: $clipQuality) {
                        ForEach(ClipQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                } footer: {
                    Text("For new clips and trims. 1080p is several times faster to make from 4K game videos. Clips you already have stay as they are.")
                }
                Section {
                    TextField("My team", text: $myTeam)
                        .textInputAutocapitalization(.words)
                    Picker("Label on exported clips", selection: $exportLabel) {
                        ForEach(ExportLabelMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("Labelled clip quality", selection: $labelledQuality) {
                        ForEach(LabelledExportQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .disabled(exportLabel == .off)
                } header: {
                    Text("Game labels")
                } footer: {
                    Text("New games start with your team; change it on any game. Saved and shared clips show the team, opponent, tournament and date for a few seconds at the start and end. Never the score. Adding a label re-makes the video: 1080p is several times faster than full quality for 4K clips.")
                }
                playersSection
                Section {
                    Button("Restore Defaults") {
                        preRoll = ClipWindow.defaultPreRoll
                        postRoll = ClipWindow.defaultPostRoll
                    }
                }
            }
            .addPlayerAlert(isPresented: $addingPlayer) { name, number in
                Player.add(name: name, number: number, in: modelContext)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Player tags (decision 0030): My Player, then each player to edit or delete.
    private var playersSection: some View {
        Section {
            Picker("My Player", selection: $myPlayerRaw) {
                Text("None").tag("")
                ForEach(players) { player in
                    Text(player.fullLabel).tag(player.id.uuidString)
                }
            }
            ForEach(players) { player in
                NavigationLink {
                    PlayerEditor(player: player)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(player.color.color)
                            .frame(width: 12, height: 12)
                        Text(player.fullLabel)
                        Spacer()
                        Text(player.clips.count == 1 ? "1 clip" : "\(player.clips.count) clips")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Button("Add Player", systemImage: "plus") { addingPlayer = true }
        } header: {
            Text("Players")
        } footer: {
            Text("Tag clips with who's in them, then filter a game's clips to My Player. Names and numbers stay on this phone; they aren't added to saved or shared videos.")
        }
    }
}
