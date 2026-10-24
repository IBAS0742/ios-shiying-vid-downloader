import Foundation

enum DownloadQuality: String, CaseIterable, Identifiable, Codable {
    case best
    case p1080
    case p720
    case p480
    case p360

    var id: String { rawValue }

    /// 当前下载器只使用 iPhone 原生可播放的 MP4/H.264 视频流，
    /// YouTube 的 1440p/2160p 通常是 VP9/AV1，无法稳定原生播放或画中画。
    var maxResolution: Int {
        switch self {
        case .best, .p1080:
            return 1080
        case .p720:
            return 720
        case .p480:
            return 480
        case .p360:
            return 360
        }
    }

    var title: String {
        switch self {
        case .best:
            return "最高可用（最高 1080p）"
        case .p1080:
            return "1080p 高清"
        case .p720:
            return "720p"
        case .p480:
            return "480p 省空间"
        case .p360:
            return "360p 最小体积"
        }
    }

    var shortLabel: String {
        switch self {
        case .best:
            return "自动 · 1080p"
        case .p1080:
            return "1080p"
        case .p720:
            return "720p"
        case .p480:
            return "480p"
        case .p360:
            return "360p"
        }
    }

    var detail: String {
        switch self {
        case .best:
            return "自动选择不超过 1080p 的最高画质"
        case .p1080:
            return "最清晰，占用空间最大"
        case .p720:
            return "清晰度和文件体积较平衡"
        case .p480:
            return "适合保存较多视频"
        case .p360:
            return "下载最快，占用空间最小"
        }
    }

    var icon: String {
        switch self {
        case .best:
            return "sparkles"
        case .p1080:
            return "4k.tv"
        case .p720:
            return "rectangle.inset.filled"
        case .p480:
            return "rectangle.compress.vertical"
        case .p360:
            return "arrow.down.circle"
        }
    }
}
