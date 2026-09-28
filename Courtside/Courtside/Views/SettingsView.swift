import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ClipSettings.preRollKey) private var preRoll = ClipWindow.defaultPreRoll
    @AppStorage(ClipSettings.postRollKey) private var postRoll = ClipWindow.defaultPostRoll

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
                    Button("Restore Defaults") {
                        preRoll = ClipWindow.defaultPreRoll
                        postRoll = ClipWindow.defaultPostRoll
                    }
                }
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
}
