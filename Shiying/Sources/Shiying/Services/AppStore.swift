import AVFoundation
import Foundation
import UIKit

enum ImportFeedback {
    case success(count: Int)
    case duplicate
    case invalid(String)
}

@MainActor
final class AppStore: ObservableObject {
    enum AddResult {
        case added(VideoItem)
        case duplicate(VideoItem)
        case invalid
    }

    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published var toast: ToastMessage?
    @Published var importActivity: String?
    @Published var downloadQuality: DownloadQuality = .best {
        didSet {
            UserDefaults.standard.set(downloadQuality.rawValue, forKey: Self.downloadQualityKey)
        }
    }
    @Published var youtubePageTitle: String = "" {
        didSet {
            UserDefaults.standard.set(youtubePageTitle, forKey: Self.youtubePageTitleKey)
        }
    }
    @Published var telegramPageTitle: String = "" {
        didSet {
            UserDefaults.standard.set(telegramPageTitle, forKey: Self.telegramPageTitleKey)
        }
    }
    @Published var autoReadClipboard: Bool = true {
        didSet {
            UserDefaults.standard.set(autoReadClipboard, forKey: Self.autoReadClipboardKey)
        }
    }
    @Published var maxConcurrentDownloads: Int = 2 {
        didSet {
            UserDefaults.standard.set(maxConcurrentDownloads, forKey: Self.maxConcurrentDownloadsKey)
            pumpDownloadQueue()
        }
    }
    /// Number of parallel range connections used for YouTube media files.
    @Published var youtubeSegments: Int = 4 {
        didSet {
            UserDefaults.standard.set(youtubeSegments, forKey: Self.youtubeSegmentsKey)
        }
    }
    /// Baseline playback speed used whenever a video starts. Holding the video
    /// in the built-in player temporarily adds 0.5x on top of this value.
    @Published var playbackRate: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: Self.playbackRateKey)
        }
    }
    /// Moves watched YouTube videos to the trash by default. Users can keep
    /// them in the playlist independently from Telegram videos.
    @Published var autoDeleteYouTubeAfterPlayback: Bool = true {
        didSet {
            UserDefaults.standard.set(
                autoDeleteYouTubeAfterPlayback,
                forKey: Self.autoDeleteYouTubeKey
            )
        }
    }
    /// Moves watched Telegram videos to the trash by default.
    @Published var autoDeleteTelegramAfterPlayback: Bool = true {
        didSet {
            UserDefaults.standard.set(
                autoDeleteTelegramAfterPlayback,
                forKey: Self.autoDeleteTelegramKey
            )
        }
    }
    /// Telegram chats pinned by the user. They are shown above the rest of the
    /// list every time the Telegram browser loads.
    @Published private(set) var pinnedTelegramChatIDs: Set<Int64> = []
    @Published private(set) var downloadsPaused = false
    @Published private(set) var downloadSpeeds: [UUID: Double] = [:]

    nonisolated static let trashRetentionDays = 7
    nonisolated static let maxAutoRetries = 5
    nonisolated static let retryDelaySeconds = 10
    nonisolated static let playbackRateOptions: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4]
    private static let downloadQualityKey = "shiying.downloadQuality"
    private static let youtubePageTitleKey = "shiying.youtubePageTitle"
    private static let telegramPageTitleKey = "shiying.telegramPageTitle"
    private static let autoReadClipboardKey = "shiying.autoReadClipboard"
    private static let maxConcurrentDownloadsKey = "shiying.maxConcurrentDownloads"
    private static let youtubeSegmentsKey = "shiying.youtubeSegments"
    private static let playbackRateKey = "shiying.playbackRate"
    private static let autoDeleteYouTubeKey = "shiying.autoDeleteYouTubeAfterPlayback"
    private static let autoDeleteTelegramKey = "shiying.autoDeleteTelegramAfterPlayback"
    private static let pinnedTelegramChatsKey = "shiying.pinnedTelegramChatIDs"

    private struct SpeedSample {
        let date: Date
        let bytes: Int64
        let bytesPerSecond: Double
    }

    private var kindProgress: [UUID: [String: Double]] = [:]
    private var speedSamples: [UUID: [String: SpeedSample]] = [:]
    private var isRecovering = false
    private var toastTask: Task<Void, Never>?
    private var housekeepingTimer: Timer?
    private var speedTimer: Timer?
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var resolveTasks: [UUID: Task<Void, Never>] = [:]

    func pageTitle(for source: MediaSource) -> String {
        let customTitle: String
        switch source {
        case .youtube:
            customTitle = youtubePageTitle
        case .telegram:
            customTitle = telegramPageTitle
        }
        return customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? source.title
            : customTitle
    }

    var playlist: [VideoItem] {
        items.filter { !$0.isTrashed }.sorted(by: Self.playlistOrder)
    }

    /// Manually reordered items keep their saved positions. Items that have not
    /// been placed yet (for example a freshly downloaded video) stay on top in
    /// newest-first order, matching the previous behavior.
    private static func playlistOrder(_ lhs: VideoItem, _ rhs: VideoItem) -> Bool {
        switch (lhs.manualOrder, rhs.manualOrder) {
        case let (left?, right?):
            if left != right { return left < right }
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.none, .none):
            break
        }
        return lhs.addedAt > rhs.addedAt
    }

    var downloadsGroup: [VideoItem] {
        items.filter { item in
            !item.isTrashed && (item.status == .queued || item.status == .resolving
                || item.status == .downloading || item.status == .retrying || item.status == .failed)
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    var queuedCount: Int {
        items.filter { !$0.isTrashed && $0.status == .queued }.count
    }

    /// Whether any download still needs to make progress, including items
    /// waiting for a free slot or an automatic retry.
    var hasActiveDownloadWork: Bool {
        guard !downloadsPaused else { return false }
        return items.contains {
            !$0.isTrashed && ($0.status == .queued || $0.status == .resolving
                || $0.status == .downloading || $0.status == .retrying)
        }
    }

    func playbackQueue(for item: VideoItem) -> [VideoItem] {
        playlist.filter { $0.source == item.source && $0.isPlayable }
    }

    /// Whether watched videos of this source should move to the trash.
    func autoDeletesAfterPlayback(for source: MediaSource) -> Bool {
        switch source {
        case .youtube:
            return autoDeleteYouTubeAfterPlayback
        case .telegram:
            return autoDeleteTelegramAfterPlayback
        }
    }

    func isTelegramChatPinned(_ chatID: Int64) -> Bool {
        pinnedTelegramChatIDs.contains(chatID)
    }

    func toggleTelegramChatPin(_ chatID: Int64) {
        var updated = pinnedTelegramChatIDs
        if updated.contains(chatID) {
            updated.remove(chatID)
        } else {
            updated.insert(chatID)
        }
        pinnedTelegramChatIDs = updated
        UserDefaults.standard.set(
            updated.map(String.init),
            forKey: Self.pinnedTelegramChatsKey
        )
        AppLog.info("telegram pin toggled chat=\(chatID) pinned=\(updated.contains(chatID))")
    }

    /// Saves a new manual order for the ready videos of one source. Videos that
    /// are still downloading are cleared so they appear on top once ready.
    func reorderPlaylist(source: MediaSource, orderedIDs: [UUID]) {
        var positions: [UUID: Int] = [:]
        for (position, id) in orderedIDs.enumerated() {
            positions[id] = position
        }

        for index in items.indices where items[index].source == source && !items[index].isTrashed {
            if items[index].status == .ready, let position = positions[items[index].id] {
                items[index].manualOrder = position
            } else {
                items[index].manualOrder = nil
            }
        }

        save()
        AppLog.info("playlist reordered source=\(source.rawValue) count=\(orderedIDs.count)")
    }

    var trash: [VideoItem] {
        items.filter(\.isTrashed).sorted {
            ($0.deleteAfter ?? .distantFuture) < ($1.deleteAfter ?? .distantFuture)
        }
    }

    init() {
        AppPaths.prepare()

        let defaults = UserDefaults.standard
        youtubePageTitle = defaults.string(forKey: Self.youtubePageTitleKey) ?? ""
        telegramPageTitle = defaults.string(forKey: Self.telegramPageTitleKey) ?? ""
        if let raw = defaults.string(forKey: Self.downloadQualityKey),
           let savedQuality = DownloadQuality(rawValue: raw) {
            downloadQuality = savedQuality
        }
        if let savedClipboard = defaults.object(forKey: Self.autoReadClipboardKey) as? Bool {
            autoReadClipboard = savedClipboard
        }
        let savedConcurrent = defaults.integer(forKey: Self.maxConcurrentDownloadsKey)
        maxConcurrentDownloads = (1...4).contains(savedConcurrent) ? savedConcurrent : 2
        let savedSegments = defaults.integer(forKey: Self.youtubeSegmentsKey)
        youtubeSegments = [1, 4, 8].contains(savedSegments) ? savedSegments : 4
        let savedRate = defaults.double(forKey: Self.playbackRateKey)
        playbackRate = Self.playbackRateOptions.contains(savedRate) ? savedRate : 1.0
        if let savedAutoDelete = defaults.object(forKey: Self.autoDeleteYouTubeKey) as? Bool {
            autoDeleteYouTubeAfterPlayback = savedAutoDelete
        }
        if let savedAutoDelete = defaults.object(forKey: Self.autoDeleteTelegramKey) as? Bool {
            autoDeleteTelegramAfterPlayback = savedAutoDelete
        }
        if let pinned = defaults.stringArray(forKey: Self.pinnedTelegramChatsKey) {
            pinnedTelegramChatIDs = Set(pinned.compactMap(Int64.init))
        }

        load()

        DownloadManager.shared.progressHandler = { [weak self] id, kind, value, bytes in
            self?.receiveProgress(id: id, kind: kind, value: value, bytes: bytes)
        }
        DownloadManager.shared.fileHandler = { [weak self] id, kind in
            self?.receiveFile(id: id, kind: kind)
        }
        DownloadManager.shared.errorHandler = { [weak self] id, kind, message in
            self?.receiveDownloadError(id: id, kind: kind, message: message)
        }

        purgeExpired(notify: false)
        startHousekeepingTimer()
        startSpeedTimer()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            await self?.recoverDownloads()
            self?.pumpDownloadQueue()
        }
    }

    deinit {
        housekeepingTimer?.invalidate()
        speedTimer?.invalidate()
        toastTask?.cancel()
        for task in retryTasks.values {
            task.cancel()
        }
    }

    // MARK: - Adding

    @discardableResult
    func addYouTubeLink(_ rawText: String, sharedTitle: String? = nil) -> AddResult {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        var candidate = YouTubeLink.extractURL(from: trimmed)
        if candidate == nil {
            let withScheme = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            candidate = URL(string: withScheme)
        }

        guard let candidateURL = candidate,
              let videoID = YouTubeLink.videoID(from: candidateURL) else {
            toast = ToastMessage(text: "没有识别到有效的 YouTube 链接", icon: "link.badge.plus")
            AppLog.info("add invalid link: \(trimmed.prefix(120))")
            return .invalid
        }

        AppLog.info("add request videoID=\(videoID)")

        if let existing = items.first(where: { $0.videoID == videoID }) {
            let message: String
            if existing.isTrashed {
                message = "这个视频已在废纸篓，已跳过重复下载"
            } else if existing.status == .downloading || existing.status == .resolving || existing.status == .retrying {
                message = "这个视频已经在下载队列中"
            } else if existing.status == .failed {
                message = "这个视频已在片库中，点按可重试"
            } else {
                message = "这个视频已经在片库中"
            }
            AppLog.info("duplicate skipped videoID=\(videoID) status=\(existing.status.rawValue)")
            showToast(text: message, icon: "checkmark.circle")
            return .duplicate(existing)
        }

        let fallbackTitle = cleanedSharedTitle(sharedTitle) ?? "YouTube 视频"
        let item = VideoItem(
            videoID: videoID,
            sourceURL: YouTubeLink.canonicalURL(videoID: videoID).absoluteString,
            title: fallbackTitle
        )

        items.insert(item, at: 0)
        save()
        AppPaths.createDirectory(for: item.id)

        showToast(text: "已加入下载队列", icon: "arrow.down.circle.fill")
        NotificationService.requestAuthorizationIfNeeded()

        pumpDownloadQueue()
        return .added(item)
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "shiyin" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        guard components.host == "add" || components.path == "/add" else { return }

        let rawLink = components.queryItems?.first(where: { $0.name == "url" })?.value
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value
        guard let rawLink, !rawLink.isEmpty else {
            showToast(text: "分享内容里没有可识别的链接", icon: "exclamationmark.triangle")
            return
        }
        Task { [weak self] in
            _ = await self?.importInput(rawLink, sharedTitle: title)
        }
    }

    func importFromPasteboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            toast = ToastMessage(text: "剪贴板里没有链接", icon: "doc.on.clipboard")
            return
        }
        Task { [weak self] in
            _ = await self?.importInput(text)
        }
    }

    /// Handles single videos, YouTube playlists, Telegram public posts/channels,
    /// and text that contains several of those links.
    func importInput(_ rawText: String, sharedTitle: String? = nil) async -> ImportFeedback {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("请输入链接")
        }

        let urls = LinkExtractor.urls(in: trimmed)
        guard !urls.isEmpty else {
            return .invalid("没有识别到 YouTube 或 Telegram 链接")
        }

        var addedCount = 0
        var handledCount = 0
        var sawDuplicate = false
        var lastError: String?

        for url in urls.prefix(6) {
            if let playlistID = YouTubeLink.playlistIDForImport(from: url) {
                handledCount += 1
                switch await importYouTubePlaylist(playlistID: playlistID) {
                case .success(let count):
                    addedCount += count
                case .duplicate:
                    sawDuplicate = true
                case .invalid(let message):
                    lastError = message
                }
            } else if let videoID = YouTubeLink.videoID(from: url) {
                handledCount += 1
                AppLog.info("single youtube import videoID=\(videoID)")
                switch addYouTubeLink(url.absoluteString, sharedTitle: urls.count == 1 ? sharedTitle : nil) {
                case .added:
                    addedCount += 1
                case .duplicate:
                    sawDuplicate = true
                case .invalid:
                    lastError = "没有识别到有效的 YouTube 链接"
                }
            } else if let telegramLink = TelegramLink.parse(url) {
                handledCount += 1
                switch await importTelegram(link: telegramLink) {
                case .success(let count):
                    addedCount += count
                case .duplicate:
                    sawDuplicate = true
                case .invalid(let message):
                    lastError = message
                }
            }
        }

        if handledCount == 0 {
            return .invalid("目前支持 YouTube 视频/播放列表和 Telegram 公开频道/帖子")
        }
        if addedCount > 0 {
            return .success(count: addedCount)
        }
        if let lastError {
            return .invalid(lastError)
        }
        if sawDuplicate {
            return .duplicate
        }
        return .invalid("没有可导入的视频")
    }

    private func importYouTubePlaylist(playlistID: String) async -> ImportFeedback {
        importActivity = "正在读取 YouTube 播放列表…"
        defer { importActivity = nil }

        do {
            let batch = try await YouTubePlaylistService.fetch(playlistID: playlistID)
            let baseDate = Date()
            var added = 0
            var skipped = 0

            for (index, entry) in batch.entries.enumerated() {
                if items.contains(where: { $0.videoID == entry.videoID }) {
                    skipped += 1
                    continue
                }

                let item = VideoItem(
                    videoID: entry.videoID,
                    sourceURL: YouTubeLink.canonicalURL(videoID: entry.videoID).absoluteString,
                    title: entry.title.isEmpty ? "YouTube 视频" : entry.title,
                    channel: entry.channel,
                    duration: entry.duration,
                    addedAt: baseDate.addingTimeInterval(-Double(index)),
                    source: .youtube,
                    remoteThumbnailURL: entry.thumbnailURL?.absoluteString
                )
                items.append(item)
                AppPaths.createDirectory(for: item.id)
                added += 1
            }

            save()
            pumpDownloadQueue()

            guard added > 0 else {
                showToast(
                    text: skipped > 0 ? "播放列表里的视频都已经在片库中" : "播放列表里没有视频",
                    icon: "checkmark.circle"
                )
                return .duplicate
            }

            NotificationService.requestAuthorizationIfNeeded()
            let truncation = batch.truncated ? "（列表较长，只导入前 \(batch.entries.count) 个）" : ""
            showToast(
                text: "已从「\(batch.title)」加入 \(added) 个视频\(truncation)",
                icon: "text.badge.plus"
            )
            AppLog.info("playlist imported title=\(batch.title) added=\(added) skipped=\(skipped)")
            return .success(count: added)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("playlist import failed: \(message)")
            showToast(text: message, icon: "exclamationmark.triangle.fill")
            return .invalid(message)
        }
    }

    private func importTelegram(link: TelegramLink) async -> ImportFeedback {
        importActivity = "正在读取 Telegram 内容…"
        defer { importActivity = nil }

        do {
            let batch = try await TelegramService.fetch(link: link)
            let baseDate = Date()
            var added = 0
            var skipped = 0

            for (index, video) in batch.videos.enumerated() {
                if items.contains(where: { $0.videoID == video.itemKey }) {
                    skipped += 1
                    continue
                }

                let item = VideoItem(
                    videoID: video.itemKey,
                    sourceURL: "https://t.me/\(video.username)/\(video.postID)",
                    title: video.title.isEmpty ? "\(batch.title) 视频" : video.title,
                    channel: video.channelTitle,
                    duration: 0,
                    addedAt: baseDate.addingTimeInterval(-Double(index)),
                    source: .telegram,
                    directMediaURL: video.mediaURL.absoluteString,
                    remoteThumbnailURL: video.thumbnailURL?.absoluteString
                )
                items.append(item)
                AppPaths.createDirectory(for: item.id)
                added += 1
            }

            save()
            pumpDownloadQueue()

            guard added > 0 else {
                showToast(
                    text: skipped > 0 ? "这些 Telegram 视频都已经在片库中" : "没有找到可下载的视频",
                    icon: "checkmark.circle"
                )
                return .duplicate
            }

            NotificationService.requestAuthorizationIfNeeded()
            showToast(text: "已导入 \(added) 个 Telegram 视频", icon: "paperplane.fill")
            AppLog.info("telegram imported channel=\(batch.title) added=\(added) skipped=\(skipped)")
            return .success(count: added)
        } catch {
            if let tgError = error as? TelegramServiceError, case .mediaTooLarge = tgError {
                if !TelegramSession.shared.phase.isReady, TelegramCredentials.isConfigured {
                    TelegramSession.shared.bootstrap()
                    _ = await waitForTelegramReady(timeout: 8)
                }
                if TelegramSession.shared.phase.isReady {
                    return await importTelegramViaTDLib(link: link)
                }
                let message = "这条视频超过网页预览的 20MB 上限。请先在「设置 → Telegram 登录」扫码登录，再导入一次"
                AppLog.error("telegram import failed: \(message)")
                showToast(text: message, icon: "exclamationmark.triangle.fill")
                return .invalid(message)
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("telegram import failed: \(message)")
            showToast(text: message, icon: "exclamationmark.triangle.fill")
            return .invalid(message)
        }
    }

    /// Reads the post/channel through the logged-in TDLib session, which can see
    /// videos larger than the public web preview limit.
    private func importTelegramViaTDLib(link: TelegramLink) async -> ImportFeedback {
        importActivity = "正在通过 Telegram 读取大视频…"
        defer { importActivity = nil }

        do {
            let videos = try await TelegramSession.shared.fetchVideos(link: link)
            let baseDate = Date()
            var added = 0
            var skipped = 0

            for (index, video) in videos.enumerated() {
                if items.contains(where: { $0.videoID == video.itemKey }) {
                    skipped += 1
                    continue
                }

                let item = VideoItem(
                    videoID: video.itemKey,
                    sourceURL: "https://t.me/\(video.username)/\(video.postID)",
                    title: video.title.isEmpty ? "Telegram 视频" : video.title,
                    channel: video.channelTitle,
                    duration: video.duration,
                    addedAt: baseDate.addingTimeInterval(-Double(index)),
                    source: .telegram,
                    directMediaURL: "td://\(video.fileID)",
                    remoteThumbnailURL: nil
                )
                items.append(item)
                AppPaths.createDirectory(for: item.id)
                if let resolution = video.resolution, resolution > 0 {
                    items[items.count - 1].resolution = resolution
                }
                if video.fileSize > 0 {
                    items[items.count - 1].fileSize = video.fileSize
                }
                items[items.count - 1].telegramChatID = video.chatID
                items[items.count - 1].telegramMessageID = video.postID
                added += 1
            }

            save()
            pumpDownloadQueue()

            guard added > 0 else {
                let message = skipped > 0 ? "这些 Telegram 视频都已经在片库中" : "这个链接里没有找到可下载的视频"
                showToast(text: message, icon: "checkmark.circle")
                return skipped > 0 ? .duplicate : .invalid(message)
            }

            NotificationService.requestAuthorizationIfNeeded()
            showToast(text: "已加入 \(added) 个 Telegram 视频（登录模式）", icon: "paperplane.fill")
            AppLog.info("tdlib telegram imported channel=\(link.username) added=\(added) skipped=\(skipped)")
            return .success(count: added)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("tdlib telegram import failed: \(message)")
            showToast(text: message, icon: "exclamationmark.triangle.fill")
            return .invalid(message)
        }
    }

    // MARK: - Telegram browser import

    /// Adds videos picked from the Telegram browser to the library and starts
    /// downloading them through TDLib.
    @discardableResult
    func addTelegramVideos(_ videos: [TelegramFileVideo], chatTitle: String? = nil) -> Int {
        guard !videos.isEmpty else { return 0 }
        let baseDate = Date()
        var added = 0
        var skipped = 0

        for (index, video) in videos.enumerated() {
            let mediaURL = "td://\(video.fileID)"
            if items.contains(where: { $0.videoID == video.itemKey || $0.directMediaURL == mediaURL }) {
                skipped += 1
                continue
            }

            let item = VideoItem(
                videoID: video.itemKey,
                sourceURL: video.sourceURL,
                title: video.title.isEmpty ? "Telegram 视频" : video.title,
                channel: video.channelTitle,
                duration: video.duration,
                addedAt: baseDate.addingTimeInterval(-Double(index)),
                source: .telegram,
                directMediaURL: mediaURL,
                remoteThumbnailURL: nil
            )
            items.append(item)
            AppPaths.createDirectory(for: item.id)

            if let data = video.thumbnailData, !data.isEmpty {
                try? data.write(to: item.thumbnailFileURL, options: .atomic)
            }
            if let resolution = video.resolution, resolution > 0 {
                items[items.count - 1].resolution = resolution
            }
            if video.fileSize > 0 {
                items[items.count - 1].fileSize = video.fileSize
            }
            items[items.count - 1].telegramChatID = video.chatID
            items[items.count - 1].telegramMessageID = video.postID
            added += 1
        }

        guard added > 0 else {
            if skipped > 0 {
                showToast(text: "这些视频已经在片库或下载列表里了", icon: "checkmark.circle")
            }
            return 0
        }

        save()
        pumpDownloadQueue()
        NotificationService.requestAuthorizationIfNeeded()

        let chatPrefix = chatTitle.map { "「\($0)」的" } ?? ""
        showToast(text: "已加入\(chatPrefix) \(added) 个视频，开始下载", icon: "arrow.down.circle.fill")
        AppLog.info("telegram browser added=\(added) skipped=\(skipped) chat=\(chatTitle ?? "-")")
        return added
    }

    /// Finds a library item already backed by the same Telegram file.
    func telegramLibraryItem(for video: TelegramFileVideo) -> VideoItem? {
        if let byKey = items.first(where: { $0.videoID == video.itemKey }) {
            return byKey
        }
        let mediaURL = "td://\(video.fileID)"
        return items.first { $0.directMediaURL == mediaURL }
    }

    // MARK: - Download queue

    /// Starts queued items while the concurrency limit has free slots.
    private func pumpDownloadQueue() {
        guard !downloadsPaused else { return }
        let active = items.filter {
            !$0.isTrashed && ($0.status == .resolving || $0.status == .downloading || $0.status == .retrying)
        }.count
        guard active < maxConcurrentDownloads else { return }

        let waiting = items
            .filter { !$0.isTrashed && $0.status == .queued }
            .sorted { $0.addedAt < $1.addedAt }
        for item in waiting.prefix(maxConcurrentDownloads - active) {
            startQueuedDownload(itemID: item.id)
        }
    }

    private func startQueuedDownload(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].status == .queued, !items[index].isTrashed else { return }

        items[index].status = .resolving
        items[index].errorMessage = nil
        clearSpeed(id: itemID)
        save()

        resolveTasks[itemID]?.cancel()
        resolveTasks[itemID] = Task { [weak self] in
            await self?.resolveAndDownload(itemID: itemID)
        }
    }

    // MARK: - Pause / resume / delete all downloads

    func pauseAllDownloads() {
        downloadsPaused = true
        DownloadManager.shared.suspendAll()
        TelegramSession.shared.pauseAllDownloads()
        speedSamples.removeAll()
        downloadSpeeds.removeAll()
        AppLog.info("downloads paused by user")
        showToast(text: "已暂停全部下载", icon: "pause.circle.fill")
    }

    func resumeAllDownloads() {
        downloadsPaused = false
        DownloadManager.shared.resumeAll()
        TelegramSession.shared.resumeAllDownloads()
        pumpDownloadQueue()
        AppLog.info("downloads resumed by user")
        showToast(text: "已继续下载", icon: "play.circle.fill")
    }

    private func cancelTransfer(itemID: UUID) {
        DownloadManager.shared.cancel(itemID: itemID)
        TelegramSession.shared.cancelDownload(itemID: itemID)
    }

    func deleteAllDownloads() {
        let ids = items.filter { item in
            !item.isTrashed && (item.status == .queued || item.status == .resolving
                || item.status == .downloading || item.status == .retrying || item.status == .failed)
        }.map(\.id)

        var removed = 0
        for id in ids where performDeletePermanently(itemID: id) {
            removed += 1
        }
        save()
        AppLog.info("all downloads deleted count=\(removed)")
        showToast(text: "已删除 \(removed) 个下载任务", icon: "trash.fill")
    }

    // MARK: - Group operations

    func moveAllToTrash(in source: MediaSource) {
        let ids = items.filter {
            !$0.isTrashed && $0.source == source && $0.status == .ready
        }.map(\.id)

        var moved = 0
        for id in ids where performMoveToTrash(itemID: id) {
            moved += 1
        }
        save()
        pumpDownloadQueue()
        AppLog.info("group moved to trash source=\(source.rawValue) count=\(moved)")
        showToast(text: "已将 \(moved) 个视频移到废纸篓", icon: "trash")
    }

    func deleteAllPermanently(in source: MediaSource) {
        let ids = items.filter {
            !$0.isTrashed && $0.source == source && $0.status == .ready
        }.map(\.id)

        var removed = 0
        for id in ids where performDeletePermanently(itemID: id) {
            removed += 1
        }
        save()
        pumpDownloadQueue()
        AppLog.info("group permanently deleted source=\(source.rawValue) count=\(removed)")
        showToast(text: "已删除 \(removed) 个视频", icon: "trash.fill")
    }

    func deleteAllTrash() {
        let ids = trash.map(\.id)
        var removed = 0
        for id in ids where performDeletePermanently(itemID: id) {
            removed += 1
        }
        save()
        AppLog.info("trash emptied count=\(removed)")
        showToast(text: "已清空废纸篓（\(removed) 个）", icon: "trash.fill")
    }

    func restoreBatch(_ ids: Set<UUID>) {
        var restored = 0
        for id in ids where performRestore(itemID: id) {
            restored += 1
        }
        save()
        showToast(text: "已恢复 \(restored) 个视频", icon: "arrow.uturn.backward.circle")
    }

    func deleteBatchPermanently(_ ids: Set<UUID>) {
        var removed = 0
        for id in ids where performDeletePermanently(itemID: id) {
            removed += 1
        }
        save()
        showToast(text: "已彻底删除 \(removed) 个视频", icon: "trash.fill")
    }

    private func cleanedSharedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return nil }
        if trimmed.lowercased().contains("http") { return nil }
        return trimmed
    }

    // MARK: - Resolution and download

    private func resolveAndDownload(itemID: UUID) async {
        resolveTasks[itemID] = nil
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !items[index].isTrashed else { return }

        if items[index].source == .telegram {
            await beginTelegramDownload(itemID: itemID)
            return
        }

        items[index].status = .resolving
        items[index].errorMessage = nil
        save()
        let videoID = items[index].videoID
        let selectedQuality = downloadQuality
        let knownTitle = items[index].title
        let knownChannel = items[index].channel
        let knownThumbnail = items[index].remoteThumbnailURL.flatMap(URL.init(string:))
        let hasUsefulMetadata = !knownChannel.isEmpty && knownTitle != "YouTube 视频"
        AppLog.info("resolve start videoID=\(videoID) quality=\(selectedQuality.shortLabel) max=\(selectedQuality.maxResolution)p source=youtube")

        async let mediaTask = YouTubeService.prepare(
            videoID: videoID,
            maxResolution: selectedQuality.maxResolution
        )

        let metadata: VideoMetadata
        if hasUsefulMetadata {
            metadata = VideoMetadata(title: knownTitle, channel: knownChannel, thumbnailURL: knownThumbnail)
        } else {
            metadata = await MetadataService.fetch(videoID: videoID)
        }
        AppLog.info("metadata title=\(metadata.title ?? "nil") channel=\(metadata.channel ?? "nil")")
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            if let title = metadata.title, !title.isEmpty {
                items[index].title = title
            }
            if let channel = metadata.channel, !channel.isEmpty {
                items[index].channel = channel
            }
            save()
            let itemSnapshot = items[index]
            let thumbnailURL = metadata.thumbnailURL ?? knownThumbnail
            Task { [weak self] in
                let ok = await MetadataService.downloadThumbnail(
                    for: itemSnapshot,
                    preferredURL: thumbnailURL
                )
                guard ok else { return }
                await MainActor.run {
                    self?.objectWillChange.send()
                }
            }
        }

        do {
            let media = try await mediaTask
            AppLog.info("streams ready requested=\(selectedQuality.shortLabel) quality=\(media.qualityLabel) audio=\(media.audioURL != nil) muxed=\(media.isMuxed)")
            guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].isTrashed else {
                return
            }

            guard !downloadsPaused else {
                items[index].status = .queued
                items[index].errorMessage = nil
                save()
                return
            }

            items[index].status = .downloading
            items[index].hasSeparateAudio = media.audioURL != nil
            items[index].resolution = media.resolution
            items[index].errorMessage = nil
            save()

            kindProgress[itemID] = [:]
            progress[itemID] = 0

            AppPaths.createDirectory(for: itemID)
            DownloadManager.shared.start(
                itemID: itemID,
                videoURL: media.videoURL,
                audioURL: media.audioURL,
                segments: youtubeSegments
            )
            AppLog.info("download started videoID=\(videoID) quality=\(media.qualityLabel) segments=\(youtubeSegments)")
            if let upgradedFrom = media.upgradedFrom {
                showToast(
                    text: "所选 \(upgradedFrom)p 不可用，已自动改用 \(media.qualityLabel)",
                    icon: "arrow.up.circle.fill"
                )
            } else {
                showToast(text: "开始下载 \(media.qualityLabel)", icon: "arrow.down.circle.fill")
            }
        } catch {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            AppLog.error("resolve failed videoID=\(videoID): \(error.localizedDescription)")
            if isPermanentFailure(error) {
                items[index].status = .failed
                items[index].errorMessage = error.localizedDescription
                clearSpeed(id: itemID)
                save()
                pumpDownloadQueue()
                showToast(text: "下载失败：\(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            } else {
                scheduleAutoRetry(itemID: itemID, reason: error.localizedDescription)
            }
        }
    }

    private func beginTelegramDownload(itemID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !items[index].isTrashed else { return }

        guard !downloadsPaused else {
            items[index].status = .queued
            items[index].errorMessage = nil
            save()
            return
        }

        guard let raw = items[index].directMediaURL,
              let url = URL(string: raw) else {
            items[index].status = .failed
            items[index].errorMessage = "Telegram 视频直链无效，请重新导入"
            save()
            pumpDownloadQueue()
            return
        }

        if url.scheme?.lowercased() == "td" {
            await beginTDLibDownload(itemID: itemID, fileID: Int(url.host ?? "") ?? 0)
            return
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            items[index].status = .failed
            items[index].errorMessage = "Telegram 视频直链无效，请重新导入"
            save()
            pumpDownloadQueue()
            return
        }

        items[index].status = .downloading
        items[index].errorMessage = nil
        items[index].hasSeparateAudio = false
        items[index].resolution = nil
        save()

        kindProgress[itemID] = [:]
        progress[itemID] = 0
        AppPaths.createDirectory(for: itemID)

        // Test hook: force segmented Range downloads for direct-URL items.
        let segments = ProcessInfo.processInfo.environment["SHIYING_TEST_SEGMENTS"].flatMap(Int.init) ?? 1
        DownloadManager.shared.start(itemID: itemID, videoURL: url, audioURL: nil, segments: segments)
        AppLog.info("telegram download started item=\(itemID) host=\(url.host ?? "nil") segments=\(segments)")

        if let thumbnailString = items[index].remoteThumbnailURL,
           let thumbnailURL = URL(string: thumbnailString) {
            let snapshot = items[index]
            Task { [weak self] in
                let ok = await MetadataService.downloadThumbnail(for: snapshot, preferredURL: thumbnailURL)
                guard ok else { return }
                await MainActor.run {
                    self?.objectWillChange.send()
                }
            }
        }
    }

    /// Downloads a Telegram video through TDLib. Used for files that the public
    /// web preview hides behind its ~20MB limit.
    private func beginTDLibDownload(itemID: UUID, fileID: Int) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].isTrashed else { return }

        TelegramSession.shared.bootstrap()
        let ready = await waitForTelegramReady(timeout: 20)
        guard let current = items.firstIndex(where: { $0.id == itemID }), !items[current].isTrashed else { return }
        guard ready else {
            items[current].status = .failed
            items[current].errorMessage = "需要登录 Telegram 才能下载这条视频，请到设置里扫码登录"
            save()
            pumpDownloadQueue()
            return
        }

        // TDLib reuses file ids once a cached file is deleted, so the id stored
        // at import time may now point at an unrelated file. Re-resolve it from
        // the chat/message pair before downloading.
        var activeFileID = fileID
        var resolvedSize: Int64 = 0
        var resolvedHeight: Int?
        if let locator = telegramLocator(for: items[current]) {
            do {
                if let resolved = try await TelegramSession.shared.resolveVideoFileID(
                    chatID: locator.chatID,
                    messageID: locator.messageID
                ) {
                    activeFileID = resolved.fileID
                    resolvedSize = resolved.fileSize
                    if let height = resolved.resolution, height > 0 {
                        resolvedHeight = height
                    }
                }
            } catch {
                AppLog.error("tdlib resolve failed item=\(itemID) chat=\(locator.chatID) message=\(locator.messageID): \(error.localizedDescription)")
            }
        }

        guard let fresh = items.firstIndex(where: { $0.id == itemID }), !items[fresh].isTrashed else { return }

        guard activeFileID > 0 else {
            items[fresh].status = .failed
            items[fresh].errorMessage = "Telegram 视频文件标识无效，请重新导入"
            save()
            pumpDownloadQueue()
            return
        }

        if items[fresh].directMediaURL != "td://\(activeFileID)" {
            items[fresh].directMediaURL = "td://\(activeFileID)"
        }
        if resolvedSize > 0 {
            items[fresh].fileSize = resolvedSize
        }

        let knownResolution = items[fresh].resolution
        items[fresh].status = .downloading
        items[fresh].errorMessage = nil
        items[fresh].hasSeparateAudio = false
        items[fresh].resolution = resolvedHeight ?? knownResolution
        save()

        kindProgress[itemID] = [:]
        progress[itemID] = 0
        AppPaths.createDirectory(for: itemID)

        let destination = items[fresh].videoFileURL
        TelegramSession.shared.download(
            fileID: activeFileID,
            itemID: itemID,
            destination: destination,
            onProgress: { [weak self] value, bytes in
                self?.receiveProgress(id: itemID, kind: "video", value: value, bytes: bytes)
            },
            onComplete: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.receiveFile(id: itemID, kind: "video")
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.receiveTDLibError(id: itemID, message: message)
                }
            }
        )
        AppLog.info("tdlib download started item=\(itemID) fileID=\(activeFileID)")
    }

    /// Recovers the chat/message pair used to re-resolve the TDLib file id.
    /// Falls back to parsing the legacy `tg:c<chatID>:<messageID>:<index>` key.
    private func telegramLocator(for item: VideoItem) -> (chatID: Int64, messageID: Int64)? {
        if let chatID = item.telegramChatID, let messageID = item.telegramMessageID, messageID > 0 {
            return (chatID, Int64(messageID))
        }
        let parts = item.videoID.split(separator: ":")
        guard parts.count >= 3, parts[0] == "tg", parts[1].hasPrefix("c"),
              let chatID = Int64(parts[1].dropFirst()),
              let messageID = Int64(parts[2]), messageID > 0 else { return nil }
        return (chatID, messageID)
    }

    private func waitForTelegramReady(timeout: TimeInterval) async -> Bool {
        if TelegramSession.shared.phase.isReady { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            switch TelegramSession.shared.phase {
            case .ready:
                return true
            case .failed, .stopped, .unconfigured:
                return false
            default:
                continue
            }
        }
        return TelegramSession.shared.phase.isReady
    }

    private func receiveTDLibError(id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .downloading else { return }

        TelegramSession.shared.cancelDownload(itemID: id)
        scheduleAutoRetry(itemID: id, reason: "Telegram 下载失败：\(message)")
    }

    func retry(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[index].status == .failed else { return }

        cancelAutoRetry(itemID: itemID)
        resolveTasks[itemID]?.cancel()
        cancelTransfer(itemID: itemID)
        try? FileManager.default.removeItem(at: items[index].videoFileURL)
        try? FileManager.default.removeItem(at: items[index].audioFileURL)
        kindProgress[itemID] = nil
        progress[itemID] = nil
        clearSpeed(id: itemID)
        items[index].status = .queued
        items[index].errorMessage = nil
        items[index].retryCount = 0
        save()

        pumpDownloadQueue()
    }

    /// Cancels a pending automatic retry. Used by the UI when the user wants to stop waiting.
    func abortAutoRetry(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        cancelAutoRetry(itemID: itemID)
        guard items[index].status == .retrying else { return }
        items[index].status = .failed
        items[index].errorMessage = "已取消自动重试"
        clearSpeed(id: itemID)
        save()
        pumpDownloadQueue()
        AppLog.info("auto retry cancelled by user item=\(itemID)")
    }

    private func cancelAutoRetry(itemID: UUID) {
        retryTasks[itemID]?.cancel()
        retryTasks[itemID] = nil
    }

    private func isPermanentFailure(_ error: Error) -> Bool {
        guard let mediaError = error as? MediaPreparationError else { return false }
        switch mediaError {
        case .invalidVideo, .qualityUnavailable:
            return true
        case .noPlayableStream, .extractionFailed:
            return false
        }
    }

    /// Schedules a retry after a short delay instead of failing immediately.
    /// Retries are capped so a permanently broken video cannot loop forever.
    private func scheduleAutoRetry(itemID: UUID, reason: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].isTrashed else { return }
        let status = items[index].status
        guard status == .downloading || status == .resolving else { return }

        cancelTransfer(itemID: itemID)
        cancelAutoRetry(itemID: itemID)
        kindProgress[itemID] = nil
        progress[itemID] = nil
        clearSpeed(id: itemID)

        if items[index].retryCount < Self.maxAutoRetries {
            items[index].retryCount += 1
            let attempt = items[index].retryCount
            items[index].status = .retrying
            items[index].errorMessage = reason
            save()

            AppLog.info("auto retry scheduled item=\(itemID) attempt=\(attempt)/\(Self.maxAutoRetries) delay=\(Self.retryDelaySeconds)s reason=\(reason)")
            showToast(
                text: "下载失败，\(Self.retryDelaySeconds) 秒后自动重试（\(attempt)/\(Self.maxAutoRetries)）",
                icon: "arrow.clockwise"
            )

            retryTasks[itemID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.retryDelaySeconds))
                guard !Task.isCancelled else { return }
                await self?.performAutoRetry(itemID: itemID)
            }
        } else {
            items[index].status = .failed
            items[index].errorMessage = "自动重试 \(Self.maxAutoRetries) 次仍失败：\(reason)"
            save()
            pumpDownloadQueue()
            AppLog.error("auto retry exhausted item=\(itemID) reason=\(reason)")
            showToast(
                text: "自动重试 \(Self.maxAutoRetries) 次仍失败，点按重试",
                icon: "exclamationmark.triangle.fill"
            )
        }
    }

    private func performAutoRetry(itemID: UUID) async {
        retryTasks[itemID] = nil
        guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].isTrashed else { return }
        guard items[index].status == .retrying else { return }

        cancelTransfer(itemID: itemID)
        try? FileManager.default.removeItem(at: items[index].videoFileURL)
        try? FileManager.default.removeItem(at: items[index].audioFileURL)
        clearSpeed(id: itemID)
        items[index].status = .queued
        items[index].errorMessage = nil
        save()
        AppLog.info("auto retry starting item=\(itemID) attempt=\(items[index].retryCount)/\(Self.maxAutoRetries)")
        pumpDownloadQueue()
    }

    private func receiveProgress(id: UUID, kind: String, value: Double, bytes: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .downloading else { return }
        var values = kindProgress[id] ?? [:]
        values[kind] = min(1, max(0, value))
        kindProgress[id] = values

        let expected = items[index].hasSeparateAudio ? 2.0 : 1.0
        let sum = values.values.reduce(0, +)
        progress[id] = min(1, sum / expected)
        trackSpeed(id: id, kind: kind, bytes: bytes)
    }

    func downloadSpeedText(for id: UUID) -> String? {
        downloadSpeeds[id].flatMap { AppPaths.formatSpeed($0) }
    }

    var totalDownloadSpeedText: String? {
        AppPaths.formatSpeed(downloadSpeeds.values.reduce(0, +))
    }

    private func trackSpeed(id: UUID, kind: String, bytes: Int64) {
        guard !downloadsPaused else { return }

        let now = Date()
        var samples = speedSamples[id] ?? [:]

        if let last = samples[kind], bytes >= last.bytes {
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed >= 0.35 {
                let instant = Double(bytes - last.bytes) / elapsed
                let smoothed = last.bytesPerSecond > 0
                    ? last.bytesPerSecond * 0.6 + instant * 0.4
                    : instant
                samples[kind] = SpeedSample(date: now, bytes: bytes, bytesPerSecond: max(0, smoothed))
            }
        } else {
            samples[kind] = SpeedSample(date: now, bytes: bytes, bytesPerSecond: 0)
        }

        speedSamples[id] = samples
        refreshSpeed(id: id)
    }

    private func refreshSpeed(id: UUID) {
        guard let samples = speedSamples[id] else {
            downloadSpeeds[id] = nil
            return
        }
        let now = Date()
        let total = samples.values
            .filter { now.timeIntervalSince($0.date) < 3 }
            .reduce(0.0) { $0 + $1.bytesPerSecond }
        if total > 0 {
            downloadSpeeds[id] = total
        } else {
            downloadSpeeds[id] = nil
        }
    }

    private func clearSpeed(id: UUID) {
        speedSamples[id] = nil
        downloadSpeeds[id] = nil
    }

    private func receiveFile(id: UUID, kind: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var values = kindProgress[id] ?? [:]
        values[kind] = 1
        kindProgress[id] = values

        let item = items[index]
        let videoReady = FileManager.default.fileExists(atPath: item.videoFileURL.path)
        let audioReady = !item.hasSeparateAudio || FileManager.default.fileExists(atPath: item.audioFileURL.path)
        if videoReady && audioReady {
            progress[id] = 1
        } else {
            progress[id] = 0.96
            return
        }

        Task { [weak self] in
            await self?.finalizeDownload(itemID: id)
        }
    }

    private func receiveDownloadError(id: UUID, kind: String, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .downloading else { return }

        if items[index].source == .telegram, message.contains("HTTP 4") {
            cancelTransfer(itemID: id)
            kindProgress[id] = nil
            progress[id] = nil
            items[index].status = .failed
            items[index].errorMessage = "Telegram 直链已失效，请重新导入这条消息"
            save()
            pumpDownloadQueue()
            showToast(text: "Telegram 视频直链已失效，请重新导入", icon: "exclamationmark.triangle.fill")
            return
        }

        let label = kind == "audio" ? "音频" : "视频"
        scheduleAutoRetry(itemID: id, reason: "\(label)下载失败：\(message)")
    }

    private func finalizeDownload(itemID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[index].status == .downloading || items[index].status == .ready else { return }

        let item = items[index]
        guard FileManager.default.fileExists(atPath: item.videoFileURL.path) else { return }
        if item.hasSeparateAudio,
           !FileManager.default.fileExists(atPath: item.audioFileURL.path) {
            return
        }

        var size: Int64 = 0
        for url in [item.videoFileURL, item.audioFileURL] {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            size += Int64(values?.fileSize ?? 0)
        }

        // A stale TDLib file id used to silently download a tiny unrelated
        // cached file and mark the item ready. Treat a much smaller file as a
        // failed download so the item can be retried with a fresh id.
        let expectedSize = item.fileSize
        if item.directMediaURL?.hasPrefix("td://") == true,
           expectedSize > 0, size < expectedSize / 2 {
            try? FileManager.default.removeItem(at: item.videoFileURL)
            try? FileManager.default.removeItem(at: item.audioFileURL)
            guard let stale = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[stale].status = .failed
            items[stale].errorMessage = "Telegram 下载到的文件不完整，请点按重试"
            kindProgress[itemID] = nil
            progress[itemID] = nil
            clearSpeed(id: itemID)
            save()
            AppLog.error("download incomplete title=\(item.title) got=\(size) expected=\(expectedSize)")
            pumpDownloadQueue()
            showToast(text: "Telegram 视频下载不完整，请点按重试", icon: "exclamationmark.triangle.fill")
            return
        }

        var duration = items[index].duration
        if let asset = try? await PlaybackAssetBuilder.makeAsset(for: item),
           let loaded = try? await asset.load(.duration), loaded.isNumeric, loaded.seconds.isFinite, loaded.seconds > 0 {
            duration = loaded.seconds
        }

        guard let freshIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[freshIndex].duration = duration
        items[freshIndex].fileSize = size
        items[freshIndex].status = .ready
        items[freshIndex].errorMessage = nil
        items[freshIndex].retryCount = 0
        let title = items[freshIndex].title
        let trashed = items[freshIndex].isTrashed
        save()
        AppLog.info("download finished title=\(title) bytes=\(size) duration=\(Int(duration))s")

        kindProgress[itemID] = nil
        progress[itemID] = nil
        clearSpeed(id: itemID)
        NotificationService.notifyDownloadFinished(title: title, itemID: itemID)
        pumpDownloadQueue()
        if !trashed {
            showToast(text: "下载完成，可以离线播放了", icon: "checkmark.circle.fill")
        }
    }

    // MARK: - Trash

    func markPlayed(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[index].status == .ready, !items[index].isTrashed else { return }
        items[index].playedAt = Date()
        save()
    }

    func savePlaybackPosition(itemID: UUID, position: Double) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), position.isFinite else { return }
        items[index].playbackPosition = max(0, position)
        save()
    }

    func movePlayedToTrash(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].isTrashed else { return }
        let now = Date()
        items[index].playedAt = now
        items[index].isTrashed = true
        items[index].trashedAt = now
        items[index].deleteAfter = Calendar.current.date(byAdding: .day, value: Self.trashRetentionDays, to: now)
        save()
        showToast(text: "已移到废纸篓，7 天后自动清理", icon: "clock.arrow.circlepath")
    }

    func moveToTrash(itemID: UUID) {
        guard performMoveToTrash(itemID: itemID) else { return }
        save()
        showToast(text: "已移到废纸篓，7 天后删除", icon: "trash")
    }

    @discardableResult
    private func performMoveToTrash(itemID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        guard !items[index].isTrashed else { return false }
        cancelAutoRetry(itemID: itemID)
        resolveTasks[itemID]?.cancel()
        resolveTasks[itemID] = nil
        cancelTransfer(itemID: itemID)
        let now = Date()
        items[index].isTrashed = true
        items[index].trashedAt = now
        items[index].deleteAfter = Calendar.current.date(byAdding: .day, value: Self.trashRetentionDays, to: now)
        if items[index].status == .queued || items[index].status == .downloading
            || items[index].status == .resolving || items[index].status == .retrying {
            items[index].status = .failed
            items[index].errorMessage = "已移到废纸篓"
        }
        progress[itemID] = nil
        kindProgress[itemID] = nil
        clearSpeed(id: itemID)
        return true
    }

    func restore(itemID: UUID) {
        guard performRestore(itemID: itemID) else { return }
        save()
        showToast(text: "已恢复到片库", icon: "arrow.uturn.backward.circle")
    }

    @discardableResult
    private func performRestore(itemID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        items[index].isTrashed = false
        items[index].trashedAt = nil
        items[index].deleteAfter = nil
        items[index].playedAt = nil
        if items[index].status == .failed, items[index].isPlayable {
            items[index].status = .ready
        }
        return true
    }

    func deletePermanently(itemID: UUID) {
        guard performDeletePermanently(itemID: itemID) else { return }
        save()
        pumpDownloadQueue()
        showToast(text: "已彻底删除", icon: "trash.fill")
    }

    @discardableResult
    private func performDeletePermanently(itemID: UUID) -> Bool {
        guard items.contains(where: { $0.id == itemID }) else { return false }
        cancelAutoRetry(itemID: itemID)
        resolveTasks[itemID]?.cancel()
        resolveTasks[itemID] = nil
        cancelTransfer(itemID: itemID)
        AppPaths.removeDirectory(for: itemID)
        items.removeAll { $0.id == itemID }
        progress[itemID] = nil
        kindProgress[itemID] = nil
        clearSpeed(id: itemID)
        return true
    }

    @discardableResult
    func purgeExpired(notify: Bool = true) -> Int {
        let now = Date()
        let expired = items.filter {
            $0.isTrashed && $0.deleteAfter.map { $0 <= now } == true
        }
        guard !expired.isEmpty else { return 0 }

        for item in expired {
            cancelAutoRetry(itemID: item.id)
            resolveTasks[item.id]?.cancel()
            resolveTasks[item.id] = nil
            cancelTransfer(itemID: item.id)
            AppPaths.removeDirectory(for: item.id)
            progress[item.id] = nil
            kindProgress[item.id] = nil
            clearSpeed(id: item.id)
        }
        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        save()
        pumpDownloadQueue()
        if notify {
            showToast(text: "已清理 \(expired.count) 个过期视频", icon: "sparkles")
        }
        return expired.count
    }

    // MARK: - Lifecycle / persistence

    func appBecameActive() {
        purgeExpired(notify: false)
        Task { [weak self] in
            await self?.recoverDownloads()
            self?.pumpDownloadQueue()
        }
    }

    private static let clipboardChangeCountKey = "shiying.clipboardChangeCount"
    private static let clipboardHandledTextKey = "shiying.clipboardHandledText"
    private var isCheckingClipboard = false

    /// Auto-imports a supported link found in the pasteboard on launch or when
    /// the app returns to the foreground. System link detection runs first, so
    /// the iOS paste prompt only appears for plain text it cannot classify.
    func importFromClipboardIfNeeded() async {
        guard autoReadClipboard, !isCheckingClipboard else { return }
        isCheckingClipboard = true
        defer { isCheckingClipboard = false }

        let pasteboard = UIPasteboard.general
        let defaults = UserDefaults.standard

        guard let lastCount = defaults.object(forKey: Self.clipboardChangeCountKey) as? Int else {
            // First run with this build: remember the existing clipboard without
            // reading it, so upgrading does not trigger a paste prompt.
            defaults.set(pasteboard.changeCount, forKey: Self.clipboardChangeCountKey)
            return
        }
        guard pasteboard.changeCount != lastCount else { return }
        defaults.set(pasteboard.changeCount, forKey: Self.clipboardChangeCountKey)

        var candidate: String?
        if let detected = try? await pasteboard.detectedValues(for: [\UIPasteboard.DetectedValues.links]) {
            candidate = detected.links.first?.url.absoluteString
        }
        if candidate == nil, pasteboard.hasStrings {
            candidate = pasteboard.string
        }

        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        guard LinkExtractor.hasSupportedLink(in: raw) else { return }
        guard defaults.string(forKey: Self.clipboardHandledTextKey) != raw else { return }
        defaults.set(raw, forKey: Self.clipboardHandledTextKey)

        AppLog.info("clipboard auto import: \(raw.prefix(160))")
        let feedback = await importInput(raw)
        if case .invalid(let message) = feedback {
            showToast(text: "剪贴板导入失败：\(message)", icon: "exclamationmark.triangle.fill")
        }
    }

    func recoverDownloads() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        let activeIDs = await DownloadManager.shared.activeItemIDs()

        for item in items {
            guard !item.isTrashed else { continue }

            switch item.status {
            case .downloading:
                let videoReady = FileManager.default.fileExists(atPath: item.videoFileURL.path)
                let audioReady = !item.hasSeparateAudio || FileManager.default.fileExists(atPath: item.audioFileURL.path)
                if videoReady && audioReady {
                    await finalizeDownload(itemID: item.id)
                } else if !activeIDs.contains(item.id) {
                    if item.source == .telegram, item.directMediaURL?.hasPrefix("td://") == true {
                        // TDLib keeps its own file cache and session, so a restarted
                        // download can resume as soon as the client is ready again.
                        if TelegramCredentials.isConfigured {
                            if let index = items.firstIndex(where: { $0.id == item.id }) {
                                items[index].status = .queued
                                items[index].errorMessage = nil
                                save()
                            }
                        } else if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index].status = .failed
                            items[index].errorMessage = "需要登录 Telegram 才能继续下载，请登录后点按重试"
                            save()
                        }
                    } else if item.source == .telegram {
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index].status = .failed
                            items[index].errorMessage = "Telegram 下载已中断，请重新导入"
                            save()
                        }
                    } else {
                        scheduleAutoRetry(itemID: item.id, reason: "下载中断")
                    }
                }
            case .resolving:
                // A resolve Task only lives in-process; requeue when it is gone
                // instead of leaving the item stranded as "解析中".
                if resolveTasks[item.id] == nil, !activeIDs.contains(item.id),
                   let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].status = .queued
                    items[index].errorMessage = nil
                    save()
                }
            case .retrying:
                if retryTasks[item.id] == nil, !activeIDs.contains(item.id),
                   let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].status = .queued
                    items[index].errorMessage = nil
                    save()
                }
            default:
                break
            }
        }
    }

    func refresh() async {
        purgeExpired(notify: false)
        await recoverDownloads()
    }

    /// Debug-only helper used by env-driven UI tests to exercise autoplay without
    /// downloading a second video. Media files are hard-linked when possible.
    @discardableResult
    func cloneFirstPlayableForTesting() -> VideoItem? {
        if let index = items.firstIndex(where: { $0.videoID.hasSuffix("-autoplay-test") }) {
            items[index].isTrashed = false
            items[index].trashedAt = nil
            items[index].deleteAfter = nil
            items[index].playedAt = nil
            items[index].addedAt = Date()
            save()
            return items[index]
        }

        guard let source = items.first(where: { $0.isPlayable }) else { return nil }
        let newID = UUID()
        AppPaths.createDirectory(for: newID)

        let fileManager = FileManager.default
        let pairs = [
            (source.videoFileURL, AppPaths.mediaURL(for: newID, kind: "video")),
            (source.audioFileURL, AppPaths.mediaURL(for: newID, kind: "audio")),
            (source.thumbnailFileURL, AppPaths.thumbnailURL(for: newID))
        ]
        for (from, to) in pairs where fileManager.fileExists(atPath: from.path) {
            do {
                try fileManager.linkItem(at: from, to: to)
            } catch {
                try? fileManager.copyItem(at: from, to: to)
            }
        }

        var clone = VideoItem(
            id: newID,
            videoID: "\(source.videoID)-autoplay-test",
            sourceURL: source.sourceURL,
            title: "\(source.title) · 连播测试 B",
            channel: source.channel,
            duration: source.duration,
            addedAt: Date().addingTimeInterval(-1),
            source: source.source
        )
        clone.status = .ready
        clone.resolution = source.resolution
        clone.hasSeparateAudio = source.hasSeparateAudio
            && fileManager.fileExists(atPath: AppPaths.mediaURL(for: newID, kind: "audio").path)
        clone.fileSize = source.fileSize

        items.insert(clone, at: 0)
        save()
        AppLog.info("test clone created id=\(newID) title=\(clone.title)")
        return clone
    }

    func cleanupTestArtifacts() {
        let targets = items.filter { $0.videoID.hasSuffix("-autoplay-test") || $0.status == .failed }
        guard !targets.isEmpty else { return }
        for item in targets {
            AppPaths.removeDirectory(for: item.id)
        }
        let ids = Set(targets.map(\.id))
        items.removeAll { ids.contains($0.id) }
        save()
        AppLog.info("test artifacts removed count=\(targets.count)")
    }

    func removeAllItemsForTesting() {
        for item in items {
            AppPaths.removeDirectory(for: item.id)
        }
        items.removeAll()
        save()
        AppLog.info("all library items removed for testing")
    }

    var allPlayableIDs: Set<UUID> {
        Set(items.filter(\.isPlayable).map(\.id))
    }

    private func startHousekeepingTimer() {
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = self?.purgeExpired(notify: false)
            }
        }
    }

    private func startSpeedTimer() {
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for id in Array(self.downloadSpeeds.keys) {
                    self.refreshSpeed(id: id)
                }
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else {
            AppLog.info("library load: no file at \(AppPaths.libraryFile.path)")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode([VideoItem].self, from: data)
            items = decoded
            AppLog.info("library loaded count=\(decoded.count)")
        } catch {
            AppLog.error("library decode failed: \(error)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: AppPaths.libraryFile, options: .atomic)
    }

    private func showToast(text: String, icon: String) {
        toastTask?.cancel()
        toast = ToastMessage(text: text, icon: icon)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.toast?.text == text {
                    self?.toast = nil
                }
            }
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let icon: String
}
