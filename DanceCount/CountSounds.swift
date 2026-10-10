import AVFoundation
import BeatKit

/// Pre-rendered sounds for each count: short spoken numbers (system text-to-speech, rendered
/// once into buffers) or synthesized clicks. Everything is mono Float32 at `format`.
final class CountSounds {
    let format: AVAudioFormat
    /// Written once speech is rendered, read by the scheduler thread: guarded by `lock`.
    private var voice: [String: AVAudioPCMBuffer] = [:]
    private let lock = NSLock()
    private var clicks: [String: AVAudioPCMBuffer] = [:]
    /// One synthesizer per word, kept alive, so a slow word can't spill into the next one.
    private var synthesizers: [AVSpeechSynthesizer] = []

    init(sampleRate: Double = 48_000) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        clicks["1"] = Self.click(freq: 1760, length: 0.07, gain: 0.9, format: format)
        clicks["5"] = Self.click(freq: 1320, length: 0.06, gain: 0.7, format: format)
        clicks["beat"] = Self.click(freq: 880, length: 0.05, gain: 0.55, format: format)
        clicks["tap"] = Self.click(freq: 600, length: 0.03, gain: 0.5, format: format)
    }

    /// Neutral beat tick, used before the "1" is known.
    var tick: AVAudioPCMBuffer? { clicks["beat"] }

    var hasVoice: Bool { lock.withLock { voice.count >= Self.words.count } }

    /// Everything the voice can say. Step calls get more room than numbers.
    private static let words: [String: String] = [
        "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven", "8": "eight",
        "tap": "tap", "rock": "rock", "step": "step", "triple": "triple", "walk": "walk", "anchor": "anchor",
        "slow": "slow", "quick": "quick", "cha": "cha", "cha-cha": "cha cha",
    ]

    /// Renders all words once. Falls back to clicks if speech isn't available.
    func prepareVoice() async {
        guard !hasVoice else { return }
        var rendered: [String: AVAudioPCMBuffer] = [:]
        for (key, word) in Self.words {
            let maxLength = Int(key) == nil && key != "tap" ? 0.45 : 0.26
            if let buffer = await render(word, maxLength: maxLength) { rendered[key] = buffer }
        }
        guard rendered.count == Self.words.count else { return }
        for (key, buffer) in rendered.sorted(by: { $0.key < $1.key }) {
            log.notice("voice \(key, privacy: .public): \(Double(buffer.frameLength) / buffer.format.sampleRate) s")
        }
        lock.withLock { voice = rendered }
    }

    /// The sound for a call, or nil when the beat should stay silent.
    func buffer(for call: Call, sound: CountSound) -> AVAudioPCMBuffer? {
        if call.isTick { return tick }
        guard let word = call.word else { return nil }
        if sound == .voice, let buffer = lock.withLock({ voice[word] }) { return buffer }
        if word == "tap" { return clicks["tap"] }
        if call.position == 1 { return clicks["1"] }
        return clicks[call.isHalfway ? "5" : "beat"]
    }

    // MARK: Speech

    private func render(_ word: String, maxLength: Double) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.6
        utterance.prefersAssistiveTechnologySettings = false

        // write() ends with an empty buffer; the timeout guards against it never coming.
        let chunks: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            let box = SpeechCollector(continuation)
            let synthesizer = AVSpeechSynthesizer()
            synthesizers.append(synthesizer)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { box.finish(); return }
                box.append(pcm)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { box.finish() }
        }
        guard let first = chunks.first else { return nil }
        var samples: [Float] = []
        for chunk in chunks { samples += Self.monoFloats(chunk) }
        samples = Self.resample(samples, from: first.format.sampleRate, to: format.sampleRate)
        return Self.trimmedBuffer(samples, format: format, maxLength: maxLength)
    }

    private static func monoFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength)
        if let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: n))
        }
        if let data = buffer.int16ChannelData {
            return (0..<n).map { Float(data[0][$0]) / 32768 }
        }
        if let data = buffer.int32ChannelData {
            return (0..<n).map { Float(data[0][$0]) / 2_147_483_648 }
        }
        return []
    }

    private static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !x.isEmpty else { return x }
        let ratio = from / to
        let n = Int(Double(x.count) / ratio)
        return (0..<n).map { i in
            let pos = Double(i) * ratio
            let lo = Int(pos)
            let f = Float(pos - Double(lo))
            return lo + 1 < x.count ? x[lo] * (1 - f) + x[lo + 1] * f : x[min(lo, x.count - 1)]
        }
    }

    /// Cuts leading/trailing silence so the word starts exactly on the beat, caps the length
    /// (numbers must fit fast salsa, ~0.27 s per beat) and normalizes the level.
    private static func trimmedBuffer(_ x: [Float], format: AVAudioFormat, maxLength: Double) -> AVAudioPCMBuffer? {
        let peak = x.map(abs).max() ?? 0
        guard peak > 0 else { return nil }
        let threshold = peak * 0.04
        guard let start = x.firstIndex(where: { abs($0) > threshold }),
              let end = x.lastIndex(where: { abs($0) > threshold }) else { return nil }
        let sr = format.sampleRate
        var y = Array(x[start...end].prefix(Int(maxLength * sr)))
        let fadeIn = Int(0.003 * sr), fadeOut = min(Int(0.04 * sr), y.count / 2)
        for i in 0..<min(fadeIn, y.count) { y[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { y[y.count - 1 - i] *= Float(i) / Float(fadeOut) }
        let gain = 0.9 / peak
        return makeBuffer(y.map { $0 * gain }, format: format)
    }

    // MARK: Clicks

    private static func click(freq: Double, length: Double, gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let n = Int(length * sr)
        let samples = (0..<n).map { i -> Float in
            let t = Double(i) / sr
            let env = min(1, t / 0.001) * exp(-t / (length / 4))
            return gain * Float(env * (sin(2 * .pi * freq * t) + 0.3 * sin(4 * .pi * freq * t)))
        }
        return makeBuffer(samples, format: format)!
    }

    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// Collects speech buffers and resumes the waiting task exactly once.
private final class SpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if continuation != nil { buffers.append(buffer) }
    }

    func finish() {
        lock.lock()
        let c = continuation
        continuation = nil
        let result = buffers
        lock.unlock()
        c?.resume(returning: result)
    }
}
