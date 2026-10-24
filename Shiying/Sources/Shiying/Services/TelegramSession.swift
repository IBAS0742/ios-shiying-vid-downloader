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

    var id: String { itemKey }

    var itemKey: String {
        "tg:\(username.lowercased()):\(postID):\(index)"
    }
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

    private var manager: TDLibClientManager?
    private var client: TDLibClient?

    private struct DownloadJob {
        let itemID: UUID
        let fileID: Int
        let destination: URL
        let onProgress: @MainActor (Double) -> Void
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
        default:
            break
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
                    index: index
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

    private func makeVideo(
        from message: Message,
        username: String,
        channelTitle: String,
        index: Int
    ) -> TelegramFileVideo? {
        guard case .messageVideo(let content) = message.content else { return nil }
        let video = content.video
        let file = video.video

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
            duration: Double(video.duration)
        )
    }

    // MARK: - Downloading files

    func download(
        fileID: Int,
        itemID: UUID,
        destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void,
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
        update(job: itemID, file: file)
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
        job.onProgress(min(0.99, max(0, value)))
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
                    job.onProgress(1)
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
