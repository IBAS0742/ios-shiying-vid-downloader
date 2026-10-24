import Foundation
import UIKit

struct VideoMetadata: Sendable {
    var title: String?
    var channel: String?
    var thumbnailURL: URL?
}

enum MetadataService {
    struct OEmbedResponse: Decodable {
        let title: String?
        let authorName: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    static func fetch(videoID: String) async -> VideoMetadata {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "url", value: YouTubeLink.canonicalURL(videoID: videoID).absoluteString),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(OEmbedResponse.self, from: data) else {
            AppLog.error("oEmbed failed videoID=\(videoID)")
            return VideoMetadata(title: nil, channel: nil, thumbnailURL: YouTubeLink.thumbnailURL(videoID: videoID))
        }

        AppLog.info("oEmbed ok videoID=\(videoID)")

        return VideoMetadata(
            title: decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            channel: decoded.authorName?.trimmingCharacters(in: .whitespacesAndNewlines),
            thumbnailURL: decoded.thumbnailURL.flatMap(URL.init(string:)) ?? YouTubeLink.thumbnailURL(videoID: videoID)
        )
    }

    @discardableResult
    static func downloadThumbnail(for item: VideoItem, preferredURL: URL?) async -> Bool {
        AppPaths.createDirectory(for: item.id)
        var candidates = [preferredURL].compactMap { $0 }
        if item.source == .youtube,
           let youtubeFallback = YouTubeLink.thumbnailURL(videoID: item.videoID) {
            candidates.append(youtubeFallback)
        }

        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count > 1_000,
                  UIImage(data: data) != nil else {
                continue
            }
            do {
                try data.write(to: AppPaths.thumbnailURL(for: item.id), options: .atomic)
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
