import Foundation

private enum DownloadRangeValidation {
    struct ContentRange: Equatable {
        let start: Int64
        let end: Int64
        let total: Int64
    }

    static func parse(_ value: String?) -> ContentRange? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        func decimal(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        guard bounds.count == 2,
              let start = decimal(bounds[0]), let end = decimal(bounds[1]),
              let total = decimal(fields[1]), start <= end, end < total else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    static func partRange(index: Int, count: Int, total: Int64) -> ContentRange? {
        guard count > 0, total > 0, Int64(count) <= total,
              index >= 0, index < count else { return nil }
        let chunk = total / Int64(count)
        return ContentRange(
            start: Int64(index) * chunk,
            end: index == count - 1 ? total - 1 : Int64(index + 1) * chunk - 1,
            total: total
        )
    }

    static func matches(status: Int?, header: String?, range: ContentRange) -> Bool {
        status == 206 && parse(header) == range
    }

    static func isComplete(status: Int?, header: String?, size: Int64) -> Bool {
        guard status == 206, let range = parse(header) else { return false }
        return range.start == 0 && range.end == range.total - 1 && size == range.total
    }
}

final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    static let sessionIdentifier = "com.ibas.shiying.downloads"

    var progressHandler: (@MainActor (UUID, String, Double, Int64) -> Void)?
    var fileHandler: (@MainActor (UUID, String) -> Void)?
    var errorHandler: (@MainActor (UUID, String, String) -> Void)?

    private var session: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?
    private let delegateQueue = OperationQueue()
    private let stateQueue = DispatchQueue(label: "com.ibas.shiying.downloads.state")
    private let progressLock = NSLock()
    private var lastProgressDelivery: [Int: Date] = [:]

    private struct TaskMeta {
        let itemID: UUID
        let kind: String
        let partIndex: Int?
        let partCount: Int
        let rangeStart: Int64
        let rangeEnd: Int64
        let totalBytes: Int64
    }

    private var partBytes: [UUID: [String: [Int: Int64]]] = [:]
    private var completedParts: [UUID: [String: Set<Int>]] = [:]
    private var finishedKinds: [UUID: Set<String>] = [:]
    private var splitDisabled: [UUID: Set<String>] = [:]
    private var sourceURLs: [UUID: [String: URL]] = [:]
    private var cancelledItems: Set<UUID> = []
    private var attemptTokens: [UUID: UUID] = [:]

    private override init() {
        super.init()
        delegateQueue.name = "com.ibas.shiying.downloads.delegate"
        delegateQueue.maxConcurrentOperationCount = 1

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    func start(itemID: UUID, videoURL: URL, audioURL: URL?, segments: Int = 1) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let token = UUID()
            self.attemptTokens[itemID] = token
            self.cancelledItems.remove(itemID)
            self.finishedKinds[itemID] = nil
            self.splitDisabled[itemID] = nil
            self.partBytes[itemID] = nil
            self.completedParts[itemID] = nil

            var urls: [String: URL] = ["video": videoURL]
            if let audioURL {
                urls["audio"] = audioURL
            }
            self.sourceURLs[itemID] = urls

            self.prepareFile(itemID: itemID, kind: "video", url: videoURL, segments: segments, token: token)
            if let audioURL {
                self.prepareFile(itemID: itemID, kind: "audio", url: audioURL, segments: segments, token: token)
            }
        }
    }

    private func prepareFile(itemID: UUID, kind: String, url: URL, segments: Int, token: UUID) {
        removeParts(itemID: itemID, kind: kind)

        guard segments > 1 else {
            startSingle(itemID: itemID, kind: kind, url: url)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let probe = await Self.probe(url: url)
            self.stateQueue.async { [weak self] in
                guard let self,
                      self.attemptTokens[itemID] == token,
                      !self.cancelledItems.contains(itemID) else { return }

                let count = probe.map { Self.partCount(totalBytes: $0.totalBytes, requested: segments) } ?? 1
                if let probe, probe.supportsRanges, count > 1 {
                    self.startSplit(
                        itemID: itemID,
                        kind: kind,
                        url: url,
                        totalBytes: probe.totalBytes,
                        count: count
                    )
                } else {
                    self.startSingle(itemID: itemID, kind: kind, url: url)
                }
            }
        }
    }

    private struct ProbeResult {
        let totalBytes: Int64
        let supportsRanges: Bool
    }

    /// Asks for one byte so we learn both the total size and whether the
    /// server honors `Range`. A HEAD request is not reliable here because
    /// some CDNs reject it or omit `Accept-Ranges`.
    private static func probe(url: URL) async -> ProbeResult? {
        var request = URLRequest(url: urlWithoutRangeParameter(url))
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let probeSession = URLSession(configuration: configuration)
        defer { probeSession.finishTasksAndInvalidate() }

        do {
            let (bytes, response) = try await probeSession.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return nil }

            guard http.statusCode == 206,
                  let range = DownloadRangeValidation.parse(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == 0, range.end == 0 else { return nil }
            return ProbeResult(totalBytes: range.total, supportsRanges: true)
        } catch {
            AppLog.info("range probe failed host=\(url.host ?? "nil"): \(error.localizedDescription)")
            return nil
        }
    }

    private static func partCount(totalBytes: Int64, requested: Int) -> Int {
        let minimumPartSize: Int64 = 6 * 1024 * 1024
        let sizeLimited = Int(totalBytes / minimumPartSize)
        return max(1, min(requested, sizeLimited))
    }

    private func startSingle(itemID: UUID, kind: String, url: URL) {
        removeParts(itemID: itemID, kind: kind)
        let task = session.downloadTask(with: Self.urlWithoutRangeParameter(url))
        task.taskDescription = "\(itemID.uuidString)|\(kind)"
        task.resume()
        AppLog.info("enqueue \(kind) task \(task.taskIdentifier) item=\(itemID)")
    }

    private func startSplit(itemID: UUID, kind: String, url: URL, totalBytes: Int64, count: Int) {
        var bytesByKind = partBytes[itemID] ?? [:]
        bytesByKind[kind] = [:]
        partBytes[itemID] = bytesByKind

        var completedByKind = completedParts[itemID] ?? [:]
        completedByKind[kind] = []
        completedParts[itemID] = completedByKind

        let requestURL = Self.urlWithoutRangeParameter(url)
        let chunk = totalBytes / Int64(count)

        for index in 0..<count {
            let start = Int64(index) * chunk
            let end = index == count - 1 ? totalBytes - 1 : (Int64(index + 1) * chunk - 1)
            guard end >= start else { continue }

            var request = URLRequest(url: requestURL)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 60

            let task = session.downloadTask(with: request)
            task.taskDescription = "\(itemID.uuidString)|\(kind)|p|\(index)|\(count)|\(start)|\(end)|\(totalBytes)"
            task.resume()
            AppLog.info("enqueue \(kind) part \(index + 1)/\(count) task \(task.taskIdentifier) item=\(itemID) bytes=\(start)-\(end)")
        }
    }

    func cancel(itemID: UUID) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.cancelledItems.insert(itemID)
            self.attemptTokens[itemID] = nil
            self.finishedKinds[itemID] = nil
            self.splitDisabled[itemID] = nil
            self.partBytes[itemID] = nil
            self.completedParts[itemID] = nil
            self.sourceURLs[itemID] = nil
            self.removeParts(itemID: itemID, kind: "video")
            self.removeParts(itemID: itemID, kind: "audio")

            let prefix = itemID.uuidString + "|"
            self.session.getAllTasks { tasks in
                tasks.filter { $0.taskDescription?.hasPrefix(prefix) == true }.forEach { $0.cancel() }
            }
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
        let prefix = "\(itemID.uuidString)|\(kind)"
        return await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.contains {
                    $0.taskDescription?.hasPrefix(prefix) == true
                })
            }
        }
    }

    private static func urlWithoutRangeParameter(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let filtered = components.queryItems?.filter { $0.name.lowercased() != "range" }
        components.queryItems = (filtered?.isEmpty ?? true) ? nil : filtered
        return components.url ?? url
    }

    private func parseTaskDescription(_ description: String?) -> TaskMeta? {
        guard let description else { return nil }
        let parts = description.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let id = UUID(uuidString: parts[0]),
              ["video", "audio"].contains(parts[1]) else { return nil }

        if parts.count != 2 {
            guard parts.count == 8, parts[2] == "p",
                  let index = Int(parts[3]),
                  let count = Int(parts[4]),
                  let start = Int64(parts[5]),
                  let end = Int64(parts[6]),
                  let total = Int64(parts[7]),
                  DownloadRangeValidation.partRange(index: index, count: count, total: total)
                    == DownloadRangeValidation.ContentRange(start: start, end: end, total: total) else { return nil }
            return TaskMeta(
                itemID: id,
                kind: parts[1],
                partIndex: index,
                partCount: count,
                rangeStart: start,
                rangeEnd: end,
                totalBytes: total
            )
        }

        return TaskMeta(
            itemID: id,
            kind: parts[1],
            partIndex: nil,
            partCount: 1,
            rangeStart: 0,
            rangeEnd: 0,
            totalBytes: 0
        )
    }

    private func claimCompletion(itemID: UUID, kind: String) -> Bool {
        var claimed = false
        stateQueue.sync {
            var kinds = finishedKinds[itemID] ?? []
            if !kinds.contains(kind) {
                kinds.insert(kind)
                finishedKinds[itemID] = kinds
                claimed = true
            }
        }
        return claimed
    }

    private func releaseCompletion(itemID: UUID, kind: String) {
        stateQueue.sync {
            guard var kinds = finishedKinds[itemID] else { return }
            kinds.remove(kind)
            finishedKinds[itemID] = kinds
        }
    }

    private func removeParts(itemID: UUID, kind: String) {
        try? FileManager.default.removeItem(at: AppPaths.partsDirectory(for: itemID, kind: kind))
    }

    private static func validatedParts(in directory: URL, count: Int, total: Int64) -> [Int: Int64]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var sizes: [Int: Int64] = [:]
        for name in names {
            guard name.hasPrefix("part-"), let index = Int(name.dropFirst(5)),
                  name == "part-\(index)",
                  let range = DownloadRangeValidation.partRange(index: index, count: count, total: total),
                  let values = try? directory.appendingPathComponent(name)
                    .resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize,
                  Int64(size) == range.end - range.start + 1 else { return nil }
            sizes[index] = Int64(size)
        }
        return sizes
    }

    private struct MergeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func mergeParts(itemID: UUID, kind: String, count: Int, total: Int64) -> Result<Int64, MergeError> {
        let directory = AppPaths.partsDirectory(for: itemID, kind: kind)
        let destination = AppPaths.mediaURL(for: itemID, kind: kind)

        do {
            guard let parts = validatedParts(in: directory, count: count, total: total),
                  parts.count == count else {
                return .failure(MergeError(message: "下载的分片不完整"))
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                return .failure(MergeError(message: "无法创建下载文件"))
            }

            let writer = try FileHandle(forWritingTo: destination)
            defer { try? writer.close() }

            for index in 0..<count {
                let partURL = directory.appendingPathComponent("part-\(index)")
                let reader = try FileHandle(forReadingFrom: partURL)
                while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try writer.write(contentsOf: data)
                }
                try? reader.close()
            }

            let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size == total else {
                try? FileManager.default.removeItem(at: destination)
                return .failure(MergeError(message: "下载的文件不完整"))
            }
            try? FileManager.default.removeItem(at: directory)
            return .success(size)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(MergeError(message: "无法合并分片：\(error.localizedDescription)"))
        }
    }

    private func finishSingle(meta: TaskMeta, location: URL) {
        guard claimCompletion(itemID: meta.itemID, kind: meta.kind) else {
            try? FileManager.default.removeItem(at: location)
            return
        }

        let destination = AppPaths.mediaURL(for: meta.itemID, kind: meta.kind)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 10_000 else {
                try? FileManager.default.removeItem(at: destination)
                releaseCompletion(itemID: meta.itemID, kind: meta.kind)
                deliverError(id: meta.itemID, kind: meta.kind, message: "下载的文件不完整")
                return
            }

            stateQueue.sync {
                partBytes[meta.itemID]?[meta.kind] = nil
                completedParts[meta.itemID]?[meta.kind] = nil
            }
            removeParts(itemID: meta.itemID, kind: meta.kind)
            AppLog.info("saved \(meta.kind) item=\(meta.itemID) bytes=\(size)")
            deliverProgress(id: meta.itemID, kind: meta.kind, progress: 1, bytes: size, taskID: 0, force: true)
            deliverFile(id: meta.itemID, kind: meta.kind)
        } catch {
            releaseCompletion(itemID: meta.itemID, kind: meta.kind)
            deliverError(id: meta.itemID, kind: meta.kind, message: "无法保存下载文件：\(error.localizedDescription)")
        }
    }

    private func finishPart(meta: TaskMeta, location: URL) {
        guard let index = meta.partIndex else { return }

        let directory = AppPaths.partsDirectory(for: meta.itemID, kind: meta.kind)
        let partURL = directory.appendingPathComponent("part-\(index)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: partURL.path) {
                try FileManager.default.removeItem(at: partURL)
            }
            try FileManager.default.moveItem(at: location, to: partURL)
        } catch {
            abortSplit(
                itemID: meta.itemID,
                kind: meta.kind,
                message: "无法保存分片：\(error.localizedDescription)",
                fallbackToSingle: false
            )
            return
        }

        let expected = meta.rangeEnd - meta.rangeStart + 1
        let size = Int64((try? partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size == expected else {
            // A short part means the CDN did not honor the range. Stop the
            // siblings so a corrupt fragment is never merged.
            abortSplit(
                itemID: meta.itemID,
                kind: meta.kind,
                message: "分片不完整（\(size)/\(expected) 字节）",
                fallbackToSingle: true
            )
            return
        }

        var allDone = false
        var isCancelled = false
        var invalidParts = false
        stateQueue.sync {
            if cancelledItems.contains(meta.itemID)
                || splitDisabled[meta.itemID]?.contains(meta.kind) == true {
                isCancelled = true
                return
            }

            guard let onDisk = Self.validatedParts(in: directory, count: meta.partCount, total: meta.totalBytes) else {
                invalidParts = true
                return
            }
            let completed = Set(onDisk.keys)
            var bytesByPart = partBytes[meta.itemID]?[meta.kind] ?? [:]
            for (diskIndex, diskSize) in onDisk {
                bytesByPart[diskIndex] = diskSize
            }

            var kinds = partBytes[meta.itemID] ?? [:]
            kinds[meta.kind] = bytesByPart
            partBytes[meta.itemID] = kinds

            var completedByKind = completedParts[meta.itemID] ?? [:]
            completedByKind[meta.kind] = completed
            completedParts[meta.itemID] = completedByKind

            allDone = completed.count == meta.partCount
        }

        if isCancelled {
            removeParts(itemID: meta.itemID, kind: meta.kind)
            return
        }

        if invalidParts {
            abortSplit(itemID: meta.itemID, kind: meta.kind, message: "已保存的分片范围或长度无效", fallbackToSingle: true)
            return
        }

        if allDone {
            mergeAndFinish(meta: meta, count: meta.partCount)
        } else {
            let aggregate = stateQueue.sync {
                (partBytes[meta.itemID]?[meta.kind] ?? [:]).values.reduce(0, +)
            }
            let progress = meta.totalBytes > 0
                ? min(1, Double(aggregate) / Double(meta.totalBytes))
                : 0
            deliverProgress(
                id: meta.itemID,
                kind: meta.kind,
                progress: progress,
                bytes: aggregate,
                taskID: 0,
                force: false
            )
        }
    }

    private func mergeAndFinish(meta: TaskMeta, count: Int) {
        guard claimCompletion(itemID: meta.itemID, kind: meta.kind) else {
            removeParts(itemID: meta.itemID, kind: meta.kind)
            return
        }

        switch Self.mergeParts(itemID: meta.itemID, kind: meta.kind, count: count, total: meta.totalBytes) {
        case .success(let size):
            stateQueue.sync {
                partBytes[meta.itemID]?[meta.kind] = nil
                completedParts[meta.itemID]?[meta.kind] = nil
            }
            AppLog.info("merged \(count) parts \(meta.kind) item=\(meta.itemID) bytes=\(size)")
            deliverProgress(id: meta.itemID, kind: meta.kind, progress: 1, bytes: size, taskID: 0, force: true)
            deliverFile(id: meta.itemID, kind: meta.kind)
        case .failure(let error):
            releaseCompletion(itemID: meta.itemID, kind: meta.kind)
            abortSplit(itemID: meta.itemID, kind: meta.kind, message: error.message, fallbackToSingle: true)
        }
    }

    private func shouldDeliverProgress(taskID: Int, force: Bool) -> Bool {
        progressLock.lock()
        defer { progressLock.unlock() }
        let now = Date()
        if !force, let last = lastProgressDelivery[taskID], now.timeIntervalSince(last) < 0.18 {
            return false
        }
        lastProgressDelivery[taskID] = now
        return true
    }

    private func deliverProgress(id: UUID, kind: String, progress: Double, bytes: Int64, taskID: Int, force: Bool) {
        guard shouldDeliverProgress(taskID: taskID, force: force) else { return }
        Task { @MainActor [weak self] in
            self?.progressHandler?(id, kind, progress, bytes)
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

    /// Stops a split download when one part is unusable, so remaining parts
    /// cannot merge into a file with a hole or a truncated fragment. When the
    /// server merely ignored the byte range, re-download the file over one
    /// connection instead of failing the item.
    private func abortSplit(itemID: UUID, kind: String, message: String, fallbackToSingle: Bool, sourceURL: URL? = nil) {
        stateQueue.async { [weak self] in
            guard let self,
                  self.splitDisabled[itemID]?.contains(kind) != true else { return }
            if self.sourceURLs[itemID]?[kind] == nil, let sourceURL {
                self.sourceURLs[itemID, default: [:]][kind] = Self.urlWithoutRangeParameter(sourceURL)
            }
            var disabled = self.splitDisabled[itemID] ?? []
            disabled.insert(kind)
            self.splitDisabled[itemID] = disabled

            var bytesByKind = self.partBytes[itemID] ?? [:]
            bytesByKind[kind] = nil
            self.partBytes[itemID] = bytesByKind

            var completedByKind = self.completedParts[itemID] ?? [:]
            completedByKind[kind] = []
            self.completedParts[itemID] = completedByKind

            self.removeParts(itemID: itemID, kind: kind)

            let prefix = "\(itemID.uuidString)|\(kind)|p|"
            self.session.getAllTasks { tasks in
                tasks.filter { $0.taskDescription?.hasPrefix(prefix) == true }.forEach { $0.cancel() }
            }
            AppLog.error("split aborted \(kind) item=\(itemID): \(message)")

            guard fallbackToSingle,
                  !self.cancelledItems.contains(itemID),
                  let url = self.sourceURLs[itemID]?[kind] else { return }
            AppLog.info("falling back to a single connection for \(kind) item=\(itemID)")
            self.startSingle(itemID: itemID, kind: kind, url: url)
        }
        if !fallbackToSingle {
            deliverError(id: itemID, kind: kind, message: message)
        }
    }

    private func acceptsPartResponse(_ response: URLResponse?, meta: TaskMeta) -> Bool {
        let http = response as? HTTPURLResponse
        return DownloadRangeValidation.matches(
            status: http?.statusCode,
            header: http?.value(forHTTPHeaderField: "Content-Range"),
            range: .init(start: meta.rangeStart, end: meta.rangeEnd, total: meta.totalBytes)
        )
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
        guard let meta = parseTaskDescription(downloadTask.taskDescription) else { return }

        if let partIndex = meta.partIndex {
            guard acceptsPartResponse(downloadTask.response, meta: meta) else {
                downloadTask.cancel()
                abortSplit(itemID: meta.itemID, kind: meta.kind, message: "分片响应范围无效", fallbackToSingle: true, sourceURL: downloadTask.originalRequest?.url)
                return
            }

            let partLength = meta.rangeEnd - meta.rangeStart + 1
            let written = min(totalBytesWritten, partLength)
            let taskID = downloadTask.taskIdentifier

            stateQueue.async { [weak self] in
                guard let self,
                      self.splitDisabled[meta.itemID]?.contains(meta.kind) != true else { return }

                var parts = self.partBytes[meta.itemID]?[meta.kind] ?? [:]
                parts[partIndex] = max(parts[partIndex] ?? 0, written)
                var kinds = self.partBytes[meta.itemID] ?? [:]
                kinds[meta.kind] = parts
                self.partBytes[meta.itemID] = kinds

                guard meta.totalBytes > 0 else { return }
                let aggregate = parts.values.reduce(0, +)
                self.deliverProgress(
                    id: meta.itemID,
                    kind: meta.kind,
                    progress: min(1, Double(aggregate) / Double(meta.totalBytes)),
                    bytes: aggregate,
                    taskID: taskID,
                    force: false
                )
            }
            return
        }

        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        deliverProgress(
            id: meta.itemID,
            kind: meta.kind,
            progress: progress,
            bytes: totalBytesWritten,
            taskID: downloadTask.taskIdentifier,
            force: false
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let meta = parseTaskDescription(downloadTask.taskDescription) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let statusCode = http?.statusCode

        if meta.partIndex != nil {
            stateQueue.sync {
                if sourceURLs[meta.itemID]?[meta.kind] == nil, let url = downloadTask.originalRequest?.url {
                    sourceURLs[meta.itemID, default: [:]][meta.kind] = Self.urlWithoutRangeParameter(url)
                }
            }
            guard acceptsPartResponse(downloadTask.response, meta: meta) else {
                try? FileManager.default.removeItem(at: location)
                abortSplit(itemID: meta.itemID, kind: meta.kind, message: "分片响应范围无效", fallbackToSingle: true, sourceURL: downloadTask.originalRequest?.url)
                return
            }
            finishPart(meta: meta, location: location)
            return
        }

        let size = Int64((try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard statusCode == 200 || DownloadRangeValidation.isComplete(
            status: statusCode, header: http?.value(forHTTPHeaderField: "Content-Range"), size: size
        ) else {
            try? FileManager.default.removeItem(at: location)
            deliverError(id: meta.itemID, kind: meta.kind, message: "下载服务器返回无效或不完整的响应")
            return
        }
        finishSingle(meta: meta, location: location)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let meta = parseTaskDescription(task.taskDescription) else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        AppLog.error("task \(task.taskIdentifier) \(meta.kind) failed: \(nsError.localizedDescription) code=\(nsError.code)")
        deliverError(id: meta.itemID, kind: meta.kind, message: nsError.localizedDescription)
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
