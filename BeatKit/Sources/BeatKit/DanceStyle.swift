import Foundation

/// A dance determines the tempo range we search (which fixes most half/double-speed mistakes),
/// the meter, and how the count is voiced.
public enum DanceStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    // Social
    case salsa, bachata, kizomba, westCoastSwing, lindyHop
    // Ballroom standard
    case waltz, vienneseWaltz, tango, foxtrot, quickstep
    // Ballroom latin
    case chaCha, samba, rumba, pasoDoble, jive
    case other

    public var id: String { rawValue }

    public enum Family: String, CaseIterable, Sendable {
        case social = "Social"
        case standard = "Standard"
        case latin = "Latin"
    }

    public var family: Family {
        switch self {
        case .salsa, .bachata, .kizomba, .westCoastSwing, .lindyHop, .other: .social
        case .waltz, .vienneseWaltz, .tango, .foxtrot, .quickstep: .standard
        case .chaCha, .samba, .rumba, .pasoDoble, .jive: .latin
        }
    }

    public var name: String {
        switch self {
        case .salsa: "Salsa"
        case .bachata: "Bachata"
        case .kizomba: "Kizomba"
        case .westCoastSwing: "West Coast Swing"
        case .lindyHop: "Lindy Hop"
        case .waltz: "Waltz"
        case .vienneseWaltz: "Viennese Waltz"
        case .tango: "Tango"
        case .foxtrot: "Slow Foxtrot"
        case .quickstep: "Quickstep"
        case .chaCha: "Cha-cha"
        case .samba: "Samba"
        case .rumba: "Rumba"
        case .pasoDoble: "Paso Doble"
        case .jive: "Jive"
        case .other: "Other"
        }
    }

    /// Beats per bar: 3 for the waltzes, 4 otherwise (samba and paso doble are written in 2/4
    /// but danced and counted in 8s like the rest).
    public var beatsPerBar: Int {
        switch self {
        case .waltz, .vienneseWaltz: 3
        default: 4
        }
    }

    /// The count runs over two bars: 1…8, or 1…6 in 3/4.
    public var countCycle: Int { 2 * beatsPerBar }

    /// Range of counted beats per minute. Ballroom ranges are the competition tempos
    /// (bars per minute × beats per bar) widened for social and practice music.
    public var tempoRange: ClosedRange<Double> {
        switch self {
        case .salsa: 140...235
        case .bachata: 105...160
        case .kizomba: 75...118
        case .westCoastSwing: 70...135
        case .lindyHop: 110...240
        case .waltz: 75...100          // 28–30 bars/min
        case .vienneseWaltz: 150...190 // 58–60 bars/min
        case .tango: 112...140         // 31–33 bars/min
        case .foxtrot: 96...128        // 28–30 bars/min
        case .quickstep: 180...216     // 50–52 bars/min
        case .chaCha: 108...136        // 30–32 bars/min
        case .samba: 90...112          // 50–52 bars/min of 2/4
        case .rumba: 88...112          // 25–27 bars/min
        case .pasoDoble: 110...130     // 60–62 bars/min of 2/4
        case .jive: 150...190          // 42–44 bars/min
        case .other: 70...200
        }
    }

    /// Most likely tempo; ties between half and double speed are broken towards it.
    public var typicalBPM: Double {
        switch self {
        case .salsa: 185
        case .bachata: 128
        case .kizomba: 94
        case .westCoastSwing: 100
        case .lindyHop: 150
        case .waltz: 87
        case .vienneseWaltz: 177
        case .tango: 128
        case .foxtrot: 116
        case .quickstep: 204
        case .chaCha: 124
        case .samba: 102
        case .rumba: 104
        case .pasoDoble: 122
        case .jive: 172
        case .other: 120
        }
    }

    /// Where the music's strongest low/harmonic accent sits relative to "1", in beats.
    /// Salsa's tumbao bass and conga open tones land on 4 (and 8), anticipating the 1.
    var accentToOne: Int {
        self == .salsa ? 1 : 0
    }

    /// Counts that dancers don't step on and say nothing for (salsa's 4 and 8).
    public var quietCounts: Set<Int> {
        self == .salsa ? [4, 8] : []
    }

    /// Counts voiced as "tap" (bachata's 4 and 8).
    public var tapCounts: Set<Int> {
        self == .bachata ? [4, 8] : []
    }
}
