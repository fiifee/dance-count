import Foundation

/// Replays audio through the tracker the way the app does: small chunks, and each beat is
/// committed `lead` seconds before it happens (Bluetooth output latency + scheduling margin).
/// What gets committed is exactly what the dancer would hear.
public enum Simulation {
    public struct Event {
        public let beat: Beat
        /// Stream time when the beat was committed.
        public let decidedAt: Double
        public let bpm: Double
    }

    public static func run(samples: [Float], sampleRate: Double, style: DanceStyle, lead: Double = 0.35,
                           chunk: Int = 1024, configure: (BeatTracker) -> Void = { _ in },
                           onChunk: (BeatTracker, Double) -> Void = { _, _ in }) -> [Event] {
        let tracker = BeatTracker(sampleRate: sampleRate, style: style)
        configure(tracker)
        var events: [Event] = []
        var lastTime = -Double.infinity
        var offset = 0
        samples.withUnsafeBufferPointer { all in
            while offset < all.count {
                let n = min(chunk, all.count - offset)
                tracker.process(UnsafeBufferPointer(rebasing: all[offset..<(offset + n)]))
                offset += n
                let now = tracker.streamTime
                onChunk(tracker, now)
                // Commit every beat that is now within the lead window.
                while let next = tracker.nextBeat(after: max(now, lastTime + 0.5 * tracker.period)),
                      next.time - lead <= now {
                    events.append(Event(beat: next, decidedAt: now, bpm: 60 / tracker.period))
                    lastTime = next.time
                }
            }
        }
        return events
    }

    public struct Score: CustomStringConvertible {
        public var fMeasure: Double
        public var meanOffsetMs: Double
        public var stdOffsetMs: Double
        /// Matched beats whose count (1…cycle) was right, after `settle` seconds.
        public var countAccuracy: Double
        /// Same, but 1 vs 5 (and 2 vs 6 …) confusions forgiven — the bar is right.
        public var barAccuracy: Double
        public var firstBeatAt: Double?

        public var description: String {
            String(format: "F %.2f  offset %+.0f±%.0f ms  count %3.0f%%  bar %3.0f%%  first beat %@",
                   fMeasure, meanOffsetMs, stdOffsetMs, countAccuracy * 100, barAccuracy * 100,
                   firstBeatAt.map { String(format: "%.1fs", $0) } ?? "never")
        }
    }

    /// Compares committed beats against ground truth (±70 ms window). `oneIndices` are
    /// indices into `truth` that are a "1"; counts are checked from `settle` seconds on.
    public static func score(_ events: [Event], truth: [Double], ones: [Int], settle: Double = 12, cycle: Int = 8) -> Score {
        let tolerance = 0.07
        var matchedTruth = Set<Int>()
        var offsets: [Double] = []
        var counted = 0, countRight = 0, barRight = 0
        var j = 0
        for e in events {
            while j < truth.count - 1 && truth[j + 1] <= e.beat.time { j += 1 }
            let candidates = [j, j + 1].filter { $0 < truth.count }
            guard let k = candidates.min(by: { abs(truth[$0] - e.beat.time) < abs(truth[$1] - e.beat.time) }),
                  abs(truth[k] - e.beat.time) <= tolerance, !matchedTruth.contains(k) else { continue }
            matchedTruth.insert(k)
            offsets.append(e.beat.time - truth[k])
            if truth[k] >= settle, let one = ones.last(where: { $0 <= k }) {
                let expected = (k - one) % cycle + 1
                counted += 1
                if expected == e.beat.count { countRight += 1 }
                if (expected - 1) % (cycle / 2) == (e.beat.count - 1) % (cycle / 2) { barRight += 1 }
            }
        }
        let precision = events.isEmpty ? 0 : Double(matchedTruth.count) / Double(events.count)
        let recall = Double(matchedTruth.count) / Double(max(1, truth.count))
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        let mean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let std = offsets.isEmpty ? 0 : (offsets.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(offsets.count)).squareRoot()
        return Score(fMeasure: f, meanOffsetMs: mean * 1000, stdOffsetMs: std * 1000,
                     countAccuracy: counted > 0 ? Double(countRight) / Double(counted) : 0,
                     barAccuracy: counted > 0 ? Double(barRight) / Double(counted) : 0,
                     firstBeatAt: events.first?.decidedAt)
    }
}
