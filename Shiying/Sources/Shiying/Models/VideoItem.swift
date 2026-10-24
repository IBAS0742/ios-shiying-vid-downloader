import Foundation

struct VideoItem: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case queued
        case resolving
        case downloading
        case retrying
        case ready
        case failed
    }

    let id: UUID
    let videoID: String
    var sourceURL: String
    var title: String
    var channel: String
    var duration: Double
    var resolution: Int?
    var addedAt: Date
    var status: Status
    var errorMessage: String?
    var hasSeparateAudio: Bool
    var fileSize: Int64
    var isTrashed: Bool
    var playedAt: Date?
    var trashedAt: Date?
    var deleteAfter: Date?
    var retryCount: Int
    var source: MediaSource
    var directMediaURL: String?
    var remoteThumbnailURL: String?

    init(
        id: UUID = UUID(),
        videoID: String,
        sourceURL: String,
        title: String,
        channel: String = "",
        duration: Double = 0,
        addedAt: Date = Date(),
        source: MediaSource = .youtube,
        directMediaURL: String? = nil,
        remoteThumbnailURL: String? = nil
    ) {
        self.id = id
        self.videoID = videoID
        self.sourceURL = sourceURL
        self.title = title
        self.channel = channel
        self.duration = duration
        self.addedAt = addedAt
        self.resolution = nil
        self.status = .queued
        self.errorMessage = nil
        self.hasSeparateAudio = false
        self.fileSize = 0
        self.isTrashed = false
        self.playedAt = nil
        self.trashedAt = nil
        self.deleteAfter = nil
        self.retryCount = 0
        self.source = source
        self.directMediaURL = directMediaURL
        self.remoteThumbnailURL = remoteThumbnailURL
    }

    var thumbnailFileURL: URL {
        AppPaths.thumbnailURL(for: id)
    }

    var videoFileURL: URL {
        AppPaths.mediaURL(for: id, kind: "video")
    }

    var audioFileURL: URL {
        AppPaths.mediaURL(for: id, kind: "audio")
    }

    var isPlayable: Bool {
        status == .ready && FileManager.default.fileExists(atPath: videoFileURL.path)
    }

    var durationText: String {
        guard duration > 0, duration.isFinite else { return "--:--" }
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var resolutionText: String? {
        guard let resolution, resolution > 0 else { return nil }
        return "\(resolution)p"
    }

    var daysUntilDeletion: Int {
        guard let deleteAfter else { return 0 }
        return max(0, Int(ceil(deleteAfter.timeIntervalSinceNow / 86_400)))
    }

    var deletionText: String {
        if daysUntilDeletion <= 0 { return "即将删除" }
        return "\(daysUntilDeletion) 天后删除"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case videoID
        case sourceURL
        case title
        case channel
        case duration
        case resolution
        case addedAt
        case status
        case errorMessage
        case hasSeparateAudio
        case fileSize
        case isTrashed
        case playedAt
        case trashedAt
        case deleteAfter
        case retryCount
        case source
        case directMediaURL
        case remoteThumbnailURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        videoID = try container.decode(String.self, forKey: .videoID)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "视频"
        channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? ""
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .failed
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        hasSeparateAudio = try container.decodeIfPresent(Bool.self, forKey: .hasSeparateAudio) ?? false
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        isTrashed = try container.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        playedAt = try container.decodeIfPresent(Date.self, forKey: .playedAt)
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        deleteAfter = try container.decodeIfPresent(Date.self, forKey: .deleteAfter)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        source = try container.decodeIfPresent(MediaSource.self, forKey: .source) ?? .youtube
        directMediaURL = try container.decodeIfPresent(String.self, forKey: .directMediaURL)
        remoteThumbnailURL = try container.decodeIfPresent(String.self, forKey: .remoteThumbnailURL)
    }
}
