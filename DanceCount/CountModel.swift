import AVFoundation
import BeatKit
import MediaPlayer
import Observation
import UIKit

/// UI-facing state and actions. Wires AirPods presses and lock-screen controls to the core.
@MainActor @Observable
final class CountModel {
    var settings = CountSettings.load() {
        didSet {
            settings.save()
            if settings.mic != oldValue.mic, status.running { restart() } else { core.update(settings: settings) }
        }
    }
    private(set) var status = CoreStatus()
    private(set) var call: Call?
    private(set) var errorMessage: String?
    private(set) var lastClip: URL?
    private(set) var clipMessage: String?

    private let core = AudioCore()
    private var lastRemotePress: TimeInterval = 0
    private let demo: String?

    init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        demo = args.firstIndex(of: "-demo").map { args.indices.contains($0 + 1) ? args[$0 + 1] : "salsa" }
        if let i = args.firstIndex(of: "-style"), args.indices.contains(i + 1), let style = DanceStyle(rawValue: args[i + 1]) {
            settings.style = style
        }
        #else
        demo = nil
        #endif
        core.onStatus = { [weak self] in self?.status = $0 }
        core.onBeat = { [weak self] call in
            guard let self else { return }
            self.call = call
        }
        core.onError = { [weak self] in self?.errorMessage = $0 }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in log.notice("app → background") }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in log.notice("app → foreground") }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in log.notice("app will terminate") }
        setUpRemoteControls()
        if demo != nil || args.contains("-autostart") { start() }
        #if DEBUG
        watchMainThread()
        #endif
    }

    // MARK: Actions

    func start() {
        errorMessage = nil
        Task {
            if demo == nil {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else {
                    errorMessage = "Dance Count needs the microphone to hear the music. Allow it in Settings › Privacy › Microphone."
                    return
                }
            }
            do {
                try core.start(settings: settings, demo: demo)
                updateNowPlaying()
            } catch {
                log.error("start failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        core.stop()
        call = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggle() { status.running ? stop() : start() }

    private func restart() {
        stop()
        start()
    }

    /// Screen tap: people tap close to the beat, so assume little delay.
    func markOneFromScreen() {
        core.markOne(hostTime: AudioCore.now(), reactionLag: 0.06)
    }

    func shiftCount(_ delta: Int) { core.shiftCount(by: delta) }
    func flipHalfBeat() { core.flipHalfBeat() }
    func relisten() { core.relisten(); call = nil }
    func faster() { core.scaleTempo(by: 2) }
    func slower() { core.scaleTempo(by: 0.5) }

    func saveClip() {
        clipMessage = "Saving…"
        core.saveClip { [weak self] result in
            switch result {
            case .success(let url):
                self?.lastClip = url
                self?.clipMessage = "Saved \(url.lastPathComponent)"
            case .failure(let error):
                self?.clipMessage = error.localizedDescription
            }
        }
    }

    #if DEBUG
    /// Logs when the main thread stalls (UI feels slow).
    private func watchMainThread() {
        var last = AudioCore.now()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let now = AudioCore.now()
            if now - last > 0.4 { log.notice("main thread stalled \(now - last - 0.25) s") }
            last = now
        }
    }
    #endif

    // MARK: AirPods & lock screen

    /// Squeezing an AirPods stem arrives as play/pause (or, while the AirPods mic is in use,
    /// as an input-mute toggle). Both mean "this is 1". Double squeeze = start over.
    private func setUpRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            command.addTarget { [weak self] event in
                log.notice("remote command \(event.command.description, privacy: .public)")
                self?.remoteOne()
                return .success
            }
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.relisten()
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.flipHalfBeat()
            return .success
        }

        NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main) { [weak self] note in
            log.notice("input mute change \(String(describing: note.userInfo), privacy: .public)")
            guard (note.userInfo?[AVAudioApplication.muteStateKey] as? Bool) == true else { return }
            MainActor.assumeIsolated {
                self?.remoteOne()
                // We need the mic: undo the mute right away.
                try? AVAudioApplication.shared.setInputMuted(false)
            }
        }
    }

    private func remoteOne() {
        log.notice("remote press")
        let now = AudioCore.now()
        // Play/pause and mute can both fire for one press.
        guard now - lastRemotePress > 0.4, status.running else { return }
        lastRemotePress = now
        // Bluetooth button presses arrive ~0.2 s late.
        core.markOne(hostTime: now, reactionLag: 0.22)
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Counting \(settings.style.name)",
            MPMediaItemPropertyArtist: "Dance Count — squeeze AirPods on the 1",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }
}
