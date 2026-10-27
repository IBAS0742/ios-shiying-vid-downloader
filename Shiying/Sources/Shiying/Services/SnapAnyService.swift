import Foundation

enum SnapAnyCredentials {
    private static let service = "com.ibas.shiying.snapany"
    private static let apiKeyAccount = "apiKey"

    static var apiKey: String? {
        let value = KeychainStore.string(for: apiKeyAccount, service: service)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static var isConfigured: Bool {
        apiKey != nil
    }

    static var maskedKey: String? {
        guard let key = apiKey else { return nil }
        guard key.count > 16 else { return key }
        return "\(key.prefix(12))…\(key.suffix(4))"
    }

    static func save(apiKey: String) {
        KeychainStore.set(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            for: apiKeyAccount,
            service: service
        )
    }

    static func clear() {
        KeychainStore.remove(apiKeyAccount, service: service)
    }
}

enum SnapAnyError: LocalizedError {
    case notConfigured
    case unauthorized
    case insufficientCredits
    case rateLimited
    case business(String)
    case http(Int)
    case invalidResponse
    case noProxyStream

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在设置里填写 SnapAny API Key"
        case .unauthorized:
            return "SnapAny API Key 无效，请重新填写"
        case .insufficientCredits:
            return "SnapAny 额度不足，请充值或稍后再试"
        case .rateLimited:
            return "SnapAny 请求过于频繁，请稍后再试"
        case .business(let message):
            return "SnapAny 解析失败：\(message)"
        case .http(let code):
            return "SnapAny 返回 HTTP \(code)"
        case .invalidResponse:
            return "SnapAny 返回的数据无法识别"
        case .noProxyStream:
            return "SnapAny 没有返回可用的代理视频流"
        }
    }
}

struct SnapAnyPrepared: Sendable {
    let media: PreparedMedia
    let title: String?
    let channel: String?
    let thumbnailURL: URL?
    let duration: Double?
}

/// Talks to SnapAny's YouTube proxy-download API. The proxy links need no key or
/// headers and support Range requests, so the existing DownloadManager can fetch
/// them even when the phone cannot reach YouTube directly.
enum SnapAnyService {
    private static let endpoint = URL(string: "https://api.snapany.com/openapi/v1/youtube/proxy-download")!
    private static let maxNativeResolution = 1080

    static func prepare(videoID: String, maxResolution: Int) async throws -> SnapAnyPrepared {
        guard let apiKey = SnapAnyCredentials.apiKey else {
            throw SnapAnyError.notConfigured
        }

        let payload = ExtractRequest(url: YouTubeLink.canonicalURL(videoID: videoID).absoluteString)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            AppLog.error("snapany request failed videoID=\(videoID): \(error.localizedDescription)")
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw SnapAnyError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = errorMessage(from: data)
            AppLog.error("snapany http \(http.statusCode) videoID=\(videoID) message=\(message)")
            switch http.statusCode {
            case 401:
                throw SnapAnyError.unauthorized
            case 402:
                throw SnapAnyError.insufficientCredits
            case 429:
                throw SnapAnyError.rateLimited
            case 400:
                throw SnapAnyError.business(message)
            default:
                throw SnapAnyError.http(http.statusCode)
            }
        }

        let decoded: ExtractResponse
        do {
            decoded = try JSONDecoder().decode(ExtractResponse.self, from: data)
        } catch {
            AppLog.error("snapany decode failed videoID=\(videoID): \(error.localizedDescription)")
            throw SnapAnyError.invalidResponse
        }

        let medias = decoded.medias ?? []
        let variants = candidates(from: medias)
        let selected = select(from: variants, maxResolution: maxResolution)

        if let selected {
            let media = makeMedia(from: selected, maxResolution: maxResolution)
            AppLog.info(
                "snapany resolved videoID=\(videoID) variants=\(variants.count) quality=\(media.qualityLabel) "
                    + "muxed=\(media.isMuxed) upgraded=\(media.upgradedFrom.map(String.init) ?? "no")"
            )
            return SnapAnyPrepared(
                media: media,
                title: clean(decoded.title),
                channel: clean(decoded.author?.name),
                thumbnailURL: thumbnailURL(from: selected.media, fallback: medias),
                duration: selected.media.duration
            )
        }

        if let resource = fallbackResource(in: medias) {
            let media = PreparedMedia(
                videoURL: resource.url,
                audioURL: nil,
                resolution: nil,
                isMuxed: true,
                qualityLabel: "原画",
                upgradedFrom: nil
            )
            AppLog.info("snapany resolved videoID=\(videoID) via resource proxy (no tiered variants)")
            return SnapAnyPrepared(
                media: media,
                title: clean(decoded.title),
                channel: clean(decoded.author?.name),
                thumbnailURL: previewURL(from: medias),
                duration: medias.first?.duration
            )
        }

        AppLog.error("snapany returned no usable proxy stream videoID=\(videoID) medias=\(medias.count)")
        throw SnapAnyError.noProxyStream
    }

    // MARK: - Selection

    private struct Candidate {
        let height: Int
        let fps: Double
        let qualityLabel: String?
        let videoURL: URL
        let audioURL: URL?
        let media: Media

        var isMuxed: Bool { audioURL == nil }
    }

    private static func candidates(from medias: [Media]) -> [Candidate] {
        var result: [Candidate] = []

        for media in medias {
            if let type = media.mediaType, !type.lowercased().contains("video") {
                continue
            }
            for variant in media.variants ?? [] {
                guard let proxy = variant.videoProxyURL, !proxy.isEmpty,
                      let videoURL = URL(string: proxy) else { continue }
                guard let height = variant.quality, height > 0, height != 9999, height <= maxNativeResolution else {
                    continue
                }
                if let ext = variant.videoExt, ext.lowercased() != "mp4" {
                    continue
                }

                var audioURL: URL?
                if let proxy = variant.audioProxyURL, !proxy.isEmpty {
                    guard let ext = variant.audioExt, ext.lowercased() == "m4a",
                          let parsed = URL(string: proxy) else { continue }
                    audioURL = parsed
                }

                result.append(
                    Candidate(
                        height: height,
                        fps: variant.fps ?? 0,
                        qualityLabel: variant.qualityLabel,
                        videoURL: videoURL,
                        audioURL: audioURL,
                        media: media
                    )
                )
            }
        }

        return result
    }

    private static func select(from candidates: [Candidate], maxResolution: Int) -> Candidate? {
        let capped = candidates.filter { $0.height <= maxResolution }
        if let best = capped.max(by: isWorse) {
            return best
        }

        // Nothing at or below the requested cap: use the lowest higher tier,
        // mirroring the automatic upgrade used by the native resolver.
        let above = candidates.filter { $0.height > maxResolution && $0.height <= maxNativeResolution }
        return above.min(by: isWorse)
    }

    private static func isWorse(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.height != rhs.height {
            return lhs.height < rhs.height
        }
        if lhs.fps != rhs.fps {
            return lhs.fps < rhs.fps
        }
        // Prefer a single muxed file when both tiers are equivalent.
        return !lhs.isMuxed && rhs.isMuxed
    }

    private static func makeMedia(from candidate: Candidate, maxResolution: Int) -> PreparedMedia {
        let label = clean(candidate.qualityLabel) ?? "\(candidate.height)p"
        return PreparedMedia(
            videoURL: candidate.videoURL,
            audioURL: candidate.audioURL,
            resolution: candidate.height,
            isMuxed: candidate.audioURL == nil,
            qualityLabel: label,
            upgradedFrom: candidate.height > maxResolution ? maxResolution : nil
        )
    }

    private static func fallbackResource(in medias: [Media]) -> (url: URL, media: Media)? {
        for media in medias {
            if let type = media.mediaType, !type.lowercased().contains("video") {
                continue
            }
            if let proxy = media.resourceProxyURL, !proxy.isEmpty, let url = URL(string: proxy) {
                return (url, media)
            }
        }
        return nil
    }

    private static func thumbnailURL(from media: Media, fallback medias: [Media]) -> URL? {
        for candidate in [media] + medias {
            if let value = candidate.previewURL, let url = URL(string: value) {
                return url
            }
        }
        return nil
    }

    private static func previewURL(from medias: [Media]) -> URL? {
        medias.first { media in
            guard let value = media.previewURL, !value.isEmpty else { return false }
            return true
        }.flatMap { $0.previewURL }.flatMap(URL.init(string:))
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func errorMessage(from data: Data) -> String {
        if let apiError = try? JSONDecoder().decode(APIError.self, from: data) {
            if let message = apiError.message ?? apiError.error ?? apiError.msg ?? apiError.detail,
               !message.isEmpty {
                return message
            }
        }
        let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
        return body.isEmpty ? "未知错误" : body
    }

    // MARK: - Wire format

    private struct ExtractRequest: Encodable {
        let url: String
    }

    private struct APIError: Decodable {
        let message: String?
        let error: String?
        let msg: String?
        let detail: String?
    }

    private struct ExtractResponse: Decodable {
        let title: String?
        let author: Author?
        let medias: [Media]?
    }

    private struct Author: Decodable {
        let name: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case nickname
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let value = try? single.decode(String.self) {
                name = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decodeIfPresent(String.self, forKey: .name))
                ?? (try? container.decodeIfPresent(String.self, forKey: .nickname)) ?? nil
        }
    }

    private struct Media: Decodable {
        let mediaType: String?
        let resourceURL: String?
        let resourceProxyURL: String?
        let previewURL: String?
        let duration: Double?
        let variants: [Variant]?

        private enum CodingKeys: String, CodingKey {
            case mediaType = "media_type"
            case resourceURL = "resource_url"
            case resourceProxyURL = "resource_proxy_url"
            case previewURL = "preview_url"
            case duration
            case variants
        }
    }

    private struct Variant: Decodable {
        let quality: Int?
        let qualityLabel: String?
        let fps: Double?
        let videoURL: String?
        let videoProxyURL: String?
        let videoExt: String?
        let videoCodec: String?
        let videoFilesize: Int64?
        let audioURL: String?
        let audioProxyURL: String?
        let audioExt: String?
        let audioCodec: String?
        let audioFilesize: Int64?

        private enum CodingKeys: String, CodingKey {
            case quality
            case qualityLabel = "quality_label"
            case fps
            case videoURL = "video_url"
            case videoProxyURL = "video_proxy_url"
            case videoExt = "video_ext"
            case videoCodec = "video_codec"
            case videoFilesize = "video_filesize"
            case audioURL = "audio_url"
            case audioProxyURL = "audio_proxy_url"
            case audioExt = "audio_ext"
            case audioCodec = "audio_codec"
            case audioFilesize = "audio_filesize"
        }
    }
}
