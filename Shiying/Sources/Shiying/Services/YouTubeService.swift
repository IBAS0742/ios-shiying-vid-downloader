import Foundation
import YouTubeKit

struct PreparedMedia: Sendable {
    let videoURL: URL
    let audioURL: URL?
    let resolution: Int?
    let isMuxed: Bool
    let qualityLabel: String
    /// Set when the requested cap was unavailable and a higher stream was used.
    let upgradedFrom: Int?
}

enum MediaPreparationError: LocalizedError {
    case invalidVideo
    case noPlayableStream
    case qualityUnavailable(Int)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVideo:
            return "无法识别这个 YouTube 链接"
        case .noPlayableStream:
            return "没有找到可下载的 MP4 视频流"
        case .qualityUnavailable(let resolution):
            return "这个视频没有 \(resolution)p–1080p 的原生可播放画质（可能只提供 4K / VP9 / AV1 等格式）"
        case .extractionFailed(let detail):
            return "YouTube 解析失败：\(detail)"
        }
    }
}

enum YouTubeService {
    private struct StreamGroups {
        var muxed: [YouTubeKit.Stream] = []
        var videoOnly: [YouTubeKit.Stream] = []
        var audioOnly: [YouTubeKit.Stream] = []
    }

    static func prepare(videoID: String, maxResolution: Int) async throws -> PreparedMedia {
        let youtube = YouTube(videoID: videoID, methods: [.local, .remote])

        let streams: [YouTubeKit.Stream]
        do {
            streams = try await youtube.streams
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("YouTubeKit streams failed videoID=\(videoID): \(message)")
            throw MediaPreparationError.extractionFailed(message)
        }
        AppLog.info("YouTubeKit returned \(streams.count) streams for videoID=\(videoID) requestedMax=\(maxResolution)p")

        let groups = streamGroups(from: streams.filter { $0.isNativelyPlayable })
        AppLog.info(
            "candidates max=\(maxResolution)p muxed=\(groups.muxed.count) video=\(groups.videoOnly.count) audio=\(groups.audioOnly.count) "
                + "bestMuxed=\(bestVideoStream(in: groups.muxed)?.videoResolution ?? 0)p"
        )

        if let media = selectMedia(from: groups, maxResolution: maxResolution) {
            return media
        }

        if let upgraded = selectUpgrade(from: groups, above: maxResolution) {
            AppLog.info("no playable stream at or below \(maxResolution)p, upgraded to \(upgraded.qualityLabel)")
            return upgraded
        }

        if !groups.videoOnly.isEmpty, groups.audioOnly.isEmpty {
            throw MediaPreparationError.extractionFailed("只找到无音轨视频，未能匹配音频流")
        }

        throw MediaPreparationError.qualityUnavailable(maxResolution)
    }

    private static func streamGroups(from playable: [YouTubeKit.Stream]) -> StreamGroups {
        var groups = StreamGroups()

        for stream in playable {
            let resolution = stream.videoResolution ?? 0

            if stream.includesVideoAndAudioTrack,
               stream.fileExtension == YouTubeKit.FileExtension.mp4,
               resolution > 0 {
                groups.muxed.append(stream)
            }

            if stream.includesVideoTrack,
               !stream.includesAudioTrack,
               stream.fileExtension == YouTubeKit.FileExtension.mp4,
               resolution > 0 {
                groups.videoOnly.append(stream)
            }

            if stream.includesAudioTrack,
               !stream.includesVideoTrack,
               stream.fileExtension == YouTubeKit.FileExtension.m4a {
                groups.audioOnly.append(stream)
            }
        }

        return groups
    }

    /// Picks the highest native-playable stream at or below the requested cap.
    private static func selectMedia(from groups: StreamGroups, maxResolution: Int) -> PreparedMedia? {
        let muxedCandidates = groups.muxed.filter { ($0.videoResolution ?? 0) <= maxResolution }
        let videoCandidates = groups.videoOnly.filter { ($0.videoResolution ?? 0) <= maxResolution }

        let muxed = bestVideoStream(in: muxedCandidates)
        let videoOnly = bestVideoStream(in: videoCandidates)
        let audioOnly = groups.audioOnly.highestAudioBitrateStream()

        // When video-only and muxed have the same resolution, use the muxed file
        // to avoid saving a separate audio track.
        if let video = videoOnly, let audio = audioOnly,
           (muxed == nil || (video.videoResolution ?? 0) > (muxed?.videoResolution ?? 0)) {
            return PreparedMedia(
                videoURL: video.url,
                audioURL: audio.url,
                resolution: video.videoResolution,
                isMuxed: false,
                qualityLabel: "\(video.videoResolution ?? 0)p",
                upgradedFrom: nil
            )
        }

        if let muxed {
            return PreparedMedia(
                videoURL: muxed.url,
                audioURL: nil,
                resolution: muxed.videoResolution,
                isMuxed: true,
                qualityLabel: "\(muxed.videoResolution ?? 0)p",
                upgradedFrom: nil
            )
        }

        if let video = videoOnly, let audio = audioOnly {
            return PreparedMedia(
                videoURL: video.url,
                audioURL: audio.url,
                resolution: video.videoResolution,
                isMuxed: false,
                qualityLabel: "\(video.videoResolution ?? 0)p",
                upgradedFrom: nil
            )
        }

        return nil
    }

    /// Used only when nothing exists at or below the requested cap: picks the
    /// lowest available resolution above it, so a failed 360p item becomes 480p
    /// or 720p instead of failing outright.
    private static func selectUpgrade(from groups: StreamGroups, above resolution: Int) -> PreparedMedia? {
        let audio = groups.audioOnly.highestAudioBitrateStream()
        let hardCap = 1080

        var available = Set<Int>()
        for stream in groups.muxed {
            if let value = stream.videoResolution, value > resolution, value <= hardCap {
                available.insert(value)
            }
        }
        if audio != nil {
            for stream in groups.videoOnly {
                if let value = stream.videoResolution, value > resolution, value <= hardCap {
                    available.insert(value)
                }
            }
        }

        for candidate in available.sorted() {
            if let muxed = bestVideoStream(in: groups.muxed.filter { $0.videoResolution == candidate }) {
                return PreparedMedia(
                    videoURL: muxed.url,
                    audioURL: nil,
                    resolution: muxed.videoResolution,
                    isMuxed: true,
                    qualityLabel: "\(candidate)p",
                    upgradedFrom: resolution
                )
            }
            if let video = bestVideoStream(in: groups.videoOnly.filter { $0.videoResolution == candidate }),
               let audio {
                return PreparedMedia(
                    videoURL: video.url,
                    audioURL: audio.url,
                    resolution: video.videoResolution,
                    isMuxed: false,
                    qualityLabel: "\(candidate)p",
                    upgradedFrom: resolution
                )
            }
        }

        return nil
    }

    private static func bestVideoStream(in streams: [YouTubeKit.Stream]) -> YouTubeKit.Stream? {
        streams.max { lhs, rhs in
            let lhsResolution = lhs.videoResolution ?? 0
            let rhsResolution = rhs.videoResolution ?? 0
            if lhsResolution != rhsResolution {
                return lhsResolution < rhsResolution
            }
            return (lhs.bitrate ?? 0) < (rhs.bitrate ?? 0)
        }
    }
}
