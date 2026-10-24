import Foundation

enum MediaSource: String, Codable, CaseIterable, Sendable {
    case youtube
    case telegram

    var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .telegram: return "Telegram"
        }
    }

    var shortLabel: String {
        switch self {
        case .youtube: return "YT"
        case .telegram: return "TG"
        }
    }

    var icon: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .telegram: return "paperplane.fill"
        }
    }

    var accentHex: UInt {
        switch self {
        case .youtube: return 0xFF5E68
        case .telegram: return 0x59A9E8
        }
    }
}
