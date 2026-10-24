import Foundation

enum YouTubeLink {
    static func videoID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host.contains("youtu.be"), let first = pathComponents.first {
            return normalizedID(first)
        }

        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value {
                return normalizedID(v)
            }

            if pathComponents.count >= 2 {
                let first = pathComponents[0].lowercased()
                if ["shorts", "live", "embed", "v"].contains(first) {
                    return normalizedID(pathComponents[1])
                }
            }
        }

        return videoID(in: url.absoluteString)
    }

    static func videoID(in rawText: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|shorts/|live/|embed/)|youtu\.be/)([0-9A-Za-z_-]{11})"#,
            #"(?:[?&]v=)([0-9A-Za-z_-]{11})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
            if let match = regex.firstMatch(in: rawText, options: [], range: range),
               let idRange = Range(match.range(at: 1), in: rawText) {
                return String(rawText[idRange])
            }
        }
        return nil
    }

    static func extractURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    static func playlistID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        guard host.contains("youtube.com") || host.contains("youtube-nocookie.com") else { return nil }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "list" })?.value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// A watch link with both `v` and `list` is treated as a single video; the
    /// playlist is only imported when the link itself points at a playlist.
    static func playlistIDForImport(from url: URL) -> String? {
        guard let id = playlistID(from: url) else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let hasVideo = components?.queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true
        if hasVideo { return nil }
        let supportedPrefixes = ["PL", "UU", "OL", "FL", "LL", "VL", "TL"]
        guard supportedPrefixes.contains(where: { id.hasPrefix($0) }) else { return nil }
        return id
    }

    static func isPlaylistLink(_ url: URL) -> Bool {
        playlistID(from: url) != nil
    }

    static func canonicalURL(videoID: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    private static func normalizedID(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/?&"))
        guard cleaned.count == 11 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return cleaned
    }
}
