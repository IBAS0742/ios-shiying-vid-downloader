import Foundation

enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shiying", isDirectory: true)
    }()

    static let libraryFile = root.appendingPathComponent("library.json")

    static let telegramRoot = root.appendingPathComponent("Telegram", isDirectory: true)

    static func prepare() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func directory(for id: UUID) -> URL {
        root.appendingPathComponent("Videos", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func mediaURL(for id: UUID, kind: String) -> URL {
        let ext = kind == "audio" ? "m4a" : "mp4"
        return directory(for: id).appendingPathComponent("media-\(kind).\(ext)")
    }

    static func thumbnailURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("thumbnail.jpg")
    }

    static func createDirectory(for id: UUID) {
        try? FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
    }

    static func removeDirectory(for id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
