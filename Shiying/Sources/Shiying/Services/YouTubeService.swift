import Foundation
import YouTubeKit

struct PreparedMedia: Sendable {
    let videoURL: URL
    let audioURL: URL?
    let resolution: Int?
    let isMuxed: Bool
    let qualityLabel: String
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
            return "这个视频没有 \(resolution)p 或更低的可播放画质，请在设置里选择更高画质"
        case .extractionFailed(let detail):
            return "YouTube 解析失败：\(detail)"
        }
    }
}

enum YouTubeService {
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
        AppLog.info("YouTubeKit returned \(streams.count) streams for \(videoID) requestedMax=\(maxResolution)p")

        let playable: [YouTubeKit.Stream] = streams.filter { $0.isNativelyPlayable }

        var muxedCandidates: [YouTubeKit.Stream] = []
        var videoCandidates: [YouTubeKit.Stream] = []
        var audioCandidates: [YouTubeKit.Stream] = []

        for stream in playable {
            let resolution = stream.videoResolution ?? 0

            if stream.includesVideoAndAudioTrack,
               stream.fileExtension == YouTubeKit.FileExtension.mp4,
               resolution > 0,
               resolution <= maxResolution {
                muxedCandidates.append(stream)
            }

            if stream.includesVideoTrack,
               !stream.includesAudioTrack,
               stream.fileExtension == YouTubeKit.FileExtension.mp4,
               resolution > 0,
               resolution <= maxResolution {
                videoCandidates.append(stream)
            }

            if stream.includesAudioTrack,
               !stream.includesVideoTrack,
               stream.fileExtension == YouTubeKit.FileExtension.m4a {
                audioCandidates.append(stream)
            }
        }

        let muxed = bestVideoStream(in: muxedCandidates)
        let videoOnly = bestVideoStream(in: videoCandidates)
        let audioOnly = audioCandidates.highestAudioBitrateStream()

        AppLog.info("candidates max=\(maxResolution)p muxed=\(muxedCandidates.count) video=\(videoCandidates.count) audio=\(audioCandidates.count) bestVideo=\(videoOnly?.videoResolution ?? 0)p bestMuxed=\(muxed?.videoResolution ?? 0)p")

        // Prefer the highest resolution at or below the requested cap.
        // When video-only and muxed have the same resolution, use the muxed file
        // to avoid saving a separate audio track.
        if let video = videoOnly, let audio = audioOnly,
           (muxed == nil || (video.videoResolution ?? 0) > (muxed?.videoResolution ?? 0)) {
            return PreparedMedia(
                videoURL: video.url,
                audioURL: audio.url,
                resolution: video.videoResolution,
                isMuxed: false,
                qualityLabel: "\(video.videoResolution ?? 0)p"
            )
        }

        if let muxed {
            return PreparedMedia(
                videoURL: muxed.url,
                audioURL: nil,
                resolution: muxed.videoResolution,
                isMuxed: true,
                qualityLabel: "\(muxed.videoResolution ?? 0)p"
            )
        }

        if let video = videoOnly, let audio = audioOnly {
            return PreparedMedia(
                videoURL: video.url,
                audioURL: audio.url,
                resolution: video.videoResolution,
                isMuxed: false,
                qualityLabel: "\(video.videoResolution ?? 0)p"
            )
        }

        if videoOnly != nil {
            throw MediaPreparationError.extractionFailed("只找到无音轨视频，未能匹配音频流")
        }

        throw MediaPreparationError.qualityUnavailable(maxResolution)
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
