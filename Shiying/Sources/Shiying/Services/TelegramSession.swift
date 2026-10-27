import Foundation
import UIKit
import TDLibKit

enum TelegramCredentials {
    private static let apiIDKey = "telegram.apiID"
    private static let apiHashKey = "telegram.apiHash"

    static var apiID: Int? {
        KeychainStore.string(for: apiIDKey).flatMap(Int.init)
    }

    static var apiHash: String? {
        let value = KeychainStore.string(for: apiHashKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static var isConfigured: Bool {
        apiID != nil && apiHash != nil
    }

    static func save(apiID: Int, apiHash: String) {
        KeychainStore.set(String(apiID), for: apiIDKey)
        KeychainStore.set(apiHash.trimmingCharacters(in: .whitespacesAndNewlines), for: apiHashKey)
    }

    static func clear() {
        KeychainStore.remove(apiIDKey)
        KeychainStore.remove(apiHashKey)
    }
}

enum TelegramSessionError: LocalizedError {
    case notConfigured
    case notReady
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在设置里填写 Telegram API ID 和 API Hash"
        case .notReady:
            return "Telegram 尚未登录，请先在设置里扫码登录"
        case .api(let message):
            return message
        }
    }
}

struct TelegramFileVideo: Identifiable, Sendable {
    let username: String
    let channelTitle: String
    let postID: Int
    let index: Int
    let title: String
    let fileID: Int
    let fileSize: Int64
    let duration: Double
    var chatID: Int64? = nil
    var thumbnailData: Data? = nil
    var resolution: Int? = nil
    var date: Foundation.Date? = nil

    var id: String { itemKey }

    var itemKey: String {
        if !username.isEmpty {
            return "tg:\(username.lowercased()):\(postID):\(index)"
        }
        if let chatID {
            return "tg:c\(chatID):\(postID):\(index)"
        }
        return "tg:\(postID):\(index)"
    }

    var sourceURL: String {
        if !username.isEmpty {
            return "https://t.me/\(username)/\(postID)"
        }
        if let chatID {
            return "tg://openmessage?chat_id=\(chatID)&message_id=\(postID)"
        }
        return ""
    }
}

struct TelegramChatSummary: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case channel
        case group

        var label: String {
            switch self {
            case .channel: return "频道"
            case .group: return "群组"
            }
        }

        var icon: String {
            switch self {
            case .channel: return "megaphone.fill"
            case .group: return "person.2.fill"
            }
        }
    }

    let id: Int64
    let title: String
    let kind: Kind
    let photoData: Data?
    let unreadCount: Int
    let lastMessageDate: Foundation.Date?
    let isArchived: Bool

    init?(
        chat: Chat,
        archived: Bool
    ) {
        let kind: Kind
        switch chat.type {
        case .chatTypeBasicGroup:
            kind = .group
        case .chatTypeSupergroup(let info):
            kind = info.isChannel ? .channel : .group
        default:
            return nil
        }

        id = chat.id
        title = chat.title
        self.kind = kind
        photoData = chat.photo?.minithumbnail?.data
        unreadCount = max(0, chat.unreadCount)
        lastMessageDate = chat.lastMessage.map {
            Foundation.Date(timeIntervalSince1970: TimeInterval($0.date))
        }
        isArchived = archived
    }
}

struct TelegramVideoPage: Sendable {
    let videos: [TelegramFileVideo]
    let nextFromMessageID: Int64?
}

/// Owns the TDLib client used for QR login and for downloading Telegram videos
/// that the public web preview refuses to expose (over ~20 MB).
@MainActor
final class TelegramSession: ObservableObject {
    static let shared = TelegramSession()

    enum Phase: Equatable {
        case unconfigured
        case stopped
        case starting
        case waitingForQR
        case passwordRequired
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var qrLink: String?
    @Published private(set) var passwordHint: String = ""
    @Published private(set) var profileName: String = ""
    @Published private(set) var profileUsername: String = ""
    @Published private(set) var connectionStateText: String = ""
    @Published private(set) var downloadDebugText: String = ""

    private var manager: TDLibClientManager?
    private var client: TDLibClient?

    private struct DownloadJob {
        let itemID: UUID
        let fileID: Int
        let destination: URL
        let onProgress: @MainActor (Double, Int64) -> Void
        let onComplete: @MainActor (Result<Void, Swift.Error>) -> Void
    }

    private var jobs: [UUID: DownloadJob] = [:]
    private var fileToItem: [Int: UUID] = [:]

    private init() {}

    // MARK: - Lifecycle

    var profileLabel: String {
        if !profileName.isEmpty && !profileUsername.isEmpty {
            return "\(profileName) · @\(profileUsername)"
        }
        if !profileName.isEmpty { return profileName }
        if !profileUsername.isEmpty { return "@\(profileUsername)" }
        return "已登录"
    }

    func bootstrap() {
        guard TelegramCredentials.isConfigured else {
            phase = .unconfigured
            return
        }
        guard manager == nil else { return }

        prepareDirectories()
        phase = .starting

        let manager = TDLibClientManager()
        self.manager = manager

        let client = manager.createClient { [weak self] data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            Task { @MainActor [weak self] in
                self?.handle(update)
            }
        }
        self.client = client
        AppLog.info("tdlib client created")
    }

    /// Logs out and releases the TDLib client. A new QR flow can start afterwards.
    func logOut() {
        guard let client else { return }
        phase = .starting
        Task {
            do {
                _ = try await client.logOut()
                AppLog.info("tdlib logOut requested")
            } catch {
                self.phase = .failed("退出 Telegram 失败：\(self.friendlyMessage(error))")
            }
        }
    }

    // MARK: - Update handling

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let value):
            handleAuthState(value.authorizationState)
        case .updateFile(let value):
            handleFile(value.file)
        case .updateConnectionState(let value):
            let text = Self.describe(value.state)
            if connectionStateText != text {
                AppLog.info("tdlib connection state: \(text)")
            }
            connectionStateText = text
        default:
            break
        }
    }

    private static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .connectionStateReady: return "已连接"
        case .connectionStateConnecting: return "连接中"
        case .connectionStateConnectingToProxy: return "连接代理中"
        case .connectionStateUpdating: return "同步中"
        case .connectionStateWaitingForNetwork: return "等待网络"
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            Task { await applyParameters() }

        case .authorizationStateWaitPhoneNumber:
            requestQRCode()

        case .authorizationStateWaitOtherDeviceConfirmation(let value):
            qrLink = value.link
            phase = .waitingForQR
            AppLog.info("tdlib waiting for QR confirmation")

        case .authorizationStateWaitPassword(let value):
            passwordHint = value.passwordHint
            phase = .passwordRequired
            AppLog.info("tdlib waiting for 2FA password")

        case .authorizationStateReady:
            qrLink = nil
            passwordHint = ""
            phase = .ready
            AppLog.info("tdlib authorized")
            Task { await refreshProfile() }

        case .authorizationStateLoggingOut:
            phase = .starting

        case .authorizationStateClosing:
            break

        case .authorizationStateClosed:
            failAllDownloads(TelegramSessionError.api("Telegram 会话已关闭"))
            client = nil
            manager = nil
            qrLink = nil
            profileName = ""
            profileUsername = ""
            phase = .stopped
            AppLog.info("tdlib client closed")

        case .authorizationStateWaitCode, .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode:
            phase = .failed("这个账号需要验证码登录，请先在 Telegram 官方 App 里完成登录，再回来扫码")

        case .authorizationStateWaitRegistration:
            phase = .failed("这个 Telegram 账号还没有完成注册，请先在官方 App 里完成注册")

        case .authorizationStateWaitPremiumPurchase:
            phase = .failed("这个账号需要在 Telegram 官方 App 内完成 Premium 购买确认")

        default:
            break
        }
    }

    private func applyParameters() async {
        guard let client,
              let apiID = TelegramCredentials.apiID,
              let apiHash = TelegramCredentials.apiHash else {
            phase = .unconfigured
            return
        }

        let root = AppPaths.telegramRoot
        do {
            _ = try await client.setTdlibParameters(
                apiHash: apiHash,
                apiId: apiID,
                applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                databaseDirectory: root.appendingPathComponent("Database", isDirectory: true).path,
                databaseEncryptionKey: Data(),
                deviceModel: UIDevice.current.model,
                filesDirectory: root.appendingPathComponent("Files", isDirectory: true).path,
                systemLanguageCode: "zh-hans",
                systemVersion: UIDevice.current.systemVersion,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )
            AppLog.info("tdlib parameters applied")
        } catch {
            phase = .failed("Telegram 初始化失败：\(friendlyMessage(error))")
        }
    }

    private func requestQRCode() {
        guard let client else { return }
        Task {
            do {
                _ = try await client.requestQrCodeAuthentication(otherUserIds: nil)
            } catch {
                if qrLink == nil {
                    phase = .failed("无法生成登录二维码：\(friendlyMessage(error))")
                } else {
                    AppLog.error("tdlib QR refresh rejected: \(friendlyMessage(error))")
                }
            }
        }
    }

    func refreshQRCode() {
        requestQRCode()
    }

    func submitPassword(_ password: String) async {
        guard let client else { return }
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.checkAuthenticationPassword(password: trimmed)
        } catch {
            phase = .passwordRequired
            AppLog.error("tdlib password check failed: \(friendlyMessage(error))")
        }
    }

    private func refreshProfile() async {
        guard let client else { return }
        do {
            let me = try await client.getMe()
            let name = [me.firstName, me.lastName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            profileName = name.isEmpty ? "Telegram 用户" : name
            profileUsername = me.usernames?.activeUsernames.first ?? ""
        } catch {
            AppLog.error("tdlib getMe failed: \(friendlyMessage(error))")
        }
    }

    // MARK: - Resolving public posts through TDLib

    func fetchVideos(link: TelegramLink) async throws -> [TelegramFileVideo] {
        guard let client else { throw TelegramSessionError.notReady }

        do {
            let chat = try await client.searchPublicChat(username: link.username)
            let channelTitle = chat.title
            var collected: [TelegramFileVideo] = []
            var seen = Set<String>()

            func append(_ message: Message, index: Int) {
                guard let video = makeVideo(
                    from: message,
                    username: link.username,
                    channelTitle: channelTitle,
                    index: index,
                    chatID: chat.id
                ) else { return }
                guard seen.insert(video.itemKey).inserted else { return }
                collected.append(video)
            }

            switch link {
            case .post(_, let postID):
                let message = try await client.getMessage(chatId: chat.id, messageId: Int64(postID))
                append(message, index: 0)

            case .channel:
                let history = try await client.getChatHistory(
                    chatId: chat.id,
                    fromMessageId: 0,
                    limit: 60,
                    offset: 0,
                    onlyLocal: false
                )
                for message in history.messages ?? [] {
                    append(message, index: 0)
                    if collected.count >= 30 { break }
                }
                collected.sort { $0.postID > $1.postID }
            }

            AppLog.info("tdlib resolved \(collected.count) video(s) for \(link.username)")
            return collected
        } catch {
            throw TelegramSessionError.api("Telegram 读取失败：\(friendlyMessage(error))")
        }
    }

    // MARK: - Browsing joined chats

    /// Lists group and channel chats from the user's main and archived lists.
    func loadChatSummaries(limit: Int = 120) async throws -> [TelegramChatSummary] {
        guard let client else { throw TelegramSessionError.notReady }

        var summaries: [TelegramChatSummary] = []
        var seen = Set<Int64>()
        var firstError: Swift.Error?

        for (list, archived) in [(ChatList.chatListMain, false), (ChatList.chatListArchive, true)] {
            do {
                _ = try await client.loadChats(chatList: list, limit: limit)
            } catch {
                if !isChatListFullyLoaded(error) {
                    firstError = firstError ?? error
                }
            }

            do {
                let chats = try await client.getChats(chatList: list, limit: limit)
                for id in chats.chatIds where seen.insert(id).inserted {
                    guard let chat = try? await client.getChat(chatId: id),
                          let summary = TelegramChatSummary(chat: chat, archived: archived) else {
                        continue
                    }
                    summaries.append(summary)
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        if summaries.isEmpty, let firstError {
            throw TelegramSessionError.api("Telegram 群组读取失败：\(friendlyMessage(firstError))")
        }

        summaries.sort { lhs, rhs in
            switch (lhs.lastMessageDate, rhs.lastMessageDate) {
            case let (left?, right?): return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }
        AppLog.info("tdlib chats loaded count=\(summaries.count)")
        return summaries
    }

    /// Loads a page of video messages from one chat. `fromMessageID` is the
    /// cursor returned by the previous page; pass 0 for the newest page.
    func loadChatVideos(
        chatID: Int64,
        chatTitle: String,
        fromMessageID: Int64 = 0,
        pageSize: Int = 30
    ) async throws -> TelegramVideoPage {
        guard let client else { throw TelegramSessionError.notReady }

        do {
            let history = try await client.getChatHistory(
                chatId: chatID,
                fromMessageId: fromMessageID,
                limit: 100,
                offset: 0,
                onlyLocal: false
            )
            let messages = history.messages ?? []
            var videos: [TelegramFileVideo] = []
            var seen = Set<String>()
            var oldestMessageID: Int64 = 0

            for message in messages {
                if oldestMessageID == 0 || message.id < oldestMessageID {
                    oldestMessageID = message.id
                }
                guard videos.count < pageSize else { continue }
                guard let video = makeVideo(
                    from: message,
                    username: "",
                    channelTitle: chatTitle,
                    index: 0,
                    chatID: chatID
                ) else { continue }
                guard seen.insert(video.itemKey).inserted else { continue }
                videos.append(video)
            }

            // A full page usually means older history exists. The cursor
            // message appears again on the next page; the caller dedupes it.
            let next = (messages.count >= 100 && oldestMessageID > 0) ? oldestMessageID : nil
            AppLog.info("tdlib chat videos chat=\(chatID) loaded=\(videos.count) messages=\(messages.count) next=\(next ?? 0)")
            return TelegramVideoPage(videos: videos, nextFromMessageID: next)
        } catch {
            throw TelegramSessionError.api("Telegram 视频读取失败：\(friendlyMessage(error))")
        }
    }

    private func isChatListFullyLoaded(_ error: Swift.Error) -> Bool {
        (error as? TDLibKit.Error)?.code == 404
    }

    private func makeVideo(
        from message: Message,
        username: String,
        channelTitle: String,
        index: Int,
        chatID: Int64? = nil
    ) -> TelegramFileVideo? {
        guard message.canBeSaved else { return nil }
        guard case .messageVideo(let content) = message.content else { return nil }
        let video = content.video
        let file = video.video
        guard file.id > 0 else { return nil }

        let caption = content.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = caption.isEmpty ? video.fileName : caption
        let title = rawTitle.isEmpty
            ? "\(channelTitle) #\(message.id)"
            : String(rawTitle.prefix(180))

        return TelegramFileVideo(
            username: username,
            channelTitle: channelTitle,
            postID: Int(message.id),
            index: index,
            title: title,
            fileID: file.id,
            fileSize: max(file.size, file.expectedSize),
            duration: Double(video.duration),
            chatID: chatID,
            thumbnailData: video.minithumbnail?.data,
            resolution: video.height > 0 ? video.height : nil,
            date: Foundation.Date(timeIntervalSince1970: TimeInterval(message.date))
        )
    }

    // MARK: - Downloading files

    /// Re-reads the message and returns its current video file info.
    /// Persisted file ids are unsafe because TDLib reuses ids once a cached
    /// file is deleted.
    func resolveVideoFileID(chatID: Int64, messageID: Int64) async throws -> TelegramFileVideo? {
        guard let client else { throw TelegramSessionError.notReady }
        let message = try await client.getMessage(chatId: chatID, messageId: messageID)
        return makeVideo(
            from: message,
            username: "",
            channelTitle: "",
            index: 0,
            chatID: chatID
        )
    }

    func download(
        fileID: Int,
        itemID: UUID,
        destination: URL,
        onProgress: @escaping @MainActor (Double, Int64) -> Void,
        onComplete: @escaping @MainActor (Result<Void, Swift.Error>) -> Void
    ) {
        guard let client else {
            onComplete(.failure(TelegramSessionError.notReady))
            return
        }
        guard jobs[itemID] == nil else { return }

        jobs[itemID] = DownloadJob(
            itemID: itemID,
            fileID: fileID,
            destination: destination,
            onProgress: onProgress,
            onComplete: onComplete
        )
        fileToItem[fileID] = itemID

        Task {
            do {
                let file = try await client.downloadFile(
                    fileId: fileID,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
                self.update(job: itemID, file: file)
            } catch {
                self.finish(job: itemID, result: .failure(error))
            }
        }
    }

    private func handleFile(_ file: File) {
        guard let itemID = fileToItem[file.id] else { return }
        let total = max(file.expectedSize, file.size)
        downloadDebugText = "file=\(file.id) \(file.local.downloadedSize)/\(total) active=\(file.local.isDownloadingActive) done=\(file.local.isDownloadingCompleted)"
        logFileProgress(file, total: total)
        update(job: itemID, file: file)
    }

    private struct FileProgressLog {
        let bucket: Int
        let date: Foundation.Date
    }

    private var progressLogs: [Int: FileProgressLog] = [:]

    private func logFileProgress(_ file: File, total: Int64) {
        guard total > 0 else { return }
        let percent = Int(Double(file.local.downloadedSize) / Double(total) * 100)
        let bucket = percent / 10 * 10
        let now = Foundation.Date()
        if let last = progressLogs[file.id],
           last.bucket == bucket,
           now.timeIntervalSince(last.date) < 15 {
            return
        }
        progressLogs[file.id] = FileProgressLog(bucket: bucket, date: now)
        AppLog.info(
            "tdlib file \(file.id) \(percent)% "
                + "(\(file.local.downloadedSize)/\(total)) "
                + "active=\(file.local.isDownloadingActive)"
        )
    }

    private func update(job itemID: UUID, file: File) {
        guard let job = jobs[itemID] else { return }

        if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            finish(job: itemID, result: .success(()), localPath: file.local.path)
            return
        }

        let total = max(file.expectedSize, file.size)
        guard total > 0 else { return }
        let value = Double(file.local.downloadedSize) / Double(total)
        job.onProgress(min(0.99, max(0, value)), Int64(file.local.downloadedSize))
    }

    private func finish(
        job itemID: UUID,
        result: Result<Void, Swift.Error>,
        localPath: String? = nil
    ) {
        guard let job = jobs.removeValue(forKey: itemID) else { return }
        fileToItem[job.fileID] = nil

        guard case .success = result, let localPath else {
            if case .failure(let error) = result {
                job.onComplete(.failure(error))
            }
            return
        }

        let source = URL(fileURLWithPath: localPath)
        Task.detached(priority: .utility) {
            do {
                let directory = job.destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: job.destination.path) {
                    try FileManager.default.removeItem(at: job.destination)
                }
                try FileManager.default.copyItem(at: source, to: job.destination)
                await MainActor.run {
                    job.onProgress(1, 0)
                    job.onComplete(.success(()))
                    self.deleteCachedFile(job.fileID)
                }
            } catch {
                await MainActor.run {
                    job.onComplete(.failure(error))
                }
            }
        }
    }

    private func deleteCachedFile(_ fileID: Int) {
        guard let client else { return }
        Task {
            _ = try? await client.deleteFile(fileId: fileID)
        }
    }

    func pauseAllDownloads() {
        guard let client else { return }
        let ids = jobs.values.map(\.fileID)
        guard !ids.isEmpty else { return }
        Task {
            for id in ids {
                _ = try? await client.toggleDownloadIsPaused(fileId: id, isPaused: true)
            }
        }
    }

    func resumeAllDownloads() {
        guard let client else { return }
        let ids = jobs.values.map(\.fileID)
        guard !ids.isEmpty else { return }
        Task {
            for id in ids {
                _ = try? await client.toggleDownloadIsPaused(fileId: id, isPaused: false)
            }
        }
    }

    func cancelDownload(itemID: UUID) {
        guard let job = jobs.removeValue(forKey: itemID) else { return }
        fileToItem[job.fileID] = nil
        guard let client else { return }
        Task {
            _ = try? await client.cancelDownloadFile(fileId: job.fileID, onlyIfPending: false)
        }
    }

    private func failAllDownloads(_ error: Swift.Error) {
        let pending = jobs
        jobs.removeAll()
        fileToItem.removeAll()
        for job in pending.values {
            job.onComplete(.failure(error))
        }
    }

    // MARK: - Helpers

    private func prepareDirectories() {
        AppPaths.prepare()
        let root = AppPaths.telegramRoot
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("Database", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("Files", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func friendlyMessage(_ error: Swift.Error) -> String {
        if let tdlibError = error as? TDLibKit.Error {
            switch tdlibError.code {
            case 429:
                return "Telegram 请求过于频繁，请稍后再试"
            case 406:
                return "Telegram 暂时拒绝了请求，请稍后再试"
            default:
                return tdlibError.message
            }
        }
        return error.localizedDescription
    }
}
