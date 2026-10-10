import AVFoundation

/// Keeps the last minute of what the mic heard, so a tricky song from a social can be saved
/// and replayed through `beatcli file` to tune the tracker.
struct ClipBuffer {
    let sampleRate: Double
    private var ring: [Float]
    private var write = 0
    private var filled = 0

    init(sampleRate: Double, seconds: Double = 60) {
        self.sampleRate = sampleRate
        ring = [Float](repeating: 0, count: Int(sampleRate * seconds))
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        for v in samples {
            ring[write] = v
            write = (write + 1) % ring.count
        }
        filled = min(ring.count, filled + samples.count)
    }

    var seconds: Double { Double(filled) / sampleRate }

    func snapshot() -> [Float] {
        guard filled == ring.count else { return Array(ring[0..<filled]) }
        return Array(ring[write...] + ring[..<write])
    }

    /// Writes a 16-bit WAV into Documents/Clips (visible in the Files app).
    static func save(_ samples: [Float], sampleRate: Double, name: String) throws -> URL {
        let folder = URL.documentsDirectory.appending(path: "Clips", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return url
    }
}
