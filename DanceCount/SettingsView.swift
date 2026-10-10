import SwiftUI

struct SettingsView: View {
    @Bindable var model: CountModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Listen with", selection: $model.settings.mic) {
                        ForEach(MicSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Microphone")
                } footer: {
                    Text(model.settings.mic == .airPods
                         ? "Uses the AirPods microphones, which hear the room clearly. On older iOS versions this can lower the playback quality of the counts."
                         : "Uses the iPhone microphone. Works from a pocket, but fabric muffles the music — a shirt or jacket pocket is better than jeans.")
                }

                let style = model.settings.style
                if style.patterns.count > 1 {
                    Section {
                        Picker("Call", selection: Binding(
                            get: { model.settings.pattern(for: style).id },
                            set: { model.settings.patternIDs[style.rawValue] = $0 }
                        )) {
                            ForEach(style.patterns) { Text($0.label).tag($0.id) }
                        }
                    } header: {
                        Text(style.name)
                    } footer: {
                        Text("Step calls start from the 1 — tap “That was 1” or squeeze your AirPods where your pattern starts.")
                    }
                }

                Section("Counts") {
                    Picker("Sound", selection: $model.settings.sound) {
                        ForEach(CountSound.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Say", selection: $model.settings.density) {
                        ForEach(CountDensity.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $model.settings.volume, in: 0.05...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Text("Earlier")
                        Slider(value: $model.settings.timingOffsetMs, in: -250...250, step: 10)
                        Text("Later")
                    }
                    .font(.footnote)
                    HStack {
                        Text("Timing offset")
                        Spacer()
                        Text("\(Int(model.settings.timingOffsetMs)) ms").monospacedDigit().foregroundStyle(.secondary)
                    }
                    if model.settings.timingOffsetMs != 0 {
                        Button("Reset to 0") { model.settings.timingOffsetMs = 0 }
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    Text("If the counts land consistently before or after the beat, move this until they sit right on it. Bluetooth delay is compensated automatically, but not every headphone reports it exactly.")
                }

                Section {
                    LabeledContent("Squeeze once", value: "That was 1")
                    LabeledContent("Squeeze twice", value: "New song")
                    LabeledContent("Squeeze three times", value: "Move half a beat")
                } header: {
                    Text("AirPods controls")
                } footer: {
                    Text("Squeeze the stem right on the 1. Counting keeps going with the screen locked.")
                }

                Section {
                    Button("Save the last minute of audio", action: model.saveClip)
                        .disabled(!model.status.running)
                    if let message = model.clipMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let url = model.lastClip {
                        ShareLink(item: url) { Label("Share clip", systemImage: "square.and.arrow.up") }
                    }
                } header: {
                    Text("Song it got wrong?")
                } footer: {
                    Text("Saves what the microphone heard so the beat tracker can be improved on real music. Clips are in the Files app under Dance Count › Clips.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
