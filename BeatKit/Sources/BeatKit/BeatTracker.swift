import Accelerate
import Foundation

/// A predicted beat on the tracker's grid.
public struct Beat: Equatable, Sendable {
    /// Monotonic beat number on the current grid.
    public let index: Int
    /// Time in stream seconds (seconds of audio fed to the tracker so far).
    public let time: Double
    /// Position in the count cycle, 1…8 (1…6 for dances in 3/4).
    public let count: Int
    /// False until the tracker has a guess for the "1" (or the user set it); until then
    /// `count` is arbitrary and only the beat itself should be played.
    public let countKnown: Bool
    /// Beats since the most recent-or-future "1" on this grid (can be negative). Patterns
    /// that don't follow the 8-count, like Lindy Hop's 6-count basic, cycle on this.
    public let beatsSinceOne: Int
}

/// Real-time beat tracker: onset envelope → autocorrelation tempo → phase search → a
/// phase-locked beat grid that can be extrapolated into the future, plus a guess of
/// where the "1" of the 8-count is.
///
/// Not thread-safe: feed audio and query beats from one serial queue.
public final class BeatTracker {
    public let sampleRate: Double
    public var style: DanceStyle { didSet { if style != oldValue { resetGrid() } } }

    /// User override when the tracker locked onto half/double speed: 2 = count twice as fast.
    public var tempoFactor: Double = 1 { didSet { if tempoFactor != oldValue { resetGrid() } } }

    // MARK: Public state

    public private(set) var isLocked = false
    /// Seconds per counted beat while locked.
    public private(set) var period: Double = 0.5
    public var bpm: Double? { isLocked ? 60 / period : nil }
    /// Normalized periodicity of the music (0…1). Below ~0.1 there is no clear beat.
    public private(set) var rhythmStrength: Double = 0
    /// How much the winning tempo stands out from the others (z-score). Noise ≈ 2–3.
    public private(set) var salience: Double = 0
    /// True when the user set the "1" (tap) rather than the automatic guess.
    public private(set) var oneIsManual = false
    /// True after the user moved the grid half a beat (it had locked onto the off-beats).
    public private(set) var offBeatCorrection = false
    public var lastMeasuredBPM: Double? { tempoMeasurement.map { 60 / $0.period } }
    /// How sharply onsets line up on a beat grid (0…1, smoothed). Clear music ≈ 0.8, chatter ≈ 0.3–0.6.
    public var beatClarity: Double { clarityAverage }
    /// Accumulated "1-ness" per beat index mod 8 (diagnostics).
    public var downbeatProfile: [Double] { downbeatScores }
    /// Diagnostics hook: (beat index, beat time, low, harmony, accent).
    public var onDownbeatFeatures: ((Int, Double, Double, Double, Double) -> Void)?
    /// Diagnostics hook for grid events (lock, lose, phase jump).
    public var onGridEvent: ((String) -> Void)?
    /// Seconds of audio processed so far.
    public var streamTime: Double { Double(samplesProcessed) / sampleRate }

    // MARK: Tunables

    /// Delay between an onset in the audio and its novelty peak, removed from beat times.
    /// Measured on synthetic click tracks (see BeatKitTests).
    static let onsetLag: Double = 0.0
    private let minStrength = 0.02

    // MARK: Internals

    private let onset: OnsetDetector
    private let frameRate: Double
    private var samplesProcessed = 0
    private var framesProcessed = 0

    private var novelty: [Float] = []
    private var lowNovelty: [Float] = []
    private var chroma: [[Float]] = []
    private var baseFrame = 0
    private var recentFlux: [Float] = []
    private var recentFluxSum: Float = 0

    private var tempoMeasurement: (period: Double, strength: Double)?
    private var freshMeasurement = false
    private var recentPeriods: [Double] = []
    private var clarityAverage: Double = 0
    private var strongestRhythm: Double = 0
    private var unclearSeconds: Double = 0
    private var weakSeconds: Double = 0
    private var disagreeSeconds: Double = 0
    private var phaseOffSeconds: Double = 0

    private var anchorTime: Double = 0
    private var anchorIndex = 0
    private var lostAt: Double?

    private var oneIndex = 0
    private var downbeatScores = [Double](repeating: 0, count: 8)
    private var lastEvaluatedIndex = Int.min
    private var evaluatedBeats = 0
    private var candidateOne: Int?
    private var candidateOneVotes = 0
    private var featureMeans = (low: 0.0, harmony: 0.0, accent: 0.0)

    public init(sampleRate: Double, style: DanceStyle = .other) {
        self.sampleRate = sampleRate
        self.style = style
        onset = OnsetDetector(sampleRate: sampleRate)
        frameRate = onset.frameRate
    }

    // MARK: Feeding audio

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        onset.process(samples) { frame in
            self.append(frame)
            framesProcessed += 1
            if framesProcessed % 25 == 0 { measureTempo() }
            if framesProcessed % 10 == 0 { updateGrid() }
        }
        samplesProcessed += samples.count
    }

    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    // MARK: Querying

    /// First beat strictly after `time` (stream seconds), or nil when not locked.
    public func nextBeat(after time: Double) -> Beat? {
        guard isLocked else { return nil }
        // The epsilon keeps "next beat after this beat's own time" from returning it again.
        let k = Int(floor((time - anchorTime) / period + 1e-6)) + 1
        return beat(at: anchorIndex + k)
    }

    /// The beat at or before `time`, for showing the current count.
    public func currentBeat(at time: Double) -> Beat? {
        guard isLocked else { return nil }
        let k = Int(floor((time - anchorTime) / period))
        return beat(at: anchorIndex + k)
    }

    private func beat(at index: Int) -> Beat {
        let time = anchorTime + Double(index - anchorIndex) * period
        return Beat(index: index, time: time, count: count(for: index), countKnown: oneIsManual || evaluatedBeats >= 8, beatsSinceOne: index - oneIndex)
    }

    private func count(for index: Int) -> Int {
        cyc(index - oneIndex) + 1
    }

    // MARK: User corrections

    /// The user signalled "this is 1" at `time` (stream seconds). `reactionLag` is how late
    /// such a signal typically arrives after the beat it refers to.
    public func markOne(at time: Double, reactionLag: Double = 0.1) {
        guard isLocked else { return }
        let k = Int(((time - reactionLag - anchorTime) / period).rounded())
        onGridEvent?("markOne: beat \(anchorIndex + k) is 1 (was \(oneIndex))")
        oneIndex = anchorIndex + k
        oneIsManual = true
    }

    /// Shift the count: +1 makes every beat's number one higher.
    public func shiftCount(by delta: Int) {
        oneIndex -= delta
        oneIsManual = true
    }

    /// The grid sits on the "&" instead of the beat: move it by half a beat and keep it there.
    public func flipHalfBeat() {
        guard isLocked else { return }
        offBeatCorrection.toggle()
        anchorTime += period / 2
        if !oneIsManual { resetDownbeatStats() }
    }

    /// Forget the current song (tempo, phase and the "1") and listen afresh.
    public func relisten() {
        resetGrid()
    }

    // MARK: Onset history

    private func append(_ frame: OnsetFrame) {
        // Novelty = flux above its recent average, so sustained noise doesn't count as beats.
        recentFlux.append(frame.flux)
        recentFluxSum += frame.flux
        if recentFlux.count > 40 { recentFluxSum -= recentFlux.removeFirst() }
        let mean = recentFluxSum / Float(recentFlux.count)
        novelty.append(max(0, frame.flux - mean))
        lowNovelty.append(frame.lowFlux)
        chroma.append(frame.chroma)

        let keep = Int(10 * frameRate)
        if novelty.count > keep + Int(2 * frameRate) {
            let drop = novelty.count - keep
            novelty.removeFirst(drop)
            lowNovelty.removeFirst(drop)
            chroma.removeFirst(drop)
            baseFrame += drop
        }
    }

    /// Stream time of an absolute frame number (center of its analysis window).
    private func time(ofFrame frame: Double) -> Double {
        ((frame + 1) * Double(onset.hop) - Double(onset.fftSize) / 2) / sampleRate - Self.onsetLag
    }

    private func frame(ofTime t: Double) -> Double {
        (t + Self.onsetLag) * sampleRate / Double(onset.hop) + Double(onset.fftSize) / 2 / Double(onset.hop) - 1
    }

    private func noveltyAt(_ i: Double) -> Double {
        guard i >= 0 else { return 0 }
        let lo = Int(i)
        guard lo + 1 < novelty.count else { return lo < novelty.count ? Double(novelty[lo]) : 0 }
        let f = i - Double(lo)
        return Double(novelty[lo]) * (1 - f) + Double(novelty[lo + 1]) * f
    }

    // MARK: Tempo

    private func measureTempo() {
        let w = min(novelty.count, Int(8 * frameRate))
        guard w >= Int(3 * frameRate) else { return }
        var x = Array(novelty.suffix(w))
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(w))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(w))

        let range = style.tempoRange
        let maxLag = frameRate * 60 / range.lowerBound
        // Up to 4 periods: the multiples refine the tempo below one-frame resolution.
        let lagLimit = min(Int(4 * maxLag) + 4, w / 2)
        var ac = [Double](repeating: 0, count: lagLimit + 1)
        x.withUnsafeBufferPointer { p in
            for lag in 0...lagLimit {
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(w - lag))
                ac[lag] = Double(dot) / Double(w - lag)
            }
        }
        guard ac[0] > 1e-9 else { tempoMeasurement = nil; return }
        let ac0 = ac[0]
        for i in ac.indices { ac[i] /= ac0 }

        func acAt(_ lag: Double) -> Double {
            let lo = Int(lag)
            guard lo + 1 < ac.count else { return 0 }
            let f = lag - Double(lo)
            return max(0, ac[lo] * (1 - f) + ac[lo + 1] * f)
        }

        var best = (bpm: 0.0, score: -1.0)
        var scores: [(bpm: Double, score: Double)] = []
        var raw: [Double] = []
        for bpm in stride(from: range.lowerBound, through: range.upperBound, by: 0.25) {
            let lag = frameRate * 60 / bpm
            var s = acAt(lag)
            if 2 * lag < Double(lagLimit) { s += 0.5 * acAt(2 * lag) }
            raw.append(s)
            let octaves = log2(bpm / style.typicalBPM)
            s *= exp(-0.5 * pow(octaves / 0.45, 2))
            scores.append((bpm, s))
            if s > best.score { best = (bpm, s) }
        }
        // Parabolic refinement between grid neighbours.
        var bpm = best.bpm
        if let i = scores.firstIndex(where: { $0.bpm == best.bpm }), i > 0, i < scores.count - 1 {
            let (a, b, c) = (scores[i - 1].score, scores[i].score, scores[i + 1].score)
            let denom = a - 2 * b + c
            if denom < 0 { bpm += 0.25 * 0.5 * (a - c) / denom }
        }
        guard bpm > 0 else { tempoMeasurement = nil; return }
        // The grid search only resolves whole-frame lags (130.4 vs 127.7 BPM at 100 fps),
        // which is enough drift to slip a beat within ~20 s. Refine on the true peaks of the
        // autocorrelation at 1–4 periods: k periods measured in one go = k× the precision.
        var lag = frameRate * 60 / bpm
        for multiple in [1, 2, 4] {
            let target = lag * Double(multiple)
            let center = Int(target.rounded())
            let reach = multiple
            guard center - reach >= 1, center + reach + 1 < ac.count else { break }
            let i = (center - reach...center + reach).max { ac[$0] < ac[$1] }!
            guard i > center - reach, i < center + reach, ac[i] > 0 else { continue }
            let denom = ac[i - 1] - 2 * ac[i] + ac[i + 1]
            guard denom < 0 else { continue }
            let peak = Double(i) + 0.5 * (ac[i - 1] - ac[i + 1]) / denom
            let refined = peak / Double(multiple)
            if abs(refined - lag) / lag < 0.03 { lag = refined }
        }
        bpm = frameRate * 60 / lag
        let strength = acAt(frameRate * 60 / bpm)
        rhythmStrength = strength
        // Salience is judged before the tempo prior: with noise the prior alone would pick
        // a "steady" tempo near the typical BPM.
        let bestIndex = scores.firstIndex { $0.bpm == best.bpm } ?? 0
        let average = raw.reduce(0, +) / Double(raw.count)
        let sd = (raw.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(raw.count)).squareRoot()
        salience = sd > 0 ? (raw[bestIndex] - average) / sd : 0
        tempoMeasurement = (60 / bpm / tempoFactor, strength)
        freshMeasurement = true
    }

    // MARK: Phase

    /// Finds where the most recent beat falls for a given period, from the last ~4 s of onsets.
    private func measurePhase(periodSeconds: Double, window: Double = 4, memory: Double = 1.5) -> (time: Double, peakiness: Double)? {
        let p = periodSeconds * frameRate
        let n = novelty.count
        let w = min(n, Int(window * frameRate))
        guard w > Int(2 * p) else { return nil }
        let steps = Int(ceil(p * 2))
        var scores = [Double](repeating: 0, count: steps)
        for s in 0..<steps {
            let d = Double(s) * 0.5
            var total = 0.0
            var k = 0.0
            while d + k * p < Double(w - 1) {
                let back = d + k * p
                total += exp(-back / (memory * frameRate)) * noveltyAt(Double(n - 1) - back)
                k += 1
            }
            scores[s] = total
        }
        // Circular smoothing: beats are rarely exactly on a frame.
        var smooth = [Double](repeating: 0, count: steps)
        for s in 0..<steps {
            var acc = 0.0
            for o in -4...4 {
                acc += exp(-Double(o * o) / 18) * scores[((s + o) % steps + steps) % steps]
            }
            smooth[s] = acc
        }
        guard let bestS = smooth.indices.max(by: { smooth[$0] < smooth[$1] }), smooth[bestS] > 0 else { return nil }
        var d = Double(bestS) * 0.5
        let a = smooth[(bestS - 1 + steps) % steps], b = smooth[bestS], c = smooth[(bestS + 1) % steps]
        let denom = a - 2 * b + c
        if denom < 0 { d += 0.5 * 0.5 * (a - c) / denom }
        let mean = smooth.reduce(0, +) / Double(steps)
        let peakiness = (b - mean) / b
        let frame = Double(baseFrame + n - 1) - d
        return (time(ofFrame: frame), peakiness)
    }

    // MARK: Grid (phase-locked loop)

    private func updateGrid() {
        let now = streamTime
        guard let m = tempoMeasurement, m.strength >= minStrength else {
            weakSeconds += 0.1
            if isLocked && weakSeconds > 3 { lose(at: now) }
            return
        }
        weakSeconds = 0
        let fresh = freshMeasurement
        freshMeasurement = false
        if fresh {
            recentPeriods.append(m.period)
            if recentPeriods.count > 8 { recentPeriods.removeFirst() }
            // Music lines its onsets up on a grid; chatter doesn't, even at a "steady" tempo.
            let clarity = measurePhase(periodSeconds: m.period, window: 8, memory: 6)?.peakiness ?? 0
            clarityAverage += 0.25 * (clarity - clarityAverage)
            if isLocked && clarityAverage < 0.45 {
                unclearSeconds += 0.25
                if unclearSeconds > 3 { lose(at: now); return }
            } else {
                unclearSeconds = 0
            }
        }

        if !isLocked {
            // Music has a steady tempo; noise and chatter produce wandering estimates.
            guard fresh, recentPeriods.count >= 6 else { return }
            let median = recentPeriods.sorted()[recentPeriods.count / 2]
            guard agreement(with: median, tolerance: 0.03) >= 6, clarityAverage >= 0.6,
                  let phase = measurePhase(periodSeconds: median) else { return }
            lock(period: median, beatTime: phase.time, now: now)
            return
        }

        // Tempo: follow small drift, re-lock after a sustained different tempo (new song).
        // Recorded music keeps a steady tempo: follow slowly, and barely at all when the
        // rhythm is weak (quiet passages give poor tempo readings).
        // "Weak" is relative to this song's own strong parts: some styles (salsa) never have
        // a strong beat-level pulse, but a quiet passage drops well below the song's best.
        if fresh { strongestRhythm = max(m.strength, strongestRhythm * 0.995) }
        let confidence = min(1, m.strength / max(0.6 * strongestRhythm, 1e-6))
        let reliable = m.strength >= 0.5 * strongestRhythm && clarityAverage >= 0.7
        if fresh, reliable, abs(m.period - period) / period < 0.04 {
            period += 0.05 * confidence * (m.period - period)
        }
        if agreement(with: period, tolerance: 0.04) <= 2 {
            disagreeSeconds += 0.1
            if disagreeSeconds > 2 {
                lose(at: now)
                return
            }
        } else {
            disagreeSeconds = 0
        }

        // Phase: nudge the grid towards the measured beats, jump if persistently off.
        if let phase = measurePhase(periodSeconds: period), phase.peakiness > 0.15 {
            let measured = phase.time + (offBeatCorrection ? period / 2 : 0)
            let k = ((measured - anchorTime) / period).rounded()
            let predicted = anchorTime + k * period
            let err = measured - predicted
            if abs(err) < 0.2 * period {
                if m.strength >= 0.35 * strongestRhythm { anchorTime = predicted + 0.25 * confidence * err } else { anchorTime = predicted }
                anchorIndex += Int(k)
                phaseOffSeconds = 0
            } else if reliable && !(abs(err) > 0.3 * period && !halfBeatFlipIsClear()) {
                // Only trust a "we're off" reading while the beat is clear; through quiet
                // passages the grid just keeps going (like a dancer would). A half-beat flip
                // also needs long-term evidence that the "&" is really the stronger pulse.
                phaseOffSeconds += 0.1
                // Every shift is audible as a hiccup, so demand persistence — even more for
                // a half-beat flip, which is usually beat vs. off-beat ambiguity in the music.
                let halfBeatFlip = abs(err) > 0.3 * period
                if phaseOffSeconds > (halfBeatFlip ? 5 : 3) {
                    onGridEvent?(String(format: "%.2fs phase jump err %.3f k %.0f", now, err, k))
                    anchorTime = measured
                    anchorIndex += Int(k)
                    phaseOffSeconds = 0
                    // After a half-beat flip the old "1" statistics belong to the "&"s.
                    if !oneIsManual && abs(err) > 0.3 * period { resetDownbeatStats() }
                }
            }
        }
        evaluateDownbeats(now: now)
    }

    /// Beat vs. "&": in many songs (bachata güira, salsa montuno) the eighth notes are the
    /// strongest pulse and the two halves are nearly equal over a few seconds. Compare them over
    /// ~12 s, bass weighted in, and only allow the flip when the other half clearly wins and the
    /// user hasn't set the beat themselves.
    private func halfBeatFlipIsClear() -> Bool {
        guard !oneIsManual, !offBeatCorrection else { return false }
        return gridEvidence(shift: period / 2) > 1.25 * gridEvidence(shift: 0)
    }

    private func gridEvidence(shift: Double) -> Double {
        let n = novelty.count
        let window = min(Double(n) / frameRate, 12)
        guard window > 4 else { return 0 }
        let tail = novelty.suffix(Int(window * frameRate)), lowTail = lowNovelty.suffix(Int(window * frameRate))
        let meanNovelty = max(1e-6, Double(tail.reduce(0, +)) / Double(tail.count))
        let meanLow = max(1e-6, Double(lowTail.reduce(0, +)) / Double(lowTail.count))
        let now = time(ofFrame: Double(baseFrame + n - 1))
        var t = anchorTime + shift
        t -= ceil((t - (now - window)) / period) * period
        var total = 0.0
        while t < now - 0.05 {
            let f = Int(frame(ofTime: t).rounded()) - baseFrame
            if f - 2 >= 0, f + 2 < n {
                total += Double(novelty[(f - 2)...(f + 2)].max()!) / meanNovelty
                total += Double(lowNovelty[(f - 2)...(f + 2)].max()!) / meanLow
            }
            t += period
        }
        return total
    }

    private func lock(period newPeriod: Double, beatTime: Double, now: Double) {
        onGridEvent?(String(format: "%.2fs lock %.1f bpm", now, 60 / newPeriod))
        // Same song resuming after a short dropout: keep beat numbering and the "1".
        var beatTime = beatTime
        if let lostAt, now - lostAt < 4, abs(newPeriod - period) / period < 0.04 {
            if offBeatCorrection { beatTime += newPeriod / 2 }
            let k = ((beatTime - anchorTime) / period).rounded()
            anchorIndex += Int(k)
        } else {
            offBeatCorrection = false
            anchorIndex += 1000
            oneIndex = anchorIndex
            oneIsManual = false
            resetDownbeatStats()
        }
        period = newPeriod
        anchorTime = beatTime
        strongestRhythm = tempoMeasurement?.strength ?? 0
        isLocked = true
        lostAt = nil
        disagreeSeconds = 0
        phaseOffSeconds = 0
        lastEvaluatedIndex = anchorIndex
    }

    private func lose(at now: Double) {
        onGridEvent?(String(format: "%.2fs lost", now))
        isLocked = false
        lostAt = now
        recentPeriods.removeAll()
        disagreeSeconds = 0
    }

    private func agreement(with p: Double, tolerance: Double) -> Int {
        recentPeriods.filter { abs($0 - p) / p < tolerance }.count
    }

    private func resetGrid() {
        isLocked = false
        lostAt = nil
        recentPeriods.removeAll()
        tempoMeasurement = nil
        freshMeasurement = false
        oneIsManual = false
        offBeatCorrection = false
        resetDownbeatStats()
    }

    // MARK: Downbeat ("1") guess

    private func resetDownbeatStats() {
        downbeatScores = [Double](repeating: 0, count: style.countCycle)
        evaluatedBeats = 0
        candidateOne = nil
        candidateOneVotes = 0
    }

    /// Scores each finished beat for "1-ness" — bass hits and chord changes tend to land on 1 —
    /// and accumulates the score per 8-count position.
    private func evaluateDownbeats(now: Double) {
        let earliest = time(ofFrame: Double(baseFrame))
        while true {
            let index = max(lastEvaluatedIndex + 1, anchorIndex - 16)
            let t = anchorTime + Double(index - anchorIndex) * period
            guard t + 2 * period + 0.05 < now else { break }
            lastEvaluatedIndex = index
            guard t - 2 * period > earliest else { continue }

            let f = frame(ofTime: t) - Double(baseFrame)
            let p = period * frameRate
            let lo = max(0, Int(f) - 3), hi = min(novelty.count - 1, Int(f) + 3)
            guard lo <= hi else { continue }
            let low = Double(lowNovelty[lo...hi].max() ?? 0)
            let accent = Double(novelty[lo...hi].max() ?? 0)
            // Chords usually last at least two beats; comparing two-beat spans ignores
            // melody and walking-bass notes that change on every beat.
            let before = chromaSum(from: f - 2 * p, to: f)
            let after = chromaSum(from: f, to: f + 2 * p)
            let harmony = 1 - cosine(before, after)

            onDownbeatFeatures?(index, t, low, harmony, accent)
            // Running means (exact average while warming up, then ~20-beat memory).
            let rate = 1 / Double(min(evaluatedBeats + 1, 20))
            featureMeans.low += rate * (low - featureMeans.low)
            featureMeans.harmony += rate * (harmony - featureMeans.harmony)
            featureMeans.accent += rate * (accent - featureMeans.accent)
            // Overall loudness is deliberately left out: the loudest hit is usually the
            // snare backbeat on 2 and 4, which would pull the guess off the 1.
            let score = low / max(featureMeans.low, 1e-6)
                + harmony / max(featureMeans.harmony, 1e-6)

            for i in downbeatScores.indices { downbeatScores[i] *= 0.985 }
            downbeatScores[cyc(index)] += score
            evaluatedBeats += 1
            decideOne()
        }
    }

    private func decideOne() {
        guard !oneIsManual, evaluatedBeats >= 8, downbeatScores.count == style.countCycle else { return }
        let s = downbeatScores
        // Strongest bar position (1 and 5 together), then whichever of the two is stronger.
        // The count cycle is two bars (8 = 2×4, or 6 = 2×3 for waltzes).
        let b = style.beatsPerBar
        let bar = (0..<b).max { s[$0] + s[$0 + b] < s[$1] + s[$1 + b] }!
        let accent = s[bar] >= s[bar + b] ? bar : bar + b
        let position = cyc(accent + style.accentToOne)
        guard position != cyc(oneIndex) else { candidateOneVotes = 0; return }
        // A moving "1" is confusing: later changes need a clear lead, kept for 16 beats.
        let currentAccent = cyc(oneIndex - style.accentToOne)
        let clearLead = s[accent] > 1.2 * s[currentAccent]
        if candidateOne == position, clearLead { candidateOneVotes += 1 } else { candidateOne = position; candidateOneVotes = clearLead ? 1 : 0 }
        if evaluatedBeats == 8 || candidateOneVotes >= 16 {
            onGridEvent?("auto 1 moves by \(cyc(position - oneIndex)) beats")
            oneIndex += cyc(position - oneIndex)
            candidateOneVotes = 0
        }
    }

    /// Position within the count cycle (0-based).
    private func cyc(_ i: Int) -> Int {
        let n = style.countCycle
        return (i % n + n) % n
    }

    private func chromaSum(from a: Double, to b: Double) -> [Float] {
        var sum = [Float](repeating: 0, count: 12)
        let lo = max(0, Int(a)), hi = min(chroma.count, Int(b))
        guard lo < hi else { return sum }
        for i in lo..<hi { vDSP_vadd(sum, 1, chroma[i], 1, &sum, 1, 12) }
        return sum
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, 12)
        vDSP_svesq(a, 1, &na, 12)
        vDSP_svesq(b, 1, &nb, 12)
        guard na > 0, nb > 0 else { return 1 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }
}
