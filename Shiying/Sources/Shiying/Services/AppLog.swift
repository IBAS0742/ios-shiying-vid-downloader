import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "com.ibas.shiying.applog")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static var logFileURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("ShiyingLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("shiying.log")
    }

    static var logPath: String {
        logFileURL?.path ?? "(unavailable)"
    }

    static func info(_ message: String) {
        write("I", message)
    }

    static func error(_ message: String) {
        write("E", message)
    }

    private static func write(_ level: String, _ message: String) {
        NSLog("[Shiying][%@] %@", level, message)
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            guard let url = logFileURL else { return }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue > 512 * 1024 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    // Logging must never take the app down.
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
