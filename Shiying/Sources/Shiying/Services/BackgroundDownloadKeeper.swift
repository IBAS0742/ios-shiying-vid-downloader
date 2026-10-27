import AVFoundation
import UIKit

/// Keeps the process scheduled after the app moves to the background while
/// transfers are still in flight. A background `URLSession` keeps running on
/// its own, but TDLib downloads and YouTube resolution need the app process
/// itself, so a looping inaudible player plus a background task hold it until
/// the queue drains.
@MainActor
final class BackgroundDownloadKeeper {
    static let shared = BackgroundDownloadKeeper()

    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pollTask: Task<Void, Never>?
    private var hasWork: (() -> Bool)?

    private init() {}

    var isRunning: Bool { pollTask != nil }

    func start(hasWork: @escaping () -> Bool) {
        self.hasWork = hasWork
        guard !isRunning, hasWork() else { return }

        AppLog.info("background keeper started")
        beginBackgroundTask()
        startSilentLoop()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if self.hasWork?() != true {
                    self.stop(reason: "queue empty")
                    return
                }
            }
        }
    }

    func stop(reason: String) {
        guard isRunning || player != nil || backgroundTask != .invalid else { return }
        AppLog.info("background keeper stopped: \(reason)")
        pollTask?.cancel()
        pollTask = nil
        hasWork = nil
        player?.stop()
        player = nil
        endBackgroundTask()
    }

    private func startSilentLoop() {
        let session = AVAudioSession.sharedInstance()
        do {
            // A movie playing in picture-in-picture owns this category; keep it
            // so the keeper never downgrades long-form playback.
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silentLoopWAV())
            player.numberOfLoops = -1
            player.volume = 0.02
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            AppLog.error("background keeper audio failed: \(error.localizedDescription)")
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "shiying.background.downloads") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                AppLog.info("background keeper task expired")
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// One second of near-silent 8 kHz mono PCM, looped forever. It has to be
    /// actual audio playback for iOS to keep the process alive.
    private static func silentLoopWAV() -> Data {
        let sampleRate = 8_000
        let frameCount = sampleRate
        let bytesPerSample = 2
        let dataSize = frameCount * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(UInt32(sampleRate * bytesPerSample)))
        data.append(littleEndian(UInt16(bytesPerSample)))
        data.append(littleEndian(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian(UInt32(dataSize)))

        var samples = [Int16](repeating: 0, count: frameCount)
        for index in samples.indices {
            samples[index] = index.isMultiple(of: 2) ? 1 : -1
        }
        data.append(Data(bytes: samples, count: dataSize))
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
