import AVFoundation
import Foundation

enum PlaybackError: LocalizedError {
    case missingFiles
    case noVideoTrack
    case noAudioTrack
    case invalidAsset

    var errorDescription: String? {
        switch self {
        case .missingFiles:
            return "视频文件不存在，可能已被清理"
        case .noVideoTrack:
            return "无法读取视频轨道"
        case .noAudioTrack:
            return "无法读取音频轨道"
        case .invalidAsset:
            return "视频格式无法播放"
        }
    }
}

enum PlaybackAssetBuilder {
    static func makeAsset(for item: VideoItem) async throws -> AVAsset {
        guard FileManager.default.fileExists(atPath: item.videoFileURL.path) else {
            throw PlaybackError.missingFiles
        }

        if !item.hasSeparateAudio {
            return AVURLAsset(url: item.videoFileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        }

        guard FileManager.default.fileExists(atPath: item.audioFileURL.path) else {
            throw PlaybackError.missingFiles
        }

        let videoAsset = AVURLAsset(
            url: item.videoFileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioAsset = AVURLAsset(
            url: item.audioFileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw PlaybackError.noVideoTrack
        }
        guard let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw PlaybackError.noAudioTrack
        }

        // AVFoundation reports double the real duration for YouTube DASH fMP4,
        // so derive the true bounds from the container's mdhd boxes instead.
        let videoSeconds = try realDuration(fileURL: item.videoFileURL, kind: "vide")
        let audioSeconds = try realDuration(fileURL: item.audioFileURL, kind: "soun")
        let durationSeconds = min(videoSeconds, audioSeconds)
        guard durationSeconds > 0, durationSeconds.isFinite else {
            throw PlaybackError.invalidAsset
        }

        let start = CMTime.zero
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PlaybackError.invalidAsset
        }

        try videoTrack.insertTimeRange(
            CMTimeRange(start: start, duration: duration),
            of: sourceVideo,
            at: .zero
        )
        try audioTrack.insertTimeRange(
            CMTimeRange(start: start, duration: duration),
            of: sourceAudio,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        return composition
    }

    private static func realDuration(fileURL: URL, kind: String) throws -> Double {
        let tracks = try MP4Probe.trackDurations(fileURL: fileURL)
        if let match = tracks.first(where: { $0.kind == kind }) {
            return match.durationSeconds
        }
        if let fallback = tracks.first(where: { $0.durationSeconds > 0 }) {
            return fallback.durationSeconds
        }
        throw PlaybackError.invalidAsset
    }
}
