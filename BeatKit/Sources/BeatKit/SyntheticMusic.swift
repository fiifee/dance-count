import Foundation

/// Generated test music with known beat times, so the tracker can be measured without
/// real recordings. Grooves deliberately include the hard parts: salsa's anticipated bass,
/// swing eighths, crowd noise, reverb and a "phone in a pocket" low-pass.
public struct SyntheticSong {
    public var samples: [Float]
    public let sampleRate: Double
    /// Ground-truth beat times (seconds).
    public var beatTimes: [Double]
    /// Index into `beatTimes` of the first "1" of an 8-count.
    public var firstOneIndex: Int

    public enum Groove: String, CaseIterable, Sendable {
        case pop, salsa, bachata, swing, waltz
    }

    public struct Options: Sendable {
        public var bpm: Double
        public var seconds: Double = 60
        public var groove: Groove = .pop
        public var sampleRate: Double = 48_000
        /// Silence before the music starts.
        public var intro: Double = 0.5
        /// Muffle like a phone in a trouser pocket.
        public var pocket = false
        /// Crowd chatter level relative to the music (0 = none, 1 = as loud).
        public var crowd: Float = 0
        public var reverb = false
        /// Timing humanisation, seconds (standard deviation).
        public var jitter: Double = 0.008
        /// Total tempo change across the song, as a fraction (0.02 = speeds up 2 %).
        public var drift: Double = 0
        public var seed: UInt64 = 1
        /// 0 leaves only the crowd (for testing that noise alone isn't counted).
        public var musicGain: Float = 1

        public init(bpm: Double, groove: Groove = .pop) {
            self.bpm = bpm
            self.groove = groove
        }
    }

    public static func make(_ o: Options) -> SyntheticSong {
        var rng = SplitMix(seed: o.seed)
        let sr = o.sampleRate
        let total = Int((o.intro + o.seconds) * sr)
        var out = [Float](repeating: 0, count: total)

        // Beat grid with drift and humanisation.
        var beats: [Double] = []
        var t = o.intro
        while t < o.intro + o.seconds - 0.5 {
            beats.append(t)
            let progress = (t - o.intro) / o.seconds
            t += 60 / (o.bpm * (1 + o.drift * progress))
        }
        let played = beats.map { $0 + rng.gaussian() * o.jitter }
        func at(_ beat: Int, _ fraction: Double) -> Double? {
            guard beat + 1 < played.count else { return nil }
            return played[beat] + fraction * (played[beat + 1] - played[beat])
        }

        // I–V–vi–IV, one chord per 4 beats. Roots in Hz (A2-ish) and triads.
        let roots: [Double] = [110.0, 164.81, 92.50, 146.83]
        let triads: [[Double]] = [[220, 277.18, 329.63], [329.63, 415.30, 493.88], [185.0, 220, 277.18], [293.66, 369.99, 440]]
        func chord(ofBeat beat: Int) -> Int { (beat / 4) % 4 }

        func add(_ sound: [Float], at time: Double?, gain: Float = 1) {
            guard let time else { return }
            let start = Int(time * sr)
            for (i, v) in sound.enumerated() where start + i >= 0 && start + i < total {
                out[start + i] += gain * v
            }
        }

        let kick = Instruments.kick(sr: sr)
        let snare = Instruments.snare(sr: sr, rng: &rng)
        let hat = Instruments.hat(sr: sr, rng: &rng)
        let clave = Instruments.ping(sr: sr, freq: 2500, decay: 0.03)
        let bell = Instruments.ping(sr: sr, freq: 1100, decay: 0.06)
        let congaOpen = Instruments.ping(sr: sr, freq: 330, decay: 0.12)
        let congaSlap = Instruments.slap(sr: sr, rng: &rng)
        let guira = Instruments.scrape(sr: sr, rng: &rng)

        for i in 0..<beats.count {
            let c = chord(ofBeat: i)
            let inBar = i % 4
            let inEight = i % 8
            // Chord pad, re-struck at every bar start (salsa: the montuno replaces it).
            if inBar == 0, o.groove != .salsa, o.groove != .waltz {
                let len = 4 * 60 / o.bpm
                add(Instruments.pad(sr: sr, freqs: triads[c], seconds: len), at: played[i], gain: 0.12)
            }
            switch o.groove {
            case .pop:
                add(kick, at: played[i], gain: 0.9)
                if inBar == 1 || inBar == 3 { add(snare, at: played[i], gain: 0.5) }
                add(hat, at: played[i], gain: 0.2)
                add(hat, at: at(i, 0.5), gain: 0.12)
                add(Instruments.bass(sr: sr, freq: roots[c], seconds: 0.25), at: played[i], gain: 0.5)
            case .salsa:
                // Son clave 3-2 over the 8-count: 1, 2&, 4 | 6, 7.
                if [0, 3, 5, 6].contains(inEight) { add(clave, at: played[i], gain: 0.35) }
                if inEight == 1 { add(clave, at: at(i, 0.5), gain: 0.35) }
                add(bell, at: played[i], gain: inBar == 0 ? 0.3 : 0.2)
                // Conga tumbao: slap on 2, open tones on 4 and 4&.
                if inBar == 1 { add(congaSlap, at: played[i], gain: 0.35) }
                if inBar == 3 { add(congaOpen, at: played[i], gain: 0.45); add(congaOpen, at: at(i, 0.5), gain: 0.4) }
                // Anticipated bass: 2& and 4, playing the *next* chord on 4.
                if inBar == 1 { add(Instruments.bass(sr: sr, freq: roots[c], seconds: 0.3), at: at(i, 0.5), gain: 0.55) }
                if inBar == 3 { add(Instruments.bass(sr: sr, freq: roots[chord(ofBeat: i + 1)], seconds: 0.5), at: played[i], gain: 0.6) }
                // Piano montuno: off-beat-heavy eighths.
                for (beatOffset, fraction) in [(0, 0.0), (0, 0.5), (1, 0.5), (2, 0.0), (2, 0.5), (3, 0.5)] where beatOffset == inBar {
                    add(Instruments.pad(sr: sr, freqs: triads[c], seconds: 0.12), at: at(i, fraction), gain: 0.18)
                }
            case .bachata:
                add(guira, at: played[i], gain: 0.25)
                add(guira, at: at(i, 0.5), gain: 0.15)
                if inBar == 0 || inBar == 2 { add(Instruments.bass(sr: sr, freq: roots[c], seconds: 0.3), at: played[i], gain: 0.55) }
                if inBar == 3 { add(congaOpen, at: played[i], gain: 0.4); add(Instruments.bass(sr: sr, freq: roots[c] * 1.5, seconds: 0.2), at: played[i], gain: 0.4) }
                add(Instruments.ping(sr: sr, freq: 700, decay: 0.05), at: played[i], gain: 0.25)
                add(Instruments.ping(sr: sr, freq: 600, decay: 0.04), at: at(i, 0.5), gain: 0.15)
            case .waltz:
                // Oom-pah-pah: bass + soft kick on 1, chord stabs on 2 and 3, new chord each bar.
                let bar = i / 3
                let chord3 = bar % 4
                if i % 3 == 0 {
                    add(Instruments.bass(sr: sr, freq: roots[chord3], seconds: 0.5), at: played[i], gain: 0.6)
                    add(kick, at: played[i], gain: 0.3)
                    add(Instruments.pad(sr: sr, freqs: triads[chord3], seconds: 3 * 60 / o.bpm), at: played[i], gain: 0.08)
                } else {
                    add(Instruments.pad(sr: sr, freqs: triads[chord3], seconds: 0.18), at: played[i], gain: 0.22)
                    add(hat, at: played[i], gain: 0.08)
                }
            case .swing:
                // Walking bass every beat, ride "ding, ding-a", backbeat snare.
                let walk = roots[c] * [1, 1.26, 1.5, 1.68][inBar]
                add(Instruments.bass(sr: sr, freq: walk, seconds: 0.3), at: played[i], gain: 0.5)
                add(Instruments.ping(sr: sr, freq: 5000, decay: 0.15), at: played[i], gain: 0.12)
                if inBar == 1 || inBar == 3 {
                    add(snare, at: played[i], gain: 0.35)
                    add(Instruments.ping(sr: sr, freq: 5000, decay: 0.1), at: at(i, 0.66), gain: 0.08)
                }
                if inBar == 0 { add(kick, at: played[i], gain: 0.4) }
            }
        }

        if o.reverb { Effects.reverb(&out, sr: sr) }
        if o.crowd > 0 || o.musicGain != 1 { Effects.addCrowd(&out, sr: sr, level: o.crowd, musicGain: o.musicGain, rng: &rng) }
        if o.pocket { Effects.pocket(&out, sr: sr) }
        Effects.normalize(&out, peak: 0.5)
        for i in 0..<out.count { out[i] += Float(rng.gaussian()) * 0.002 }

        return SyntheticSong(samples: out, sampleRate: sr, beatTimes: beats, firstOneIndex: 0)
    }

    /// Joins songs with a gap of silence (a DJ change), shifting ground truth accordingly.
    public static func playlist(_ songs: [SyntheticSong], gap: Double) -> (SyntheticSong, [Range<Int>]) {
        var samples: [Float] = []
        var beats: [Double] = []
        var ranges: [Range<Int>] = []
        let sr = songs[0].sampleRate
        for song in songs {
            let offset = Double(samples.count) / sr
            let start = beats.count
            beats += song.beatTimes.map { $0 + offset }
            ranges.append(start..<beats.count)
            samples += song.samples
            samples += [Float](repeating: 0, count: Int(gap * sr))
        }
        return (SyntheticSong(samples: samples, sampleRate: sr, beatTimes: beats, firstOneIndex: 0), ranges)
    }
}

// MARK: - Sound sources

enum Instruments {
    static func envelope(_ n: Int, sr: Double, decay: Double) -> [Float] {
        (0..<n).map { i in
            let t = Double(i) / sr
            return Float(min(1, t / 0.002) * exp(-t / decay))
        }
    }

    static func kick(sr: Double) -> [Float] {
        let n = Int(0.25 * sr)
        let env = envelope(n, sr: sr, decay: 0.07)
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / sr
            phase += 2 * .pi * (50 + 90 * exp(-t / 0.03)) / sr
            return env[i] * Float(sin(phase))
        }
    }

    static func snare(sr: Double, rng: inout SplitMix) -> [Float] {
        let n = Int(0.18 * sr)
        let env = envelope(n, sr: sr, decay: 0.05)
        var prev: Float = 0
        return (0..<n).map { i in
            let noise = Float(rng.uniform() * 2 - 1)
            let hp = noise - prev
            prev = noise
            return env[i] * (0.7 * hp + 0.4 * Float(sin(2 * .pi * 190 * Double(i) / sr)))
        }
    }

    static func hat(sr: Double, rng: inout SplitMix) -> [Float] {
        let n = Int(0.05 * sr)
        let env = envelope(n, sr: sr, decay: 0.012)
        var prev: Float = 0
        return (0..<n).map { i in
            let noise = Float(rng.uniform() * 2 - 1)
            let hp = noise - prev
            prev = noise
            return env[i] * hp
        }
    }

    static func slap(sr: Double, rng: inout SplitMix) -> [Float] {
        let n = Int(0.08 * sr)
        let env = envelope(n, sr: sr, decay: 0.02)
        return (0..<n).map { i in
            env[i] * (0.6 * Float(rng.uniform() * 2 - 1) + 0.5 * Float(sin(2 * .pi * 420 * Double(i) / sr)))
        }
    }

    static func scrape(sr: Double, rng: inout SplitMix) -> [Float] {
        let n = Int(0.07 * sr)
        let env = envelope(n, sr: sr, decay: 0.03)
        var prev: Float = 0
        return (0..<n).map { i in
            let noise = Float(rng.uniform() * 2 - 1)
            let hp = noise - prev
            prev = noise
            let ridges = Float(0.5 + 0.5 * sin(2 * .pi * 90 * Double(i) / sr))
            return env[i] * hp * ridges
        }
    }

    static func ping(sr: Double, freq: Double, decay: Double) -> [Float] {
        let n = Int(decay * 5 * sr)
        let env = envelope(n, sr: sr, decay: decay)
        return (0..<n).map { env[$0] * Float(sin(2 * .pi * freq * Double($0) / sr)) }
    }

    static func bass(sr: Double, freq: Double, seconds: Double) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let env = min(1, t / 0.005) * exp(-t / (seconds * 0.6))
            return Float(env * (sin(2 * .pi * freq * t) + 0.3 * sin(4 * .pi * freq * t)))
        }
    }

    static func pad(sr: Double, freqs: [Double], seconds: Double) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let env = min(1, t / 0.01) * min(1, (seconds - t) / 0.05) * exp(-t / (seconds * 1.5))
            return Float(env * freqs.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(freqs.count))
        }
    }
}

// MARK: - Room / pocket effects

enum Effects {
    static func reverb(_ x: inout [Float], sr: Double) {
        let delays = [0.0297, 0.0371, 0.0411, 0.0437].map { Int($0 * sr) }
        let dry = x
        var wet = [Float](repeating: 0, count: x.count)
        for d in delays {
            var comb = [Float](repeating: 0, count: x.count)
            for i in 0..<x.count {
                comb[i] = dry[i] + (i >= d ? 0.78 * comb[i - d] : 0)
            }
            for i in 0..<x.count { wet[i] += comb[i] * 0.25 }
        }
        for i in 0..<x.count { x[i] = dry[i] + 0.35 * wet[i] }
    }

    /// Babble: noise shaped into ~4 syllables per second, speech band.
    static func addCrowd(_ x: inout [Float], sr: Double, level: Float, musicGain: Float, rng: inout SplitMix) {
        var musicPower: Float = 0
        for v in x { musicPower += v * v }
        musicPower /= Float(x.count)
        var crowd = [Float](repeating: 0, count: x.count)
        var lp1: Float = 0, lp2: Float = 0, hpPrev: Float = 0
        let a = Float(exp(-2 * .pi * 1800 / sr))
        // Each voice talks in bursts: syllables of random length at random times, with pauses.
        var voices = (0..<8).map { _ in (end: 0.0, start: 0.0, talking: true, until: rng.uniform() * 3) }
        for i in 0..<x.count {
            let t = Double(i) / sr
            var mod = 0.0
            for v in 0..<voices.count {
                if t >= voices[v].until {
                    voices[v].talking.toggle()
                    voices[v].until = t + (voices[v].talking ? 1 + rng.uniform() * 4 : 0.3 + rng.uniform() * 2)
                }
                guard voices[v].talking else { continue }
                if t >= voices[v].end {
                    voices[v].start = t + rng.uniform() * 0.08
                    voices[v].end = voices[v].start + 0.08 + rng.uniform() * 0.25
                }
                if t >= voices[v].start { mod += sin(.pi * (t - voices[v].start) / (voices[v].end - voices[v].start)) }
            }
            let noise = Float(rng.uniform() * 2 - 1)
            lp1 = a * lp1 + (1 - a) * noise
            lp2 = a * lp2 + (1 - a) * lp1
            let band = lp2 - hpPrev * 0.95
            hpPrev = lp2
            crowd[i] = band * Float(mod)
        }
        var crowdPower: Float = 0
        for v in crowd { crowdPower += v * v }
        crowdPower /= Float(crowd.count)
        let gain = level * (musicPower / max(crowdPower, 1e-12)).squareRoot()
        for i in 0..<x.count { x[i] = musicGain * x[i] + gain * crowd[i] }
    }

    /// Fabric + body: strong low-pass around 700 Hz and lower level.
    static func pocket(_ x: inout [Float], sr: Double) {
        let a = Float(exp(-2 * .pi * 700 / sr))
        var s1: Float = 0, s2: Float = 0
        for i in 0..<x.count {
            s1 = a * s1 + (1 - a) * x[i]
            s2 = a * s2 + (1 - a) * s1
            x[i] = 0.3 * s2
        }
    }

    static func normalize(_ x: inout [Float], peak: Float) {
        let m = x.map(abs).max() ?? 0
        guard m > 0 else { return }
        for i in 0..<x.count { x[i] *= peak / m }
    }
}

// MARK: - Deterministic RNG

public struct SplitMix {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
