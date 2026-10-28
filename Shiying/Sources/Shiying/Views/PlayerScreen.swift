import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isPlaying = false
    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPPossible = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoSizeText = "—"
    @Published private(set) var itemStatusText = "等待中"
    @Published private(set) var timeControlText = "—"
    @Published private(set) var waitingReasonText = "—"
    @Published private(set) var bufferText = "—"
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var isBoosting = false

    let playerLayer = AVPlayerLayer()
    let isDebugHUDEnabled = ProcessInfo.processInfo.environment["SHIYING_PLAYER_DEBUG"] == "1"

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var pipObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var pipController: AVPictureInPictureController?
    private let pipDelegate = PiPDelegate()

    private var startedHandler: (() -> Void)?
    private var finishedHandler: (() -> Void)?
    private var didReportStart = false
    private var didReportFinish = false
    private var fallbackDuration: Double = 0
    private var baseRate: Float = 1
    private var lastTickLog = Date.distantPast
    private var loadGeneration = 0
    private let seekNearEndOnFirstLoad = ProcessInfo.processInfo.environment["SHIYING_TEST_SEEK_END"] == "1"
    private var didSeekNearEnd = false
    private let startPiPOnPossible = ProcessInfo.processInfo.environment["SHIYING_TEST_PIP"] == "1"
    private var didAutoStartPiP = false
    private var seekGeneration = 0
    private var pendingSeekTarget: Double?
    private weak var observedItem: AVPlayerItem?

    var debugSummary: String {
        let time = String(format: "%.2f", currentTime)
        let total = String(format: "%.1f", duration)
        let pip = isPiPActive ? "active" : (isPiPPossible ? "ready" : "no")
        return """
        item=\(itemStatusText) tcs=\(timeControlText)
        rate=\(String(format: "%.2f", player?.rate ?? 0)) t=\(time)/\(total)
        wait=\(waitingReasonText) buf=\(bufferText)
        video=\(videoSizeText) pip=\(pip)
        error=\(player?.currentItem?.error?.localizedDescription ?? "nil")
        """
    }

    func load(item: VideoItem, resumeAt: Double, onStarted: @escaping () -> Void, onFinished: @escaping () -> Void) async {
        invalidatePendingLoad()
        let generation = loadGeneration
        startedHandler = onStarted
        finishedHandler = onFinished
        didReportStart = false
        didReportFinish = false
        fallbackDuration = item.duration
        currentTime = 0
        duration = item.duration
        isLoading = true
        errorMessage = nil

        AppLog.info("player load start title=\(item.title) video=\(item.videoFileURL.path) audio=\(item.audioFileURL.path)")
        AppLog.info("player files video=\(fileSize(item.videoFileURL)) audio=\(fileSize(item.audioFileURL)) separateAudio=\(item.hasSeparateAudio)")

        do {
            let asset = try await PlaybackAssetBuilder.makeAsset(for: item)
            guard generation == loadGeneration else {
                AppLog.info("player load cancelled after asset build")
                return
            }
            let assetDuration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard generation == loadGeneration else {
                AppLog.info("player load cancelled after track load")
                return
            }

            var size = CGSize.zero
            if let track = videoTracks.first {
                size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                AppLog.info("player video track size=\(Int(size.width))x\(Int(size.height)) transform=\(transform)")
            }

            guard generation == loadGeneration else { return }
            guard !videoTracks.isEmpty else {
                throw PlaybackError.noVideoTrack
            }

            let seconds = assetDuration.seconds
            duration = seconds.isFinite && seconds > 0 ? seconds : item.duration
            videoSizeText = "\(Int(size.width))x\(Int(size.height))"
            AppLog.info("player asset ready duration=\(String(format: "%.2f", duration)) videoTracks=\(videoTracks.count) audioTracks=\(audioTracks.count)")

            let playerItem = AVPlayerItem(asset: asset)
            playerItem.preferredForwardBufferDuration = 5
            playerItem.audioTimePitchAlgorithm = .spectral

            guard generation == loadGeneration else {
                AppLog.info("player load cancelled before player start")
                return
            }

            if let player {
                AppLog.info("player reuse existing AVPlayer for next item")
                player.pause()
                player.replaceCurrentItem(with: playerItem)
                installItemObservers(on: playerItem)
                updateNowPlaying(item: item)
                isLoading = false
                player.defaultRate = playbackRate
                player.play()
                resume(player, at: resumeAt)
                seekNearEndIfRequested(player)
                AppLog.info("player.play() called after item swap rate=\(String(format: "%.2f", playbackRate))")
                return
            }

            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = true
            player.defaultRate = playbackRate
            self.player = player

            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = UIColor.black.cgColor

            activateAudioSession()
            configurePiP()
            installPlayerObservers(on: player)
            installItemObservers(on: playerItem)
            updateNowPlaying(item: item)

            UIApplication.shared.beginReceivingRemoteControlEvents()
            isLoading = false
            player.play()
            resume(player, at: resumeAt)
            seekNearEndIfRequested(player)
            AppLog.info("player.play() called")
        } catch {
            guard generation == loadGeneration else {
                AppLog.info("player load cancelled after error")
                return
            }
            AppLog.error("player load failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func invalidatePendingLoad() {
        loadGeneration += 1
        seekGeneration += 1
        pendingSeekTarget = nil
        observedItem = nil
    }

    func stop() {
        AppLog.info("player stop")
        invalidatePendingLoad()
        teardownPlayer()
        startedHandler = nil
        finishedHandler = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func prepareForNextItem() {
        invalidatePendingLoad()
        AppLog.info("player prepare for next item")
        removeItemObservers()
        player?.pause()
        didReportStart = false
        didReportFinish = false
        errorMessage = nil
        isLoading = true
        isPlaying = false
        isBoosting = false
        playbackRate = baseRate
        currentTime = 0
        duration = 0
        videoSizeText = "—"
        itemStatusText = "等待中"
        timeControlText = "—"
        waitingReasonText = "—"
        bufferText = "—"
    }

    private func teardownPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        removeItemObservers()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        pipObservations.forEach { $0.invalidate() }
        pipObservations.removeAll()
        pipController?.delegate = nil
        pipController = nil
        player?.pause()
        playerLayer.player = nil
        player = nil
    }

    func play() {
        guard let player else { return }
        if duration > 0, currentTime >= duration - 0.8 {
            AppLog.info("player replay from start")
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        AppLog.info("player play tapped")
        player.defaultRate = playbackRate
        player.play()
    }

    private func resume(_ player: AVPlayer, at seconds: Double) {
        guard seconds > 0.5, seconds < duration - 0.8 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func seekNearEndIfRequested(_ player: AVPlayer) {
        guard seekNearEndOnFirstLoad, !didSeekNearEnd, duration > 8 else { return }
        didSeekNearEnd = true
        let target = max(duration - 4, 0)
        AppLog.info("test seek near end target=\(String(format: "%.1f", target))")
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = target
    }

    func pause() {
        guard let player else { return }
        AppLog.info("player pause tapped")
        player.pause()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            pause()
        } else {
            play()
        }
    }

    // MARK: - Speed

    /// Applies the speed configured in global settings. A temporary long-press
    /// boost is preserved on top of the new base rate.
    func setBaseRate(_ rate: Double) {
        baseRate = min(max(Float(rate), 0.5), 4)
        guard !isBoosting else { return }
        applyRate(baseRate)
    }

    /// Long-press boost: add 0.5x until the user releases the screen.
    func beginBoost() {
        guard !isBoosting else { return }
        isBoosting = true
        applyRate(min(baseRate + 0.5, 4.5))
    }

    func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        applyRate(baseRate)
    }

    private func applyRate(_ rate: Float) {
        playbackRate = rate
        guard let player else { return }
        player.defaultRate = rate
        if player.timeControlStatus != .paused {
            player.rate = rate
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        guard let player, let item = observedItem,
              player.currentItem === item, !isLoading else { return }
        let target = min(max(seconds, 0), max(duration, 0))
        seekGeneration += 1
        let generation = seekGeneration
        pendingSeekTarget = target
        currentTime = target
        AppLog.info("player seek to \(String(format: "%.1f", target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self, weak player, weak item] finished in
            Task { @MainActor in
                guard let self, let player, let item,
                      self.seekGeneration == generation,
                      self.player === player, self.observedItem === item,
                      player.currentItem === item else { return }
                self.pendingSeekTarget = nil
                let actualTime = item.currentTime().seconds
                if finished {
                    self.currentTime = target
                } else if actualTime.isFinite {
                    self.currentTime = max(0, actualTime)
                }
            }
        }
    }

    func togglePiP() {
        guard let pipController else {
            AppLog.error("pip controller missing")
            return
        }
        AppLog.info("pip toggle active=\(pipController.isPictureInPictureActive) possible=\(pipController.isPictureInPicturePossible)")
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - Setup

    private func installPlayerObservers(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player else { return }
            MainActor.assumeIsolated {
                self.handleTick(player: player)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus.rawValue
            let reason = player.reasonForWaitingToPlay?.rawValue
            Task { @MainActor in
                self?.handleTimeControl(status: status, reason: reason)
            }
        }
    }

    private func removeItemObservers() {
        observedItem = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

    private func installItemObservers(on playerItem: AVPlayerItem) {
        removeItemObservers()
        observedItem = playerItem
        let generation = loadGeneration

        itemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status.rawValue
            let errorText = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.loadGeneration == generation else { return }
                self.handleItemStatus(status: status, errorText: errorText)
            }
        }

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let text = error?.localizedDescription ?? "unknown"
            AppLog.error("player item failed to end: \(text)")
            Task { @MainActor in
                guard let self, self.loadGeneration == generation else { return }
                self.errorMessage = text
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { note in
            guard let item = note.object as? AVPlayerItem,
                  let event = item.errorLog()?.events.last else { return }
            AppLog.error("player error log: \(event.errorComment ?? "no comment") status=\(event.errorStatusCode) domain=\(event.errorDomain)")
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.loadGeneration == generation else { return }
                AppLog.info("player reached end")
                self.isPlaying = false
                guard !self.didReportFinish else { return }
                self.didReportFinish = true
                self.finishedHandler?()
            }
        })
    }

    private func configurePiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            AppLog.error("pip not supported on this device")
            return
        }

        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            AppLog.error("pip controller init returned nil")
            return
        }
        controller.delegate = pipDelegate
        pipDelegate.owner = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        AppLog.info("pip controller created autoInline=\(controller.canStartPictureInPictureAutomaticallyFromInline)")

        pipObservations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in
                guard let self else { return }
                self.isPiPPossible = possible
                AppLog.info("pip possible=\(possible)")
                if possible, self.startPiPOnPossible, !self.didAutoStartPiP {
                    self.didAutoStartPiP = true
                    try? await Task.sleep(for: .milliseconds(800))
                    AppLog.info("test auto start pip")
                    self.togglePiP()
                }
            }
        })

        pipObservations.append(controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] controller, _ in
            let active = controller.isPictureInPictureActive
            Task { @MainActor in
                self?.isPiPActive = active
                AppLog.info("pip active=\(active)")
            }
        })
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
            AppLog.info("audio session active category=\(session.category.rawValue)")
        } catch {
            AppLog.error("audio session failed: \(error.localizedDescription)")
        }
    }

    private func updateNowPlaying(item: VideoItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
        ]
        if !item.channel.isEmpty {
            info[MPMediaItemPropertyArtist] = item.channel
        }
        if item.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = item.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - State

    private func handleItemStatus(status: Int, errorText: String?) {
        let value = AVPlayerItem.Status(rawValue: status) ?? .unknown
        switch value {
        case .unknown:
            itemStatusText = "unknown"
        case .readyToPlay:
            itemStatusText = "ready"
        case .failed:
            itemStatusText = "failed"
        @unknown default:
            itemStatusText = "other"
        }

        AppLog.info("player item status=\(itemStatusText) error=\(errorText ?? "nil")")

        if value == .failed, let errorText {
            errorMessage = errorText
        }
        if value == .readyToPlay {
            if let player, player.timeControlStatus != .playing {
                player.play()
                AppLog.info("player re-play after ready")
            }
        }
    }

    private func handleTimeControl(status: Int, reason: String?) {
        let value = AVPlayer.TimeControlStatus(rawValue: status) ?? .paused
        switch value {
        case .paused:
            timeControlText = "paused"
            isPlaying = false
        case .waitingToPlayAtSpecifiedRate:
            timeControlText = "waiting"
            isPlaying = false
        case .playing:
            timeControlText = "playing"
            isPlaying = true
        @unknown default:
            timeControlText = "other"
            isPlaying = false
        }
        waitingReasonText = reason ?? "nil"
        AppLog.info("player timeControl=\(timeControlText) reason=\(waitingReasonText) rate=\(String(format: "%.2f", player?.rate ?? 0))")
    }

    private func handleTick(player: AVPlayer) {
        guard self.player === player, !isLoading,
              let item = observedItem, player.currentItem === item else { return }
        // The periodic callback's time can belong to the item replaced on this player.
        let seconds = item.currentTime().seconds
        if seconds.isFinite, pendingSeekTarget == nil {
            currentTime = max(0, seconds)
        }

        let itemDuration = player.currentItem?.duration.seconds ?? 0
        if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        } else if duration <= 0 {
            duration = fallbackDuration
        }

        if let item = player.currentItem {
            bufferText = "\(item.isPlaybackLikelyToKeepUp ? "ok" : "low")/\(item.isPlaybackBufferEmpty ? "empty" : "fill")"
            let size = item.presentationSize
            if size != .zero {
                videoSizeText = "\(Int(size.width))x\(Int(size.height))"
            }
        }

        if !didReportStart, player.timeControlStatus == .playing, player.rate > 0 {
            didReportStart = true
            AppLog.info("playback started at \(String(format: "%.2f", seconds))s")
            startedHandler?()
        }

        if isDebugHUDEnabled, Date().timeIntervalSince(lastTickLog) > 3 {
            lastTickLog = Date()
            AppLog.info("player tick t=\(String(format: "%.1f", currentTime))/\(String(format: "%.1f", duration)) tcs=\(timeControlText) rate=\(String(format: "%.2f", player.rate)) wait=\(waitingReasonText)")
        }
    }

    private func fileSize(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return "missing"
        }
        return "\(size.int64Value) bytes"
    }

    fileprivate func pipDidStart() {
        AppLog.info("pip did start")
        isPiPActive = true
    }

    fileprivate func pipDidStop() {
        AppLog.info("pip did stop")
        isPiPActive = false
    }

    fileprivate func pipDidFail(_ error: Error) {
        AppLog.error("pip failed: \(error.localizedDescription)")
        isPiPActive = false
    }
}

private final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var owner: PlayerViewModel?

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak owner] in
            owner?.pipDidStart()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak owner] in
            owner?.pipDidStop()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak owner] in
            owner?.pipDidFail(error)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        AppLog.info("pip restore requested")
        completionHandler(true)
    }
}

final class PlayerLayerHostView: UIView {
    var playerLayer: AVPlayerLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let playerLayer {
                layer.addSublayer(playerLayer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerSurfaceView: UIViewRepresentable {
    let playerLayer: AVPlayerLayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer = playerLayer
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        if uiView.playerLayer !== playerLayer {
            uiView.playerLayer = playerLayer
        }
    }
}

struct PlayerScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: PlaybackSession
    @ObservedObject private var model: PlayerViewModel

    @State private var currentItem: VideoItem
    @State private var isAdvancing = false
    @State private var lastSavedPosition = 0.0
    @State private var isActive = true
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var isPressingVideo = false
    @State private var boostStartTask: Task<Void, Never>?

    init(item: VideoItem, store: AppStore, session: PlaybackSession) {
        self.store = store
        self.session = session
        self._model = ObservedObject(wrappedValue: session.model)
        _currentItem = State(initialValue: item)
    }

    private var queue: [VideoItem] {
        session.request?.queue ?? []
    }

    private var displayItem: VideoItem {
        store.items.first(where: { $0.id == currentItem.id }) ?? currentItem
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.player != nil {
                PlayerSurfaceView(playerLayer: model.playerLayer)
                    .ignoresSafeArea()
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleControls()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in handleVideoPressChanged() }
                        .onEnded { _ in handleVideoPressEnded() }
                )

            if model.isLoading {
                loadingOverlay
            }

            if let errorMessage = model.errorMessage {
                errorOverlay(message: errorMessage)
            }

            controls

            if model.isBoosting {
                boostHUD
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            if model.isDebugHUDEnabled {
                debugHUD
            }
        }
        .background(Color.black)
        .task {
            AppLog.info("player queue count=\(queue.count) start=\(currentItem.title)")
            model.setBaseRate(store.playbackRate)
            await startPlayback(currentItem)
            if let delay = ProcessInfo.processInfo.environment["SHIYING_TEST_BOOST"].flatMap(Double.init) {
                AppLog.info("test boost scheduled in \(delay)s")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    handleVideoPressChanged()
                    try? await Task.sleep(for: .seconds(1.2))
                    handleVideoPressEnded()
                }
            }
            if let delay = ProcessInfo.processInfo.environment["SHIYING_TEST_MINIMIZE"].flatMap(Double.init) {
                AppLog.info("test minimize scheduled in \(delay)s")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard isActive else { return }
                    session.minimize()
                }
            }
            if ProcessInfo.processInfo.environment["SHIYING_TEST_LANDSCAPE"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard isActive else { return }
                    AppLog.info("test switch to landscape")
                    toggleOrientation()
                }
            }
            if let delay = ProcessInfo.processInfo.environment["SHIYING_TEST_PAUSE"].flatMap(Double.init) {
                AppLog.info("test pause scheduled in \(delay)s")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard isActive else { return }
                    model.togglePlayPause()
                }
            }
        }
        .onAppear {
            isActive = true
            updateIdleTimer(minimized: session.isMinimized)
            showControls()
        }
        .onChange(of: store.playbackRate) { _, rate in
            model.setBaseRate(rate)
        }
        .onChange(of: session.isMinimized) { _, minimized in
            updateIdleTimer(minimized: minimized)
            if !minimized {
                showControls()
            }
        }
        .onChange(of: session.request?.id) { _, _ in
            guard let request = session.request else { return }
            currentItem = request.item
            isAdvancing = false
            model.prepareForNextItem()
            showControls()
            Task { await startPlayback(request.item) }
        }
        .onChange(of: model.isPiPActive) { _, active in
            if active {
                cancelLongPressBoost()
            }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing {
                scheduleHide()
            } else {
                hideTask?.cancel()
                controlsVisible = true
            }
        }
        .onDisappear {
            savePlaybackPositionIfNeeded()
            isActive = false
            hideTask?.cancel()
            cancelLongPressBoost()
            UIApplication.shared.isIdleTimerDisabled = false
            model.stop()
        }
        .statusBarHidden(!session.isMinimized)
        .persistentSystemOverlays(session.isMinimized ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.16), value: model.isBoosting)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Palette.amber)
                .scaleEffect(1.35)
            Text("正在准备播放…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            if model.isDebugHUDEnabled {
                Text(model.itemStatusText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.85))
            }
        }
        .padding(26)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var boostHUD: some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("\(rateText(model.playbackRate)) 加速中")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.62)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .padding(.top, 72)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.coral)
            Text("无法播放")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            Button("关闭") { session.close() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.background)
                .padding(.horizontal, 24)
                .padding(.vertical, 11)
                .background(Capsule().fill(Palette.amber))
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(30)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if !model.isPlaying, !model.isLoading, model.errorMessage == nil {
                Button {
                    model.togglePlayPause()
                    showControls()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(.black.opacity(0.48)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.bottom, 18)
            }
            bottomBar
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                hideTask?.cancel()
                AppLog.info("player minimized")
                session.minimize()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("最小化播放")

            VStack(alignment: .leading, spacing: 2) {
                Text(displayItem.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(displayItem.isTrashed ? "已在废纸篓 · \(displayItem.deletionText)" : "自动连播 · 支持画中画")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 8)

            Button {
                toggleOrientation()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("切换横屏")

            Button {
                model.togglePiP()
                showControls()
            } label: {
                Image(systemName: model.isPiPActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(model.isPiPPossible || model.isPiPActive ? .white : .white.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!model.isPiPPossible && !model.isPiPActive)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.78), .black.opacity(0.32), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text(timeText(isScrubbing ? scrubTarget : model.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { min(max(isScrubbing ? scrubTarget : model.currentTime, 0), max(model.duration, 1)) },
                        set: {
                            isScrubbing = true
                            scrubTarget = $0
                        }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            hideTask?.cancel()
                        } else {
                            isScrubbing = false
                            model.seek(to: scrubTarget)
                            showControls()
                        }
                    }
                )
                .tint(Palette.amber)

                Text(timeText(model.duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 30) {
                Button {
                    model.skip(by: -10)
                    showControls()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    model.togglePlayPause()
                    showControls()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(.black.opacity(0.48)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    model.skip(by: 10)
                    showControls()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.45), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var debugHUD: some View {
        VStack {
            Spacer()
            HStack {
                Text(model.debugSummary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.leading)
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.green.opacity(0.5), lineWidth: 1)
                    )
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 140)
        }
        .allowsHitTesting(false)
    }

    private func startPlayback(_ item: VideoItem) async {
        guard isActive else { return }
        await model.load(item: item, resumeAt: displayItem.playbackPosition) {
        } onFinished: {
            handlePlaybackFinished()
        }
    }

    private func handlePlaybackFinished() {
        store.savePlaybackPosition(itemID: currentItem.id, position: model.duration)
        guard isActive else { return }
        guard !isAdvancing else { return }
        guard let next = nextPlayableItem else {
            AppLog.info("autoplay: no next playable item")
            showControls()
            return
        }

        AppLog.info("autoplay next id=\(next.id) title=\(next.title)")
        isAdvancing = true
        currentItem = next
        session.updateCurrentItem(next)
        model.prepareForNextItem()
        showControls()
        Task {
            await startPlayback(next)
            isAdvancing = false
        }
    }

    private var nextPlayableItem: VideoItem? {
        let currentID = currentItem.id
        guard let index = queue.firstIndex(where: { $0.id == currentID }) else {
            return nil
        }
        for candidate in queue.dropFirst(index + 1) {
            if let playable = playableItem(for: candidate) {
                return playable
            }
        }
        return nil
    }

    private func playableItem(for candidate: VideoItem) -> VideoItem? {
        if let fresh = store.items.first(where: { $0.id == candidate.id }) {
            return fresh.isPlayable && !fresh.isTrashed && fresh.source == currentItem.source ? fresh : nil
        }
        return nil
    }

    private func savePlaybackPositionIfNeeded() {
        guard model.currentTime > 0.5 else { return }
        store.savePlaybackPosition(itemID: currentItem.id, position: model.currentTime)
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    private func toggleOrientation() {
        OrientationController.shared.toggle()
        showControls()
    }

    private func updateIdleTimer(minimized: Bool) {
        let forced = ProcessInfo.processInfo.environment["SHIYING_KEEP_AWAKE"] == "1"
        UIApplication.shared.isIdleTimerDisabled = forced || !minimized
    }

    private func handleVideoPressChanged() {
        guard !isPressingVideo else { return }
        isPressingVideo = true
        guard model.isPlaying, !model.isPiPActive else { return }

        boostStartTask?.cancel()
        boostStartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, isPressingVideo, !model.isPiPActive else { return }
            model.beginBoost()
            AppLog.info("player boost start rate=\(rateText(model.playbackRate))")
        }
    }

    private func handleVideoPressEnded() {
        cancelLongPressBoost()
    }

    private func cancelLongPressBoost() {
        isPressingVideo = false
        boostStartTask?.cancel()
        boostStartTask = nil
        guard model.isBoosting else { return }
        model.endBoost()
        AppLog.info("player boost end rate=\(rateText(model.playbackRate))")
    }

    private func rateText(_ rate: Float) -> String {
        String(format: "%g×", Double(rate))
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying, !model.isDebugHUDEnabled else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !isScrubbing {
                    controlsVisible = false
                }
            }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
