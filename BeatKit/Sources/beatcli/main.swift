import AVFoundation
import BeatKit
import Foundation

// beatcli bench                                  — accuracy table over synthetic grooves
// beatcli synth <groove> <bpm> <out.wav> [--pocket] [--crowd 0.5] [--counts]
// beatcli file <audio> [--style salsa] [--out mixed.wav] [--lead 0.35]

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func style(for groove: SyntheticSong.Groove, bpm: Double) -> DanceStyle {
    switch groove {
    case .salsa: .salsa
    case .bachata: .bachata
    case .swing: .lindyHop
    case .pop: bpm < 118 ? .kizomba : .other
    case .waltz: bpm < 120 ? .waltz : .vienneseWaltz
    }
}

func writeWav(_ samples: [Float], sampleRate: Double, to path: String) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

func readMono(_ path: String) throws -> ([Float], Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let n = Int(buffer.frameLength)
    let channels = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for c in 0..<channels {
        let data = buffer.floatChannelData![c]
        for i in 0..<n { mono[i] += data[i] / Float(channels) }
    }
    return (mono, format.sampleRate)
}

/// Mixes count clicks over the music so a person can listen to what the app would do.
func mixCounts(_ music: [Float], sampleRate: Double, events: [Simulation.Event]) -> [Float] {
    var out = music.map { $0 * 0.6 }
    for e in events {
        let freq: Double = e.beat.count == 1 ? 1760 : (e.beat.count == 5 ? 1320 : 880)
        let gain: Float = e.beat.count == 1 ? 0.5 : 0.3
        let start = Int(e.beat.time * sampleRate)
        for i in 0..<Int(0.04 * sampleRate) where start + i >= 0 && start + i < out.count {
            let t = Double(i) / sampleRate
            out[start + i] += gain * Float(sin(2 * .pi * freq * t) * exp(-t / 0.012))
        }
    }
    return out
}

switch args.first {
case "bench":
    let pocketOnly = args.contains("--pocket")
    let cases: [(SyntheticSong.Groove, Double)] = [
        (.pop, 96), (.pop, 124), (.salsa, 170), (.salsa, 200), (.bachata, 126), (.bachata, 140), (.swing, 140), (.swing, 180),
        (.waltz, 87), (.waltz, 177),
    ]
    let conditions: [(String, (inout SyntheticSong.Options) -> Void)] = [
        ("clean", { _ in }),
        ("pocket+crowd+reverb", { $0.pocket = true; $0.crowd = 0.6; $0.reverb = true }),
        ("loud crowd", { $0.crowd = 1.2; $0.reverb = true }),
    ]
    print("== noise only (beats counted per minute; should be ~0)")
    for crowd: Float in [0.6, 1.2] {
        for pocket in [false, true] {
            var o = SyntheticSong.Options(bpm: 120, groove: .pop)
            o.seconds = 60
            o.crowd = crowd
            o.musicGain = 0
            o.pocket = pocket
            o.reverb = true
            o.seed = UInt64(crowd * 10) + (pocket ? 1 : 0)
            let song = SyntheticSong.make(o)
            for style in [DanceStyle.salsa, .bachata, .other] {
                let events = Simulation.run(samples: song.samples, sampleRate: song.sampleRate, style: style)
                print(String(format: "crowd %.1f %@ %-8@ %3d beats/min", crowd, pocket ? "pocket" : "open  ", style.rawValue, events.count))
            }
        }
    }
    for (name, apply) in conditions where !pocketOnly || name != "clean" {
        print("== \(name)")
        for (groove, bpm) in cases {
            var o = SyntheticSong.Options(bpm: bpm, groove: groove)
            o.seconds = 50
            o.drift = 0.01
            o.seed = UInt64(bpm)
            apply(&o)
            let song = SyntheticSong.make(o)
            let events = Simulation.run(samples: song.samples, sampleRate: song.sampleRate, style: style(for: groove, bpm: bpm))
            let danceStyle = style(for: groove, bpm: bpm)
            let ones = Array(stride(from: 0, to: song.beatTimes.count, by: danceStyle.countCycle))
            let score = Simulation.score(events, truth: song.beatTimes, ones: ones, cycle: danceStyle.countCycle)
            let bpmOut = events.last.map { String(format: "%.1f", $0.bpm) } ?? "-"
            print(String(format: "%-8@ %3.0f bpm → %6@ | ", groove.rawValue, bpm, bpmOut) + score.description)
        }
    }

case "debug":
    let groove = SyntheticSong.Groove(rawValue: args[1])!
    let bpm = Double(args[2])!
    var o = SyntheticSong.Options(bpm: bpm, groove: groove)
    o.seconds = 50
    o.drift = 0.01
    o.seed = UInt64(bpm)
    o.pocket = args.contains("--pocket")
    if args.contains("--noisy") { o.pocket = true; o.crowd = 0.6; o.reverb = true }
    o.crowd = Float(option("--crowd") ?? "\(o.crowd)") ?? 0
    o.reverb = o.reverb || args.contains("--reverb")
    o.musicGain = Float(option("--music") ?? "1") ?? 1
    let song = SyntheticSong.make(o)
    var profile: [Double] = []
    var lines = 0
    let events = Simulation.run(samples: song.samples, sampleRate: song.sampleRate, style: style(for: groove, bpm: bpm),
                                configure: { tracker in
        tracker.onGridEvent = { print($0) }
        tracker.onDownbeatFeatures = { index, t, low, harmony, accent in
            guard args.contains("--features"), lines < 40, let k = song.beatTimes.indices.min(by: { abs(song.beatTimes[$0] - t) < abs(song.beatTimes[$1] - t) }) else { return }
            lines += 1
            print(String(format: "idx %d  t %.3f  truth %d (%.3f)  low %.2f  harm %.3f  acc %.2f", index, t, k % 8 + 1, song.beatTimes[k], low, harmony, accent))
        }
    }, onChunk: { t, now in
        profile = t.downbeatProfile
        if args.contains("--trace"), Int(now * 2) != Int((now - 1024 / song.sampleRate) * 2) {
            print(String(format: "  %.1fs strength %.3f salience %.2f clarity %.2f  measured %@  locked %@", now, t.rhythmStrength, t.salience, t.beatClarity, t.lastMeasuredBPM.map { String(format: "%.1f", $0) } ?? "-", t.bpm.map { String(format: "%.1f", $0) } ?? "-"))
        }
    })
    var lastPrint = -10.0
    for e in events where e.beat.time - lastPrint > 4 && e.beat.time < song.beatTimes.last! {
        lastPrint = e.beat.time
        if let k = song.beatTimes.indices.min(by: { abs(song.beatTimes[$0] - e.beat.time) < abs(song.beatTimes[$1] - e.beat.time) }) {
            print(String(format: "%.1fs  index-truth mod8 %d  err %+.0f ms  count %d truth %d", e.beat.time, ((e.beat.index - k) % 8 + 8) % 8, (e.beat.time - song.beatTimes[k]) * 1000, e.beat.count, k % 8 + 1))
        }
    }
    // Map tracker indices to truth indices via the last matched beat.
    if let e = events.last(where: { $0.beat.time < song.beatTimes.last! }), let k = song.beatTimes.indices.min(by: { abs(song.beatTimes[$0] - e.beat.time) < abs(song.beatTimes[$1] - e.beat.time) }) {
        let shift = ((e.beat.index - k) % 8 + 8) % 8
        let byTruth = (0..<8).map { profile[($0 + shift) % 8] }
        print("score by true count 1…8:", byTruth.map { String(format: "%.1f", $0) }.joined(separator: " "))
        print("last beat count \(e.beat.count), truth \(k % 8 + 1)")
    }

case "synth":
    guard args.count >= 4, let groove = SyntheticSong.Groove(rawValue: args[1]), let bpm = Double(args[2]) else {
        print("usage: beatcli synth <pop|salsa|bachata|swing> <bpm> <out.wav> [--pocket] [--crowd x] [--counts]")
        exit(1)
    }
    var o = SyntheticSong.Options(bpm: bpm, groove: groove)
    o.seconds = Double(option("--seconds") ?? "40") ?? 40
    o.pocket = args.contains("--pocket")
    o.crowd = Float(option("--crowd") ?? "0") ?? 0
    o.reverb = args.contains("--reverb")
    let song = SyntheticSong.make(o)
    var samples = song.samples
    if args.contains("--counts") {
        let events = Simulation.run(samples: samples, sampleRate: song.sampleRate, style: style(for: groove, bpm: bpm))
        samples = mixCounts(samples, sampleRate: song.sampleRate, events: events)
    }
    try writeWav(samples, sampleRate: song.sampleRate, to: args[3])
    print("wrote \(args[3])")

case "file":
    guard args.count >= 2 else { print("usage: beatcli file <audio> [--style salsa] [--out mixed.wav]"); exit(1) }
    let (samples, sr) = try readMono(args[1])
    let danceStyle = DanceStyle(rawValue: option("--style") ?? "other") ?? .other
    let lead = Double(option("--lead") ?? "0.35") ?? 0.35
    var lastReport = -10.0
    let events = Simulation.run(samples: samples, sampleRate: sr, style: danceStyle, lead: lead, configure: { t in
        t.onGridEvent = { print("   grid: \($0)") }
    }, onChunk: { tracker, now in
        if now - lastReport >= (args.contains("--fine") ? 1 : 5) {
            lastReport = now
            let state = tracker.bpm.map { String(format: "%.1f bpm, count %d", $0, tracker.currentBeat(at: now)?.count ?? 0) } ?? "listening"
            print(String(format: "%6.1fs  rhythm %.2f clarity %.2f measured %@  %@", now, tracker.rhythmStrength, tracker.beatClarity, tracker.lastMeasuredBPM.map { String(format: "%.1f", $0) } ?? "-", state))
        }
    })
    print("\(events.count) beats counted")
    if let out = option("--out") {
        try writeWav(mixCounts(samples, sampleRate: sr, events: events), sampleRate: sr, to: out)
        print("wrote \(out) — high click = 1, middle = 5")
    }

default:
    print("usage: beatcli bench | synth … | file …")
}
