import BeatKit
import Foundation

enum MicSource: String, CaseIterable, Identifiable {
    case airPods, iPhone
    var id: String { rawValue }
    var label: String { self == .airPods ? "AirPods" : "iPhone" }
}

enum CountSound: String, CaseIterable, Identifiable {
    case voice, clicks
    var id: String { rawValue }
    var label: String { self == .voice ? "Voice" : "Clicks" }
}

enum CountDensity: String, CaseIterable, Identifiable {
    case everyBeat, oneAndFive, onlyOne
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyBeat: "Every beat"
        case .oneAndFive: "Each bar (1, 5)"
        case .onlyOne: "Only 1"
        }
    }

    /// "1 and 5" means the start of each bar: 1 and 4 in a waltz's 6-count.
    func plays(_ count: Int, cycle: Int) -> Bool {
        switch self {
        case .everyBeat: true
        case .oneAndFive: count == 1 || count == cycle / 2 + 1
        case .onlyOne: count == 1
        }
    }
}

/// How a dance is called: plain numbers, or the footwork ("rock, step, tri-ple, step").
struct StepPattern: Identifiable, Equatable {
    struct Step: Equatable {
        /// Shown on screen and used as the voice key.
        let word: String
        /// False when a slow step is held over this beat.
        let spoken: Bool
    }

    let id: String
    let label: String
    /// One step per beat, cycling from the "1"; nil = count numbers.
    let steps: [Step]?

    static let numbers = StepPattern(id: "numbers", label: "Numbers", steps: nil)

    /// `nil` entries hold the previous step silently (the second beat of a "slow").
    static func calls(_ id: String, _ label: String, _ words: [String?]) -> StepPattern {
        var steps: [Step] = []
        for word in words {
            if let word { steps.append(Step(word: word, spoken: true)) } else { steps.append(Step(word: steps.last?.word ?? "", spoken: false)) }
        }
        return StepPattern(id: id, label: label, steps: steps)
    }
}

extension DanceStyle {
    /// Available ways to call this dance; the first is the default.
    /// "triple" and "cha-cha" start on the beat so their second syllable lands near the "&".
    var patterns: [StepPattern] {
        switch self {
        case .lindyHop: [
            .calls("lindy6", "6-count basic", ["rock", "step", "triple", "step", "triple", "step"]),
            .calls("swingout", "8-count swing out", ["rock", "step", "triple", "step", "step", "step", "triple", "step"]),
            .numbers]
        case .westCoastSwing: [
            .calls("wcs6", "6-count (sugar push)", ["walk", "walk", "triple", "step", "anchor", "step"]),
            .calls("whip", "8-count (whip)", ["walk", "walk", "triple", "step", "step", "step", "anchor", "step"]),
            .numbers]
        case .jive: [
            .calls("jive", "Basic: rock step, chassé ×2", ["rock", "step", "cha-cha", "cha", "cha-cha", "cha"]),
            .numbers]
        case .chaCha: [
            .calls("chacha", "2, 3, cha-cha-cha", ["cha", "2", "3", "cha-cha"]),
            .numbers]
        case .rumba: [
            .calls("rumba", "Quick, quick, slow", [nil, "quick", "quick", "slow"]),
            .numbers]
        case .foxtrot: [
            .calls("foxtrot", "Slow, quick, quick", ["slow", nil, "quick", "quick"]),
            .numbers]
        case .quickstep: [
            .calls("quickstep", "Slow, quick, quick, slow", ["slow", nil, "quick", "quick", "slow", nil]),
            .numbers]
        case .tango: [
            .calls("tango", "Slow, slow, quick, quick, slow", ["slow", nil, "slow", nil, "quick", "quick", "slow", nil]),
            .numbers]
        default: [.numbers]
        }
    }
}

/// What is said and shown on one beat.
struct Call: Equatable {
    /// Shown big on screen: "3", "tap", "rock", "•".
    var text: String
    /// Voice sound to play; nil = silent.
    var word: String?
    /// 1-based position within the cycle, 0 while the "1" isn't known yet.
    var position: Int
    var cycle: Int
    /// Plain beat tick (used before the "1" is known).
    var isTick = false

    /// Second accented position: 5 in an 8-count, 4 in waltz's 6.
    var isHalfway: Bool { cycle % 2 == 0 && position == cycle / 2 + 1 }

    static func make(for beat: (count: Int, countKnown: Bool, beatsSinceOne: Int), settings: CountSettings) -> Call {
        let style = settings.style
        guard beat.countKnown else { return Call(text: "•", word: nil, position: 0, cycle: style.countCycle, isTick: true) }
        if let steps = settings.pattern(for: style).steps {
            let position = ((beat.beatsSinceOne % steps.count) + steps.count) % steps.count
            let step = steps[position]
            let spoken = step.spoken && (settings.density == .everyBeat || position == 0)
            return Call(text: step.word, word: spoken ? step.word : nil, position: position + 1, cycle: steps.count)
        }
        let count = beat.count
        let cycle = style.countCycle
        let text = style.tapCounts.contains(count) ? "tap" : String(count)
        let spoken = settings.density.plays(count, cycle: cycle) && !style.quietCounts.contains(count)
        return Call(text: text, word: spoken ? text : nil, position: count, cycle: cycle)
    }
}

/// User preferences, persisted in UserDefaults.
struct CountSettings: Equatable {
    var style: DanceStyle = .salsa
    var mic: MicSource = .airPods
    var sound: CountSound = .voice
    var density: CountDensity = .everyBeat
    var volume: Double = 0.8
    /// Positive = counts arrive later. Compensates for latency the system doesn't report.
    var timingOffsetMs: Double = 0
    /// Chosen pattern id per dance (raw value → StepPattern.id).
    var patternIDs: [String: String] = [:]

    func pattern(for style: DanceStyle) -> StepPattern {
        let options = style.patterns
        return options.first { $0.id == patternIDs[style.rawValue] } ?? options[0]
    }

    private static let defaults = UserDefaults.standard

    static func load() -> CountSettings {
        var s = CountSettings()
        let d = defaults
        if let v = d.string(forKey: "style").flatMap(DanceStyle.init(rawValue:)) { s.style = v }
        if let v = d.string(forKey: "mic").flatMap(MicSource.init(rawValue:)) { s.mic = v }
        if let v = d.string(forKey: "sound").flatMap(CountSound.init(rawValue:)) { s.sound = v }
        if let v = d.string(forKey: "density").flatMap(CountDensity.init(rawValue:)) { s.density = v }
        if d.object(forKey: "volume") != nil { s.volume = d.double(forKey: "volume") }
        s.timingOffsetMs = d.double(forKey: "timingOffsetMs")
        if let v = d.dictionary(forKey: "patternIDs") as? [String: String] { s.patternIDs = v }
        return s
    }

    func save() {
        let d = Self.defaults
        d.set(style.rawValue, forKey: "style")
        d.set(mic.rawValue, forKey: "mic")
        d.set(sound.rawValue, forKey: "sound")
        d.set(density.rawValue, forKey: "density")
        d.set(volume, forKey: "volume")
        d.set(timingOffsetMs, forKey: "timingOffsetMs")
        d.set(patternIDs, forKey: "patternIDs")
    }
}
