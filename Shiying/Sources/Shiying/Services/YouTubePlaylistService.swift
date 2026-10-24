import Foundation

struct YouTubePlaylistEntry: Sendable {
    let videoID: String
    let title: String
    let channel: String
    let duration: Double
    let thumbnailURL: URL?
}

struct YouTubePlaylistBatch: Sendable {
    let title: String
    let entries: [YouTubePlaylistEntry]
    let truncated: Bool
}

enum YouTubePlaylistServiceError: LocalizedError {
    case unsupported
    case unavailable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "暂不支持这种 YouTube 列表（例如自动混剪/电台列表）"
        case .unavailable(let detail):
            return "YouTube 播放列表读取失败：\(detail)"
        case .empty:
            return "这个播放列表里没有可用视频"
        }
    }
}

enum YouTubePlaylistService {
    private static let maxEntries = 300
    private static let maxPages = 8
    private static let webClientVersion = "2.20260708.00.00"
    private static let webAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    static func fetch(playlistID: String) async throws -> YouTubePlaylistBatch {
        let prefixes = ["PL", "UU", "OL", "FL", "LL", "VL", "TL"]
        guard prefixes.contains(where: { playlistID.hasPrefix($0) }) else {
            throw YouTubePlaylistServiceError.unsupported
        }

        let (root, html) = try await loadPlaylistRoot(playlistID: playlistID)

        var entries: [YouTubePlaylistEntry] = []
        var seen = Set<String>()
        collectEntries(from: root, into: &entries, seen: &seen)

        let title = playlistTitle(from: root) ?? "YouTube 播放列表"
        let channel = playlistChannel(from: root) ?? ""
        if !channel.isEmpty {
            entries = entries.map {
                YouTubePlaylistEntry(
                    videoID: $0.videoID,
                    title: $0.title,
                    channel: $0.channel.isEmpty ? channel : $0.channel,
                    duration: $0.duration,
                    thumbnailURL: $0.thumbnailURL
                )
            }
        }

        let apiKey = html.flatMap { configValue("INNERTUBE_API_KEY", in: $0) } ?? webAPIKey
        let clientVersion = html.flatMap { configValue("INNERTUBE_CLIENT_VERSION", in: $0) } ?? webClientVersion
        var token = continuationToken(in: root)
        var usedTokens = Set<String>()
        var pages = 0

        while let currentToken = token,
              entries.count < maxEntries,
              pages < maxPages,
              usedTokens.insert(currentToken).inserted {
            pages += 1
            do {
                let nextRoot = try await fetchContinuation(
                    token: currentToken,
                    apiKey: apiKey,
                    clientVersion: clientVersion
                )
                collectEntries(from: nextRoot, into: &entries, seen: &seen)
                token = continuationToken(in: nextRoot)
            } catch {
                AppLog.error("playlist continuation failed page=\(pages): \(error.localizedDescription)")
                break
            }
        }

        guard !entries.isEmpty else {
            if let html {
                let markers = ["playlistVideoRenderer", "playlistPanelVideoRenderer", "lockupViewModel", "videoId", "ytInitialData"]
                    .map { "\($0)=\(html.components(separatedBy: $0).count - 1)" }
                    .joined(separator: " ")
                AppLog.error("playlist parse empty markers: \(markers)")
            } else {
                AppLog.error("playlist parse empty from browse response")
            }
            throw YouTubePlaylistServiceError.empty
        }

        AppLog.info("playlist loaded id=\(playlistID) title=\(title) count=\(entries.count) pages=\(pages + 1)")
        return YouTubePlaylistBatch(
            title: title,
            entries: entries,
            truncated: entries.count >= maxEntries
        )
    }

    // MARK: - Networking

    private static func loadPlaylistRoot(playlistID: String) async throws -> (Any, String?) {
        if let root = try? await fetchBrowse(playlistID: playlistID) {
            AppLog.info("playlist browse fetched id=\(playlistID)")
            return (root, nil)
        }
        let html = try await fetchHTML(playlistID: playlistID)
        guard let data = jsonObject(in: html, marker: "ytInitialData"),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw YouTubePlaylistServiceError.unavailable("页面结构无法识别")
        }
        return (root, html)
    }

    private static func fetchBrowse(playlistID: String) async throws -> Any {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/browse")!
        components.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "key", value: webAPIKey),
        ]
        guard let url = components.url else {
            throw YouTubePlaylistServiceError.unavailable("列表地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(webClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": webClientVersion,
                    "hl": "en",
                    "gl": "US",
                ],
            ],
            "browseId": "VL" + playlistID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YouTubePlaylistServiceError.unavailable("列表 HTTP \(status)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func fetchHTML(playlistID: String) async throws -> String {
        var components = URLComponents(string: "https://www.youtube.com/playlist")!
        components.queryItems = [
            URLQueryItem(name: "list", value: playlistID),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US"),
        ]
        guard let url = components.url else {
            throw YouTubePlaylistServiceError.unavailable("链接格式错误")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
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
                AppLog.error("playlist page attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        guard let (data, response) = fetched else {
            throw YouTubePlaylistServiceError.unavailable(lastError?.localizedDescription ?? "网络请求失败")
        }
        guard let http = response as? HTTPURLResponse else {
            throw YouTubePlaylistServiceError.unavailable("没有收到服务器响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw YouTubePlaylistServiceError.unavailable("HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw YouTubePlaylistServiceError.unavailable("页面编码无法识别")
        }
        AppLog.info("playlist page fetched bytes=\(data.count) status=\(http.statusCode)")
        return html
    }

    private static func fetchContinuation(
        token: String,
        apiKey: String,
        clientVersion: String
    ) async throws -> Any {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/browse")!
        components.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components.url else {
            throw YouTubePlaylistServiceError.unavailable("续页地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "hl": "en",
                    "gl": "US",
                ],
            ],
            "continuation": token,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YouTubePlaylistServiceError.unavailable("续页 HTTP \(status)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Parsing

    private static func collectEntries(
        from object: Any,
        into entries: inout [YouTubePlaylistEntry],
        seen: inout Set<String>
    ) {
        if let dictionary = object as? [String: Any] {
            for key in ["playlistVideoRenderer", "playlistPanelVideoRenderer"] {
                if let renderer = dictionary[key] as? [String: Any],
                   let entry = entry(from: renderer),
                   seen.insert(entry.videoID).inserted {
                    entries.append(entry)
                }
            }
            if let lockup = dictionary["lockupViewModel"] as? [String: Any],
               let entry = lockupEntry(from: lockup),
               seen.insert(entry.videoID).inserted {
                entries.append(entry)
            }
            for value in dictionary.values {
                collectEntries(from: value, into: &entries, seen: &seen)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectEntries(from: value, into: &entries, seen: &seen)
            }
        }
    }

    private static func entry(from renderer: [String: Any]) -> YouTubePlaylistEntry? {
        guard let videoID = renderer["videoId"] as? String,
              videoID.count == 11 else {
            return nil
        }
        let title = textValue(renderer["title"]) ?? "YouTube 视频"
        let duration = (renderer["lengthSeconds"] as? String).flatMap(Double.init) ?? 0
        let channel = bylineText(renderer["shortBylineText"])
            ?? bylineText(renderer["longBylineText"])
            ?? ""
        let thumbnail = thumbnailURL(from: renderer["thumbnail"])
        return YouTubePlaylistEntry(
            videoID: videoID,
            title: title,
            channel: channel,
            duration: duration,
            thumbnailURL: thumbnail
        )
    }

    private static func lockupEntry(from lockup: [String: Any]) -> YouTubePlaylistEntry? {
        var videoID = lockup["contentId"] as? String
        if videoID?.count != 11 {
            videoID = nil
        }
        if videoID == nil,
           let context = lockup["rendererContext"] as? [String: Any],
           let endpoint = firstDictionary(withKey: "watchEndpoint", in: context),
           let candidate = endpoint["videoId"] as? String,
           candidate.count == 11 {
            videoID = candidate
        }
        guard let videoID else { return nil }

        let metadata = firstDictionary(withKey: "lockupMetadataViewModel", in: lockup)
        let title = textValue(metadata?["title"]) ?? "YouTube 视频"

        var channel = ""
        var duration: Double = 0
        if let rows = firstDictionary(withKey: "contentMetadataViewModel", in: metadata)?["metadataRows"] as? [[String: Any]] {
            for row in rows {
                guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
                for part in parts {
                    guard let text = textValue(part["text"]), !text.isEmpty else { continue }
                    if duration == 0, let seconds = parsedDuration(text) {
                        duration = seconds
                    } else if channel.isEmpty, !text.contains("view"), !text.contains("ago") {
                        channel = text
                    }
                }
            }
        }

        let thumbnail = thumbnailURL(from: firstDictionary(withKey: "thumbnailViewModel", in: lockup)?["image"])
        return YouTubePlaylistEntry(
            videoID: videoID,
            title: title,
            channel: channel,
            duration: duration,
            thumbnailURL: thumbnail
        )
    }

    private static func parsedDuration(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: ":")
        guard (2...3).contains(pieces.count),
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return pieces.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private static func playlistTitle(from root: Any) -> String? {
        if let meta = firstDictionary(withKey: "playlistMetadataRenderer", in: root),
           let title = meta["title"] as? String,
           !title.isEmpty {
            return title
        }
        if let header = firstDictionary(withKey: "playlistHeaderRenderer", in: root),
           let title = textValue(header["title"]),
           !title.isEmpty {
            return title
        }
        if let page = firstDictionary(withKey: "pageHeaderViewModel", in: root),
           let titleDictionary = page["title"] as? [String: Any],
           let dynamic = firstDictionary(withKey: "dynamicTextViewModel", in: titleDictionary),
           let text = dynamic["text"] as? [String: Any],
           let content = text["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let micro = firstDictionary(withKey: "microformatDataRenderer", in: root),
           let title = micro["title"] as? String,
           !title.isEmpty {
            return title
        }
        return nil
    }

    private static func playlistChannel(from root: Any) -> String? {
        if let header = firstDictionary(withKey: "playlistHeaderRenderer", in: root) {
            if let owner = bylineText(header["ownerText"]), !owner.isEmpty {
                return owner
            }
            if let byline = firstDictionary(withKey: "videoOwnerRenderer", in: header),
               let title = bylineText(byline["title"]),
               !title.isEmpty {
                return title
            }
        }
        if let sidebar = firstDictionary(withKey: "playlistSidebarPrimaryInfoRenderer", in: root),
           let owner = bylineText(sidebar["ownerText"]),
           !owner.isEmpty {
            return owner
        }
        return nil
    }

    private static func continuationToken(in root: Any) -> String? {
        guard let item = firstDictionary(withKey: "continuationItemRenderer", in: root),
              let endpoint = item["continuationEndpoint"] as? [String: Any],
              let command = endpoint["continuationCommand"] as? [String: Any],
              let token = command["token"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func bylineText(_ value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        if let simple = dictionary["simpleText"] as? String, !simple.isEmpty {
            return simple
        }
        if let runs = dictionary["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func textValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let simple = dictionary["simpleText"] as? String, !simple.isEmpty {
            return simple
        }
        if let content = dictionary["content"] as? String, !content.isEmpty {
            return content
        }
        if let runs = dictionary["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        if let nested = dictionary["title"] {
            return textValue(nested)
        }
        return nil
    }

    private static func thumbnailURL(from value: Any?) -> URL? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let thumbnails = (dictionary["thumbnails"] as? [[String: Any]])
            ?? (dictionary["sources"] as? [[String: Any]])
        guard let thumbnails else { return nil }
        for thumbnail in thumbnails.reversed() {
            guard let raw = thumbnail["url"] as? String else { continue }
            var value = raw
            if value.hasPrefix("//") { value = "https:" + value }
            if let url = URL(string: value) { return url }
        }
        return nil
    }

    private static func firstDictionary(withKey key: String, in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if let direct = dictionary[key] as? [String: Any] {
                return direct
            }
            for value in dictionary.values {
                if let found = firstDictionary(withKey: key, in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstDictionary(withKey: key, in: value) {
                    return found
                }
            }
        }
        return nil
    }

    private static func configValue(_ key: String, in html: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[valueRange])
    }

    private static func jsonObject(in html: String, marker: String) -> Data? {
        guard let markerRange = html.range(of: marker),
              let start = html[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < html.endIndex {
            let character = html[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let slice = html[start...index]
                        return Data(slice.utf8)
                    }
                }
            }
            index = html.index(after: index)
        }
        return nil
    }
}
