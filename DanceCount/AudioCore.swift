import AVFoundation
import BeatKit
import os

let log = Logger(subsystem: "com.raikoevestus.DanceCount", category: "audio")

/// What the UI shows about the audio side.
struct CoreStatus: Equatable {
    var running = false
    var locked = false
    var bpm: Double?
    var oneIsManual = false
    var offBeat = false
    var tempoFactor: Double = 1
    var inputLevel: Float = 0
    var clarity: Double = 0
    var micName = ""
    var outputName = ""
}

/// Owns the audio session, the engine (mic tap + count players), the beat tracker and the
/// scheduler that plays each count ahead of time so it lands on the beat in the ear.
///
/// All tracker and scheduling state lives on `queue`.
final class AudioCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dancecount.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var timer: DispatchSourceTimer?
    private let sounds = CountSounds()

    private var tracker: BeatTracker?
    private var settings = CountSettings()
    private var tempoFactor: Double = 1
    private var clip: ClipBuffer?

    /// Host-clock seconds at which stream time 0 was captured.
    private var hostOffset: Double?
    private var inputLatency: Double = 0
    private var outputLatency: Double = 0
    private var lastScheduledBeat = -Double.infinity
    private var level: Float = 0
    private var micName = ""
    private var outputName = ""
    private var observers: [NSObjectProtocol] = []
    private var demoFeed: DemoFeed?
    private var startedAt: Double = 0
    private var lastAutosave = 0
    private var load: (dsp: Double, clip: Double, audio: Double) = (0, 0, 0)
    private var restartPending = false

    /// Called on the main queue at the moment a beat is heard.
    var onBeat: ((Call) -> Void)?
    /// Called on the main queue a few times per second.
    var onStatus: ((CoreStatus) -> Void)?
    /// Called on the main queue when audio stops unexpectedly.
    var onError: ((String) -> Void)?

    init() {
        // The speech synthesizer expects the main thread.
        Task { @MainActor [sounds] in await sounds.prepareVoice() }
    }

    // MARK: Start / stop

    func start(settings: CountSettings, demo: String? = nil) throws {
        log.notice("start mic=\(settings.mic.rawValue, privacy: .public) style=\(settings.style.rawValue, privacy: .public)")
        stop()
        queue.sync {
            self.settings = settings
            self.tempoFactor = 1
        }
        let session = AVAudioSession.sharedInstance()
        if demo == nil {
            try Self.configureSession(mic: settings.mic)
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        }

        let engine = AVAudioEngine()
        var players: [AVAudioPlayerNode] = []
        for _ in 0..<4 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: sounds.format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = demo == nil ? Float(settings.volume) : 0

        let sampleRate: Double
        if let demo {
            let feed = DemoFeed(style: demo)
            sampleRate = feed.sampleRate
            demoFeed = feed
        } else {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw NSError(domain: "DanceCount", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available. Check microphone access in Settings."])
            }
            sampleRate = format.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
                self?.receive(buffer, at: when)
            }
        }

        log.notice("engine input format \(sampleRate) Hz; session \(session.category.rawValue, privacy: .public) \(session.mode.rawValue, privacy: .public) hw \(session.sampleRate) Hz in-lat \(session.inputLatency) out-lat \(session.outputLatency)")
        engine.prepare()
        try engine.start()
        log.notice("engine started")
        players.forEach { $0.play() }

        queue.sync {
            self.engine = engine
            self.players = players
            let tracker = BeatTracker(sampleRate: sampleRate, style: settings.style)
            tracker.onGridEvent = { log.notice("grid: \($0, privacy: .public)") }
            self.tracker = tracker
            self.clip = ClipBuffer(sampleRate: sampleRate)
            self.hostOffset = nil
            self.lastScheduledBeat = -.infinity
            self.inputLatency = demo == nil ? session.inputLatency : 0
            self.outputLatency = session.outputLatency + session.ioBufferDuration
            self.describeRoute()
        }
        startedAt = Self.now()
        observe(engine: engine)
        startTimer()
        demoFeed?.start { [weak self] samples, hostTime in
            samples.withUnsafeBufferPointer { self?.consume($0, hostTime: hostTime) }
        }
    }

    func stop() {
        log.notice("stop")
        demoFeed?.stop()
        demoFeed = nil
        timer?.cancel()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue.sync {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            players = []
            tracker = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.onStatus?(CoreStatus()) }
    }

    /// Applies settings that don't need a restart (style, sound, volume, timing).
    func update(settings: CountSettings) {
        queue.async {
            if self.tracker?.style != settings.style { self.tracker?.style = settings.style; self.tempoFactor = 1 }
            self.settings = settings
            if self.demoFeed == nil { self.engine?.mainMixerNode.outputVolume = Float(settings.volume) }
        }
    }

    // MARK: Corrections

    /// "This is 1", from a screen tap or AirPods press at host time `hostTime`.
    func markOne(hostTime: Double, reactionLag: Double) {
        queue.async {
            guard let t = self.streamTime(forHearing: hostTime) else { return }
            self.tracker?.markOne(at: t, reactionLag: reactionLag)
            self.pushStatus()
        }
    }

    func shiftCount(by delta: Int) {
        queue.async { self.tracker?.shiftCount(by: delta); self.pushStatus() }
    }

    func flipHalfBeat() {
        queue.async { self.tracker?.flipHalfBeat(); self.pushStatus() }
    }

    func relisten() {
        queue.async { self.tracker?.relisten(); self.tempoFactor = 1; self.tracker?.tempoFactor = 1; self.pushStatus() }
    }

    /// Multiplies the counting speed (2 = it was counting half speed).
    func scaleTempo(by factor: Double) {
        queue.async {
            self.tempoFactor = min(2, max(0.5, self.tempoFactor * factor))
            self.tracker?.tempoFactor = self.tempoFactor
            self.pushStatus()
        }
    }

    /// Saves the last minute of mic audio. Calls back on main with the file URL.
    func saveClip(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard let clip = self.clip, clip.seconds > 1 else {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "DanceCount", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nothing recorded yet."]))) }
                return
            }
            let samples = clip.snapshot()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "\(formatter.string(from: .now)) \(self.settings.style.rawValue) \(self.settings.mic.rawValue)"
            let rate = clip.sampleRate
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ClipBuffer.save(samples, sampleRate: rate, name: name) }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    // MARK: Input

    private func receive(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            for i in 0..<n { mono[i] += data[c][i] }
        }
        if channels > 1 { for i in 0..<n { mono[i] /= Float(channels) } }
        let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : Self.now()
        mono.withUnsafeBufferPointer { consume($0, hostTime: host) }
    }

    /// Feeds samples captured starting at `hostTime` (host-clock seconds).
    private func consume(_ samples: UnsafeBufferPointer<Float>, hostTime: Double) {
        let copy = Array(samples)
        queue.async {
            guard let tracker = self.tracker else { return }
            // Keep the stream↔host mapping; re-anchor on jumps (route changes, dropped buffers).
            let expected = hostTime - tracker.streamTime
            if let offset = self.hostOffset, abs(expected - offset) < 0.05 {
                self.hostOffset = offset + 0.05 * (expected - offset)
            } else {
                self.hostOffset = expected
            }
            let t0 = Self.now()
            copy.withUnsafeBufferPointer { tracker.process($0) }
            let t1 = Self.now()
            copy.withUnsafeBufferPointer { self.clip?.append($0) }
            let t2 = Self.now()
            self.load.dsp += t1 - t0
            self.load.clip += t2 - t1
            self.load.audio += Double(copy.count) / tracker.sampleRate
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-autosave"), let clip = self.clip, Int(clip.seconds) % 30 == 0, clip.seconds >= 30, self.lastAutosave != Int(clip.seconds) {
                self.lastAutosave = Int(clip.seconds)
                let samples = clip.snapshot(), rate = clip.sampleRate
                DispatchQueue.global().async { _ = try? ClipBuffer.save(samples, sampleRate: rate, name: "autosave") }
            }
            #endif
            if self.load.audio >= 5 {
                log.notice("load: tracker \(Int(100 * self.load.dsp / self.load.audio))% clip \(Int(100 * self.load.clip / self.load.audio))% of real time, backlog \(t2 - hostTime) s")
                self.load = (0, 0, 0)
            }
            var peak: Float = 0
            for v in copy { peak = max(peak, abs(v)) }
            self.level = max(peak, self.level * 0.9)
        }
    }

    // MARK: Scheduling

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        var ticks = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleBeats()
            ticks += 1
            if ticks % 10 == 0 { self.pushStatus() }
        }
        t.resume()
        timer = t
    }

    /// Host time at which a stream-time moment reaches the listener's ears through the counts.
    private func playTime(forBeat beatTime: Double) -> Double? {
        guard let hostOffset else { return nil }
        // Sound happened at (capture time − input latency); the count must leave the player
        // `outputLatency` before that to be heard on time.
        return beatTime + hostOffset - inputLatency - outputLatency + settings.timingOffsetMs / 1000
    }

    private func streamTime(forHearing hostTime: Double) -> Double? {
        guard let hostOffset else { return nil }
        return hostTime - hostOffset + inputLatency
    }

    private func scheduleBeats() {
        guard let tracker, tracker.isLocked, let hostOffset else { return }
        let now = Self.now()
        let lookahead = 0.12
        // The earliest beat we can still play on time.
        let earliest = now + 0.005 - hostOffset + inputLatency + outputLatency - settings.timingOffsetMs / 1000
        var from = max(earliest, lastScheduledBeat + 0.5 * tracker.period)
        while let beat = tracker.nextBeat(after: from), let at = playTime(forBeat: beat.time), at - now <= lookahead {
            // Step half a beat past it: asking for "the beat after this beat" can return the
            // same beat again through floating-point rounding.
            from = beat.time + 0.5 * tracker.period
            lastScheduledBeat = beat.time
            guard at > now else { continue }
            #if DEBUG
            log.notice("beat #\(beat.index) count \(beat.countKnown ? beat.count : 0) t \(beat.time) at +\(at - now) s, bpm \(60 / tracker.period)")
            #endif
            // Until the "1" is known, Call plays plain ticks rather than numbers that would shift.
            let call = Call.make(for: (beat.count, beat.countKnown, beat.beatsSinceOne), settings: settings)
            let sound = sounds.buffer(for: call, sound: settings.sound)
            if let buffer = sound,
               !players.isEmpty {
                let player = players[nextPlayer % players.count]
                nextPlayer += 1
                player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: at)))
            }
            let heard = at + outputLatency
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, heard - now)) { [weak self] in
                self?.onBeat?(call)
            }
        }
    }

    private func pushStatus() {
        guard let tracker else { return }
        let status = CoreStatus(running: true, locked: tracker.isLocked, bpm: tracker.bpm,
                                oneIsManual: tracker.oneIsManual, offBeat: tracker.offBeatCorrection,
                                tempoFactor: tempoFactor, inputLevel: level, clarity: tracker.beatClarity,
                                micName: micName, outputName: outputName)
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    // MARK: Session & route

    static func configureSession(mic: MicSource) throws {
        let session = AVAudioSession.sharedInstance()
        switch mic {
        case .iPhone:
            // Measurement mode turns off voice processing and gain control on the built-in mic.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        case .airPods:
            // Best first: full-bandwidth AirPods recording + far-field (room) pickup, then
            // full-bandwidth only, then classic hands-free mic.
            var attempts: [AVAudioSession.CategoryOptions] = []
            if #available(iOS 26.2, *) { attempts.append([.allowBluetoothHFP, .bluetoothHighQualityRecording, .farFieldInput]) }
            if #available(iOS 26.0, *) { attempts.append([.allowBluetoothHFP, .bluetoothHighQualityRecording]) }
            attempts.append([.allowBluetoothHFP])
            var lastError: Error?
            for options in attempts {
                do {
                    try session.setCategory(.playAndRecord, mode: .default, options: options.union(.defaultToSpeaker))
                    try session.setActive(true)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
            if let headset = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(headset)
            }
        }
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
    }

    private func describeRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let input = route.inputs.first {
            var name = input.portType == .builtInMic ? "iPhone mic" : input.portName
            if #available(iOS 26.0, *), let bt = input.bluetoothMicrophoneExtension {
                var extras: [String] = []
                if bt.highQualityRecording.isEnabled { extras.append("full quality") }
                if #available(iOS 26.2, *), bt.farFieldCapture.isEnabled { extras.append("room pickup") }
                if !extras.isEmpty { name += " (\(extras.joined(separator: ", ")))" }
            }
            micName = name
        } else {
            micName = demoFeed == nil ? "No mic" : "Demo music"
        }
        outputName = route.outputs.first.map { $0.portType == .builtInSpeaker ? "iPhone speaker" : $0.portName } ?? ""
    }

    private func observe(engine: AVAudioEngine) {
        let center = NotificationCenter.default
        // AirPods connecting/disconnecting changes the engine's formats: rebuild everything.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            log.notice("engine configuration change")
            self?.restart()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            log.notice("interruption \(String(describing: note.userInfo), privacy: .public)")
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            log.notice("route change \(String(describing: note.userInfo?[AVAudioSessionRouteChangeReasonKey]), privacy: .public) → \(AVAudioSession.sharedInstance().currentRoute.description, privacy: .public)")
            self?.queue.async {
                self?.describeRoute()
                let session = AVAudioSession.sharedInstance()
                self?.inputLatency = session.inputLatency
                self?.outputLatency = session.outputLatency + session.ioBufferDuration
            }
        })
    }

    private func restart() {
        guard demoFeed == nil, engine != nil, !restartPending else { return }
        // Starting reconfigures the session, which can itself fire a change: coalesce.
        let sinceStart = Self.now() - startedAt
        if sinceStart < 1 {
            restartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 - sinceStart) {
                self.restartPending = false
                self.restart()
            }
            return
        }
        let settings = queue.sync { self.settings }
        do {
            try start(settings: settings)
        } catch {
            log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            stop()
            onError?(error.localizedDescription)
        }
    }
}

/// DEBUG/simulator: plays generated music into the tracker in real time instead of the mic.
final class DemoFeed: @unchecked Sendable {
    let sampleRate = 48_000.0
    private let song: SyntheticSong
    private var timer: DispatchSourceTimer?

    init(style: String) {
        let groove = SyntheticSong.Groove(rawValue: style) ?? .salsa
        let bpm: Double = switch groove {
        case .salsa: 186
        case .bachata: 128
        case .swing: 150
        case .pop: 120
        case .waltz: 87
        }
        var options = SyntheticSong.Options(bpm: bpm, groove: groove)
        options.seconds = 120
        song = SyntheticSong.make(options)
    }

    func start(_ deliver: @escaping ([Float], Double) -> Void) {
        let chunk = 1024
        var offset = 0
        let startHost = AudioCore.now()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dancecount.demo"))
        t.schedule(deadline: .now(), repeating: .milliseconds(5))
        t.setEventHandler { [song, sampleRate] in
            // Deliver everything that "has been recorded" by now.
            let due = Int((AudioCore.now() - startHost) * sampleRate)
            while offset + chunk <= min(due, song.samples.count) {
                deliver(Array(song.samples[offset..<(offset + chunk)]), startHost + Double(offset) / sampleRate)
                offset += chunk
            }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
