import Foundation

enum TelegramLink: Equatable, Sendable {
    case channel(username: String)
    case post(username: String, id: Int)

    var username: String {
        switch self {
        case .channel(let username): return username
        case .post(let username, _): return username
        }
    }

    static func parse(_ url: URL) -> TelegramLink? {
        let host = (url.host ?? "").lowercased()
        let knownHosts = [
            "t.me", "www.t.me",
            "telegram.me", "www.telegram.me",
            "telegram.dog", "www.telegram.dog",
            "telegram.space", "www.telegram.space",
        ]
        guard knownHosts.contains(host) else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first?.lowercased(), !first.isEmpty else { return nil }
        let reserved: Set<String> = [
            "c", "joinchat", "addstickers", "share", "iv", "proxy", "socks",
            "login", "confirmphone", "setlanguage", "addemoji",
        ]
        guard !reserved.contains(first) else { return nil }

        if first == "s" {
            guard parts.count >= 2, validUsername(parts[1]) else { return nil }
            return .channel(username: parts[1])
        }

        if parts.count >= 2, let postID = Int(parts[1]) {
            guard validUsername(parts[0]) else { return nil }
            return .post(username: parts[0], id: postID)
        }

        if parts.count == 1, validUsername(parts[0]) {
            return .channel(username: parts[0])
        }

        return nil
    }

    private static func validUsername(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard name.count >= 3, name.count <= 64 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

struct TelegramVideo: Sendable {
    let username: String
    let channelTitle: String
    let postID: Int
    let index: Int
    let title: String
    let mediaURL: URL
    let thumbnailURL: URL?
    let publishedAt: Date?

    var itemKey: String {
        "tg:\(username.lowercased()):\(postID):\(index)"
    }
}

struct TelegramBatch: Sendable {
    let title: String
    let videos: [TelegramVideo]
}

enum TelegramServiceError: LocalizedError {
    case notFound
    case privateChannel
    case noVideo
    case mediaTooLarge
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到这个 Telegram 频道或帖子"
        case .privateChannel:
            return "这是私密频道/群组，拾影未登录 Telegram，无法读取"
        case .noVideo:
            return "这个 Telegram 链接里没有找到可直接下载的视频"
        case .mediaTooLarge:
            return "这条视频超过 Telegram 网页预览的大小上限（约 20MB）。在设置里扫码登录 Telegram 后即可下载"
        case .network(let detail):
            return "Telegram 读取失败：\(detail)"
        }
    }
}

enum TelegramService {
    static func fetch(link: TelegramLink) async throws -> TelegramBatch {
        switch link {
        case .channel(let username):
            return try await fetchChannel(username: username)
        case .post(let username, let id):
            return try await fetchPost(username: username, postID: id)
        }
    }

    private static func fetchChannel(username: String) async throws -> TelegramBatch {
        let previewURL = "https://t.me/s/\(username)"
        let html = try await fetchHTML(previewURL)
        var batch = parse(html: html, username: username, sortNewestFirst: true)
        if batch.videos.isEmpty {
            let fallback = try await fetchHTML("https://t.me/\(username)")
            let second = parse(html: fallback, username: username, sortNewestFirst: true)
            if !second.videos.isEmpty {
                batch = second
            } else if hasTooLargeMedia(in: html) || hasTooLargeMedia(in: fallback) {
                throw TelegramServiceError.mediaTooLarge
            }
        }
        guard !batch.videos.isEmpty else { throw TelegramServiceError.noVideo }
        return batch
    }

    private static func fetchPost(username: String, postID: Int) async throws -> TelegramBatch {
        let pageURL = "https://t.me/\(username)/\(postID)"
        let html = try await fetchHTML(pageURL)
        var batch = parse(html: html, username: username, sortNewestFirst: false)
        if batch.videos.isEmpty {
            let embedHTML = try await fetchHTML("\(pageURL)?embed=1&mode=tme")
            let embedded = parse(
                html: embedHTML,
                username: username,
                sortNewestFirst: false,
                channelTitleOverride: channelTitle(from: html)
            )
            if !embedded.videos.isEmpty {
                batch = embedded
            } else if hasTooLargeMedia(in: html) || hasTooLargeMedia(in: embedHTML) {
                throw TelegramServiceError.mediaTooLarge
            }
        }
        guard !batch.videos.isEmpty else { throw TelegramServiceError.noVideo }
        return batch
    }

    /// Public t.me pages replace large videos with a "Media is too big" notice
    /// and expose no file URL at all.
    private static func hasTooLargeMedia(in html: String) -> Bool {
        html.range(of: "media is too big", options: .caseInsensitive) != nil
    }

    // MARK: - Networking

    private static func fetchHTML(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw TelegramServiceError.network("链接格式错误")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        var fetched: (Data, URLResponse)?
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                fetched = try await URLSession.shared.data(for: request)
                break
            } catch {
                lastError = error
                AppLog.error("telegram fetch attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        guard let (data, response) = fetched else {
            throw TelegramServiceError.network(lastError?.localizedDescription ?? "网络请求失败")
        }

        guard let http = response as? HTTPURLResponse else {
            throw TelegramServiceError.network("没有收到服务器响应")
        }
        if http.statusCode == 404 {
            throw TelegramServiceError.notFound
        }
        if http.statusCode == 403 {
            throw TelegramServiceError.privateChannel
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TelegramServiceError.network("HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw TelegramServiceError.network("页面编码无法识别")
        }
        AppLog.info("telegram fetched \(urlString) bytes=\(data.count)")
        return html
    }

    // MARK: - Parsing

    private static func parse(
        html: String,
        username: String,
        sortNewestFirst: Bool,
        channelTitleOverride: String? = nil
    ) -> TelegramBatch {
        let channelTitle = channelTitleOverride ?? channelTitle(from: html) ?? username
        var videos: [TelegramVideo] = []
        var seenMedia = Set<String>()

        for block in postBlocks(in: html) {
            guard let postID = postID(from: block) else { continue }
            let text = messageText(from: block)
            let thumbnail = thumbnailURL(from: block)
            let publishedAt = publishedDate(from: block)
            let mediaURLs = videoURLs(from: block)

            for (index, mediaURL) in mediaURLs.enumerated() {
                let key = mediaURL.absoluteString
                guard !seenMedia.contains(key) else { continue }
                seenMedia.insert(key)

                let title = text.isEmpty ? "\(channelTitle) #\(postID)" : text
                videos.append(
                    TelegramVideo(
                        username: username,
                        channelTitle: channelTitle,
                        postID: postID,
                        index: index,
                        title: title,
                        mediaURL: mediaURL,
                        thumbnailURL: thumbnail,
                        publishedAt: publishedAt
                    )
                )
            }
        }

        if videos.isEmpty {
            let fallbackMedia = videoURLs(from: html)
            let pageTitle = metaContent(in: html, property: "og:description")
                ?? metaContent(in: html, property: "og:title")
                ?? channelTitle
            for (index, mediaURL) in fallbackMedia.enumerated() {
                guard seenMedia.insert(mediaURL.absoluteString).inserted else { continue }
                videos.append(
                    TelegramVideo(
                        username: username,
                        channelTitle: channelTitle,
                        postID: 0,
                        index: index,
                        title: pageTitle,
                        mediaURL: mediaURL,
                        thumbnailURL: metaContent(in: html, property: "og:image").flatMap(URL.init(string:)),
                        publishedAt: nil
                    )
                )
            }
        }

        if sortNewestFirst {
            videos.sort {
                if $0.postID != $1.postID { return $0.postID > $1.postID }
                return $0.index < $1.index
            }
        }

        return TelegramBatch(title: channelTitle, videos: videos)
    }

    private static func postBlocks(in html: String) -> [String] {
        let parts = html.components(separatedBy: "tgme_widget_message_wrap")
        if parts.count > 1 {
            return Array(parts.dropFirst())
        }
        // Single-post and embed pages have no "wrap" wrapper; parse the whole
        // document as one block instead of missing every video.
        if html.contains("data-post=") {
            return [html]
        }
        return []
    }

    private static func postID(from block: String) -> Int? {
        guard let value = firstCapture(#"data-post\s*=\s*["']([^"']+)["']"#, in: block) else {
            return nil
        }
        let pieces = value.split(separator: "/")
        guard let last = pieces.last, let id = Int(last) else { return nil }
        return id
    }

    private static func messageText(from block: String) -> String {
        guard let raw = firstCapture(
            #"<div[^>]+class\s*=\s*["'][^"']*tgme_widget_message_text[^"']*["'][^>]*>(.*?)</div>"#,
            in: block,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ""
        }
        var text = raw
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeHTMLEntities(text)
        let lines = text.split(separator: "\n").map {
            $0.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        text = lines.filter { !$0.isEmpty }.joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 180 {
            text = String(text.prefix(180))
        }
        return text
    }

    private static func videoURLs(from block: String) -> [URL] {
        var values: [String] = []

        let patterns = [
            #"<(?:video|source)\b[^>]*(?:data-)?src\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+property\s*=\s*["']og:video(?::url|:secure_url)?["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+property\s*=\s*["']og:video(?::url|:secure_url)?["']"#,
            #"<meta[^>]+property\s*=\s*["']twitter:player:stream["'][^>]+content\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            for value in captures(pattern, in: block) {
                values.append(value)
            }
        }

        var urls: [URL] = []
        var seen = Set<String>()
        for raw in values {
            var value = decodeHTMLEntities(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("//") {
                value = "https:" + value
            }
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(),
                  !host.hasSuffix("t.me"),
                  !host.hasSuffix("telegram.me") else {
                continue
            }
            if url.pathExtension.lowercased() == "m3u8" { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func thumbnailURL(from block: String) -> URL? {
        let patterns = [
            #"background-image\s*:\s*url\(\s*['"]?([^'"\)]+)['"]?\s*\)"#,
            #"<img[^>]+src\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            for raw in captures(pattern, in: block) {
                var value = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("//") { value = "https:" + value }
                guard let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                return url
            }
        }
        return nil
    }

    private static func publishedDate(from block: String) -> Date? {
        guard let raw = firstCapture(#"<time[^>]+datetime\s*=\s*["']([^"']+)["']"#, in: block) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func channelTitle(from html: String) -> String? {
        if let title = firstCapture(
            #"tgme_channel_info_header_title[^>]*>\s*(?:<span[^>]*>)?([^<]+)"#,
            in: html
        ) {
            let cleaned = decodeHTMLEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return metaContent(in: html, property: "og:title")
    }

    private static func metaContent(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            #"<meta[^>]+property\s*=\s*["']\#(escaped)["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+property\s*=\s*["']\#(escaped)["']"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let decoded = decodeHTMLEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    // MARK: - Regex helpers

    private static func firstCapture(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
    ) -> String? {
        captures(pattern, in: text, options: options).first
    }

    private static func captures(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var text = input
        let named = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " ",
        ]
        for (entity, value) in named {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }

        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return text
        }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[valueRange])
            let scalarValue: UInt32?
            if raw.lowercased().hasPrefix("x") {
                scalarValue = UInt32(raw.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(raw, radix: 10)
            }
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { continue }
            text.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return text
    }
}
