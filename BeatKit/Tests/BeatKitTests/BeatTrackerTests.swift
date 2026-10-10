import XCTest
@testable import BeatKit

final class BeatTrackerTests: XCTestCase {
    private func song(_ groove: SyntheticSong.Groove, _ bpm: Double, seconds: Double = 30, noisy: Bool = false) -> SyntheticSong {
        var o = SyntheticSong.Options(bpm: bpm, groove: groove)
        o.seconds = seconds
        o.seed = 7
        if noisy { o.pocket = true; o.crowd = 0.6; o.reverb = true }
        return SyntheticSong.make(o)
    }

    func testTracksTempoAndBeatsOnCommonGrooves() {
        for (groove, bpm, style) in [(SyntheticSong.Groove.pop, 124.0, DanceStyle.other), (.bachata, 132, .bachata), (.swing, 160, .lindyHop), (.salsa, 190, .salsa)] {
            let s = song(groove, bpm)
            let events = Simulation.run(samples: s.samples, sampleRate: s.sampleRate, style: style)
            let score = Simulation.score(events, truth: s.beatTimes, ones: Array(stride(from: 0, to: s.beatTimes.count, by: 8)))
            XCTAssertGreaterThan(score.fMeasure, 0.85, "\(groove) \(bpm): \(score)")
            XCTAssertLessThan(abs(score.meanOffsetMs), 25, "\(groove) \(bpm): \(score)")
            XCTAssertEqual(events.last?.bpm ?? 0, bpm, accuracy: bpm * 0.02, "\(groove)")
            XCTAssertLessThan(score.firstBeatAt ?? 99, 6, "\(groove) should start counting within ~5 s")
        }
    }

    func testPocketAndCrowdStillTrackPop() {
        let s = song(.pop, 110, noisy: true)
        let events = Simulation.run(samples: s.samples, sampleRate: s.sampleRate, style: .other)
        let score = Simulation.score(events, truth: s.beatTimes, ones: [0])
        XCTAssertGreaterThan(score.fMeasure, 0.85, "\(score)")
    }

    func testChatterAloneIsNotCounted() {
        var o = SyntheticSong.Options(bpm: 120, groove: .pop)
        o.seconds = 40
        o.crowd = 1
        o.musicGain = 0
        o.reverb = true
        let s = SyntheticSong.make(o)
        let events = Simulation.run(samples: s.samples, sampleRate: s.sampleRate, style: .salsa)
        XCTAssertLessThan(events.count, 20, "counted \(events.count) beats in 40 s of chatter")
    }

    func testSilenceIsNotCounted() {
        let events = Simulation.run(samples: [Float](repeating: 0, count: 48_000 * 15), sampleRate: 48_000, style: .other)
        XCTAssertTrue(events.isEmpty)
    }

    func testFindsTheBarStartFromChordChanges() {
        let s = song(.pop, 124, seconds: 40)
        let events = Simulation.run(samples: s.samples, sampleRate: s.sampleRate, style: .other)
        let score = Simulation.score(events, truth: s.beatTimes, ones: Array(stride(from: 0, to: s.beatTimes.count, by: 8)), settle: 15)
        XCTAssertGreaterThan(score.barAccuracy, 0.9, "\(score)")
    }

    func testWaltzCountsInThrees() {
        for (bpm, style) in [(87.0, DanceStyle.waltz), (177, .vienneseWaltz)] {
            let s = song(.waltz, bpm, seconds: 45)
            let events = Simulation.run(samples: s.samples, sampleRate: s.sampleRate, style: style)
            let score = Simulation.score(events, truth: s.beatTimes, ones: Array(stride(from: 0, to: s.beatTimes.count, by: 6)), settle: 20, cycle: 6)
            XCTAssertGreaterThan(score.fMeasure, 0.85, "\(style): \(score)")
            XCTAssertGreaterThan(score.barAccuracy, 0.9, "\(style) should find the bar start: \(score)")
            XCTAssertTrue(events.allSatisfy { (1...6).contains($0.beat.count) })
        }
    }

    func testMarkOneAndShiftCount() {
        let s = song(.pop, 120, seconds: 15)
        let tracker = BeatTracker(sampleRate: s.sampleRate, style: .other)
        tracker.process(s.samples)
        XCTAssertTrue(tracker.isLocked)
        // Say "1" right on a true beat (with a little reaction delay).
        let beat = s.beatTimes.last { $0 < tracker.streamTime - 1 }!
        tracker.markOne(at: beat + 0.12, reactionLag: 0.1)
        XCTAssertTrue(tracker.oneIsManual)
        XCTAssertEqual(tracker.currentBeat(at: beat + 0.05)?.count, 1)
        tracker.shiftCount(by: 1)
        XCTAssertEqual(tracker.currentBeat(at: beat + 0.05)?.count, 2)
    }

    func testHalfBeatFlipMovesGridAndSticks() {
        let s = song(.pop, 120, seconds: 20)
        let tracker = BeatTracker(sampleRate: s.sampleRate, style: .other)
        let half = s.samples.count / 2
        tracker.process(Array(s.samples[..<half]))
        let before = tracker.nextBeat(after: tracker.streamTime)!.time
        tracker.flipHalfBeat()
        let end = s.samples.count - Int(3 * s.sampleRate)
        tracker.process(Array(s.samples[half..<end]))
        let after = tracker.nextBeat(after: tracker.streamTime)!.time
        // Distance to the nearest true beat should now be about half a beat (0.25 s).
        func offGrid(_ t: Double) -> Double { s.beatTimes.map { abs($0 - t) }.min()! }
        XCTAssertLessThan(offGrid(before), 0.05)
        XCTAssertEqual(offGrid(after), 0.25, accuracy: 0.05)
    }

    func testNextBeatAfterABeatAlwaysMovesForward() {
        let s = song(.salsa, 186, seconds: 12)
        let tracker = BeatTracker(sampleRate: s.sampleRate, style: .salsa)
        tracker.process(s.samples)
        var beat = tracker.nextBeat(after: tracker.streamTime)!
        for _ in 0..<2000 {
            let next = tracker.nextBeat(after: beat.time)!
            XCTAssertEqual(next.index, beat.index + 1)
            beat = next
        }
    }

    func testOnsetDetectorWorksAtBluetoothSampleRates() {
        for rate in [16_000.0, 24_000, 44_100, 48_000] {
            var o = SyntheticSong.Options(bpm: 128, groove: .pop)
            o.seconds = 20
            o.sampleRate = rate
            let s = SyntheticSong.make(o)
            let events = Simulation.run(samples: s.samples, sampleRate: rate, style: .other)
            let score = Simulation.score(events, truth: s.beatTimes, ones: [0])
            XCTAssertGreaterThan(score.fMeasure, 0.8, "\(rate) Hz: \(score)")
            XCTAssertLessThan(abs(score.meanOffsetMs), 25, "\(rate) Hz: \(score)")
        }
    }
}
