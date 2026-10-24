import Foundation

final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    static let sessionIdentifier = "com.ibas.shiying.downloads"

    var progressHandler: (@MainActor (UUID, String, Double) -> Void)?
    var fileHandler: (@MainActor (UUID, String) -> Void)?
    var errorHandler: (@MainActor (UUID, String, String) -> Void)?

    private var session: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?
    private let delegateQueue = OperationQueue()
    private var lastProgressDelivery: [Int: Date] = [:]

    private override init() {
        super.init()
        delegateQueue.name = "com.ibas.shiying.downloads.delegate"
        delegateQueue.maxConcurrentOperationCount = 4

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    func start(itemID: UUID, videoURL: URL, audioURL: URL?) {
        let videoTask = session.downloadTask(with: videoURL)
        videoTask.taskDescription = taskDescription(itemID: itemID, kind: "video")
        videoTask.resume()
        AppLog.info("enqueue video task \(videoTask.taskIdentifier) item=\(itemID)")

        if let audioURL {
            let audioTask = session.downloadTask(with: audioURL)
            audioTask.taskDescription = taskDescription(itemID: itemID, kind: "audio")
            audioTask.resume()
            AppLog.info("enqueue audio task \(audioTask.taskIdentifier) item=\(itemID)")
        }
    }

    func cancel(itemID: UUID) {
        let prefix = itemID.uuidString + "|"
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription?.hasPrefix(prefix) == true }.forEach { $0.cancel() }
        }
    }

    func suspendAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.suspend() }
        }
        AppLog.info("all download tasks suspended")
    }

    func resumeAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.resume() }
        }
        AppLog.info("all download tasks resumed")
    }

    func activeItemIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let ids = tasks.compactMap { task -> UUID? in
                    guard let description = task.taskDescription,
                          let raw = description.split(separator: "|").first else { return nil }
                    return UUID(uuidString: String(raw))
                }
                continuation.resume(returning: Set(ids))
            }
        }
    }

    func hasActiveTask(itemID: UUID, kind: String) async -> Bool {
        let suffix = "|\(kind)"
        return await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.contains {
                    $0.taskDescription == "\(itemID.uuidString)\(suffix)"
                })
            }
        }
    }

    private func taskDescription(itemID: UUID, kind: String) -> String {
        "\(itemID.uuidString)|\(kind)"
    }

    private func parseTaskDescription(_ description: String?) -> (UUID, String)? {
        guard let description else { return nil }
        let parts = description.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, String(parts[1]))
    }

    private func deliverProgress(id: UUID, kind: String, progress: Double, taskID: Int, force: Bool) {
        let now = Date()
        if !force, let last = lastProgressDelivery[taskID], now.timeIntervalSince(last) < 0.18 {
            return
        }
        lastProgressDelivery[taskID] = now
        Task { @MainActor [weak self] in
            self?.progressHandler?(id, kind, progress)
        }
    }

    private func deliverFile(id: UUID, kind: String) {
        Task { @MainActor [weak self] in
            self?.fileHandler?(id, kind)
        }
    }

    private func deliverError(id: UUID, kind: String, message: String) {
        Task { @MainActor [weak self] in
            self?.errorHandler?(id, kind, message)
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let (id, kind) = parseTaskDescription(downloadTask.taskDescription) else { return }
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        deliverProgress(id: id, kind: kind, progress: progress, taskID: downloadTask.taskIdentifier, force: false)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let (id, kind) = parseTaskDescription(downloadTask.taskDescription) else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            deliverError(id: id, kind: kind, message: "下载服务器返回错误（HTTP \(http.statusCode)）")
            return
        }

        let destination = AppPaths.mediaURL(for: id, kind: kind)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            AppLog.info("saved \(kind) item=\(id) bytes=\(size)")
            guard size > 10_000 else {
                try? FileManager.default.removeItem(at: destination)
                deliverError(id: id, kind: kind, message: "下载的文件不完整")
                return
            }

            deliverProgress(id: id, kind: kind, progress: 1, taskID: downloadTask.taskIdentifier, force: true)
            deliverFile(id: id, kind: kind)
        } catch {
            deliverError(id: id, kind: kind, message: "无法保存下载文件：\(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let (id, kind) = parseTaskDescription(task.taskDescription) else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        AppLog.error("task \(task.taskIdentifier) \(kind) failed: \(nsError.localizedDescription) code=\(nsError.code)")
        deliverError(id: id, kind: kind, message: nsError.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
