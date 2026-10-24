import Foundation

enum LinkExtractor {
    static func urls(in rawText: String) -> [URL] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var found: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            found.append(url)
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                if let url = match.url {
                    append(url)
                }
            }
        }

        let pattern = #"(?i)(?:https?://)?(?:www\.)?(?:youtube\.com|youtu\.be|youtube-nocookie\.com|t\.me|telegram\.me|telegram\.dog|telegram\.space)/[^\s<>"']+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                var value = String(text[matchRange])
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)]}>」』"))
                if !value.lowercased().hasPrefix("http") {
                    value = "https://" + value
                }
                if let url = URL(string: value) {
                    append(url)
                }
            }
        }

        return found
    }

    static func hasSupportedLink(in rawText: String) -> Bool {
        urls(in: rawText).contains(where: isSupported)
    }

    static func isSupported(_ url: URL) -> Bool {
        YouTubeLink.videoID(from: url) != nil
            || YouTubeLink.isPlaylistLink(url)
            || TelegramLink.parse(url) != nil
    }
}
