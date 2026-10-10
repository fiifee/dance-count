import BeatKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: CountModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 18) {
            header
            Spacer(minLength: 0)
            CountDisplay(call: model.status.locked ? model.call : nil)
            oneHint
            Spacer(minLength: 0)
            if model.status.running {
                corrections
            }
            startButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-settings") { showSettings = true } }
        #endif
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .alert("Can't listen", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.stop() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    Picker("Dance", selection: $model.settings.style) {
                        ForEach(DanceStyle.Family.allCases, id: \.self) { family in
                            Section(family.rawValue) {
                                ForEach(DanceStyle.allCases.filter { $0.family == family }) { Text($0.name).tag($0) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.settings.style.name).font(.title2.bold())
                        Image(systemName: "chevron.down").font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.subheadline.monospacedDigit())
                Spacer()
                if model.status.running {
                    LevelMeter(level: model.status.inputLevel)
                    Text(model.status.micName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard model.status.running else { return "Stopped" }
        guard model.status.locked, let bpm = model.status.bpm else { return "Listening for the beat…" }
        return String(format: "%.0f BPM", bpm)
    }

    private var statusColor: Color {
        guard model.status.running else { return .gray }
        return model.status.locked ? .green : .orange
    }

    @ViewBuilder private var oneHint: some View {
        if model.status.running && model.status.locked {
            Text(model.status.oneIsManual ? "1 set by you" : "Guessing the 1 — tap below when you hear it")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(" ").font(.footnote)
        }
    }

    private var corrections: some View {
        VStack(spacing: 10) {
            Button(action: model.markOneFromScreen) {
                Text("That was 1")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(!model.status.locked)

            HStack(spacing: 10) {
                SmallButton(title: "−1", subtitle: "count") { model.shiftCount(-1) }
                SmallButton(title: "+1", subtitle: "count") { model.shiftCount(1) }
                SmallButton(title: "½", subtitle: "on the &", active: model.status.offBeat) { model.flipHalfBeat() }
            }
            .disabled(!model.status.locked)
            HStack(spacing: 10) {
                SmallButton(title: "÷2", subtitle: "slower", active: model.status.tempoFactor < 1) { model.slower() }
                SmallButton(title: "×2", subtitle: "faster", active: model.status.tempoFactor > 1) { model.faster() }
                SmallButton(title: "New", subtitle: "song") { model.relisten() }
            }
        }
    }

    private var startButton: some View {
        Button(action: model.toggle) {
            Label(model.status.running ? "Stop" : "Start counting", systemImage: model.status.running ? "stop.fill" : "ear")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.bordered)
        .tint(model.status.running ? .red : .white)
    }
}

/// The big count (or step call) plus one dot per beat of the cycle.
struct CountDisplay: View {
    let call: Call?

    var body: some View {
        let isOne = call?.position == 1
        VStack(spacing: 22) {
            Text(call?.text ?? "–")
                .font(.system(size: 150, weight: .heavy, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(isOne ? Color.accentColor : .white)
                // Instant change: at dance tempos any cross-fade leaves the count blurred
                // for much of the beat.
                .contentTransition(.identity)
                .frame(height: 170)
                .accessibilityLabel(call.map { "Count \($0.text)" } ?? "Not counting")
            let cycle = call?.cycle ?? 8
            HStack(spacing: 14) {
                ForEach(1...cycle, id: \.self) { n in
                    let big = n == 1 || (cycle % 2 == 0 && n == cycle / 2 + 1)
                    Circle()
                        .fill(n == call?.position ? (n == 1 ? Color.accentColor : .white) : Color.white.opacity(0.18))
                        .frame(width: big ? 16 : 11, height: big ? 16 : 11)
                        .frame(width: 18, height: 18)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

struct SmallButton: View {
    let title: String
    let subtitle: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .white)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        let db = 20 * log10(max(level, 1e-4))
        let fraction = CGFloat(min(1, max(0, (db + 60) / 60)))
        Capsule().fill(Color.white.opacity(0.15))
            .frame(width: 40, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(Color.green).frame(width: 40 * fraction, height: 6)
            }
            .accessibilityLabel("Microphone level")
    }
}
