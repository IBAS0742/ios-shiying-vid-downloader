import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let card = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let actionStack = UIStackView()

    private var sharedURL: URL?
    private var sharedTitle: String?
    private var didStart = false
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildUI()
        preferredContentSize = CGSize(width: 0, height: 250)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        NSLog("[ShiyingShare] viewDidAppear, starting share flow")
        startShareFlow()
    }

    private func buildUI() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.078, green: 0.09, blue: 0.133, alpha: 1)
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        view.addSubview(card)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "play.square.stack.fill")
        iconView.tintColor = UIColor(red: 1, green: 0.71, blue: 0.35, alpha: 1)
        iconView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "拾影"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在读取分享内容…"
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.numberOfLines = 2

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.text = "视频会自动加入片库并开始下载"
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.numberOfLines = 2

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = UIColor(red: 1, green: 0.71, blue: 0.35, alpha: 1)
        spinner.hidesWhenStopped = true
        spinner.startAnimating()

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .horizontal
        actionStack.spacing = 8
        actionStack.distribution = .fillEqually
        actionStack.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 5

        card.addSubview(iconView)
        card.addSubview(textStack)
        card.addSubview(spinner)
        card.addSubview(actionStack)

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = UIColor.white.withAlphaComponent(0.5)
        closeButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        card.addSubview(closeButton)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 13),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            textStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -48),

            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            spinner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            actionStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            actionStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            actionStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            actionStack.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func startShareFlow() {
        Task { @MainActor in
            let content = await loadSharedContent()
            NSLog("[ShiyingShare] loaded url=%@ title=%@", content.url?.absoluteString ?? "nil", content.title ?? "nil")
            if let url = content.url, ShareLink.isSupported(url) {
                sharedURL = ShareLink.normalized(url)
                sharedTitle = content.title
                openMainApp()
            } else {
                showNoLink()
            }
        }
    }

    private func loadSharedContent() async -> (url: URL?, title: String?) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return (nil, nil)
        }

        var candidates: [URL] = []
        var textCandidates: [String] = []
        var title: String?

        for item in items {
            if title == nil, let text = item.attributedContentText?.string, !text.isEmpty {
                title = text
            }
            if let text = item.attributedTitle?.string, title == nil, !text.isEmpty {
                title = text
            }

            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let value = await loadItem(provider, type: UTType.url.identifier) {
                        if let url = value as? URL {
                            candidates.append(url)
                        } else if let nsURL = value as? NSURL {
                            candidates.append(nsURL as URL)
                        } else if let string = value as? String, let url = URL(string: string) {
                            candidates.append(url)
                        } else if let data = value as? Data, let string = String(data: data, encoding: .utf8),
                                  let url = YouTubeLinkID.extractURL(from: string) {
                            candidates.append(url)
                        }
                    }
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let value = await loadItem(provider, type: UTType.plainText.identifier) {
                        if let string = value as? String {
                            textCandidates.append(string)
                        } else if let data = value as? Data, let string = String(data: data, encoding: .utf8) {
                            textCandidates.append(string)
                        }
                    }
                }
            }
        }

        for text in textCandidates {
            if let url = YouTubeLinkID.extractURL(from: text) {
                candidates.append(url)
            }
        }
        if let currentTitle = title, ShareLink.containsSupportedLink(inText: currentTitle) {
            title = nil
        }

        if let direct = candidates.first(where: { ShareLink.isSupported($0) }) {
            return (direct, title)
        }
        for text in textCandidates {
            if let url = YouTubeLinkID.extractURL(from: text), ShareLink.isSupported(url) {
                return (url, title)
            }
        }
        return (nil, title)
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private func openMainApp() {
        guard let sharedURL else { return }
        statusLabel.text = "正在打开拾影…"
        detailLabel.text = "已识别视频链接，正在交给 App 下载"
        spinner.startAnimating()

        var components = URLComponents()
        components.scheme = "shiyin"
        components.host = "add"
        var queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]
        if let sharedTitle, !sharedTitle.isEmpty {
            queryItems.append(URLQueryItem(name: "title", value: sharedTitle))
        }
        components.queryItems = queryItems
        guard let deepLink = components.url else {
            showFailure()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.attemptOpen(deepLink)
        }
    }

    private func attemptOpen(_ url: URL) {
        if let context = extensionContext {
            context.open(url) { [weak self] success in
                DispatchQueue.main.async {
                    NSLog("[ShiyingShare] extensionContext.open success=%d", success ? 1 : 0)
                    guard let self, !self.finished else { return }
                    if success {
                        self.showOpened()
                    } else {
                        self.openViaResponder(url)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.finished else { return }
                self.openViaResponder(url)
            }
        } else {
            openViaResponder(url)
        }
    }

    private func openViaResponder(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                showOpened()
                return
            }
            responder = current.next
        }
        showFailure()
    }

    private func showOpened() {
        guard !finished else { return }
        finished = true
        spinner.stopAnimating()
        statusLabel.text = "已发送到拾影"
        detailLabel.text = "App 正在解析标题并自动下载视频"
        iconView.image = UIImage(systemName: "checkmark.circle.fill")
        iconView.tintColor = UIColor(red: 0.41, green: 0.85, blue: 0.69, alpha: 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func showNoLink() {
        finished = false
        spinner.stopAnimating()
        iconView.image = UIImage(systemName: "link.badge.plus")
        statusLabel.text = "没有找到支持的链接"
        detailLabel.text = "支持 YouTube 视频/播放列表和 Telegram 公开链接"
        showCloseAction()
    }

    private func showFailure() {
        finished = false
        spinner.stopAnimating()
        iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
        iconView.tintColor = UIColor(red: 1, green: 0.41, blue: 0.41, alpha: 1)
        statusLabel.text = "没能自动打开拾影"
        detailLabel.text = "链接已复制。请手动打开拾影，点 + 后粘贴链接。"
        if let sharedURL {
            UIPasteboard.general.string = sharedURL.absoluteString
        }
        showFailureActions()
    }

    private func showCloseAction() {
        actionStack.isHidden = false
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionStack.addArrangedSubview(makeButton(title: "关闭", filled: true, action: #selector(cancelTapped)))
    }

    private func showFailureActions() {
        actionStack.isHidden = false
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionStack.addArrangedSubview(makeButton(title: "再试一次", filled: false, action: #selector(retryTapped)))
        actionStack.addArrangedSubview(makeButton(title: "复制并关闭", filled: true, action: #selector(copyAndCloseTapped)))
    }

    private func makeButton(title: String, filled: Bool, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseForegroundColor = filled
            ? UIColor(red: 0.05, green: 0.055, blue: 0.075, alpha: 1)
            : .white
        configuration.baseBackgroundColor = filled
            ? UIColor(red: 1, green: 0.71, blue: 0.35, alpha: 1)
            : UIColor.white.withAlphaComponent(0.08)
        configuration.cornerStyle = .capsule
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .systemFont(ofSize: 12, weight: .semibold)
            return updated
        }
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func retryTapped() {
        guard sharedURL != nil else { return }
        actionStack.isHidden = true
        iconView.image = UIImage(systemName: "play.square.stack.fill")
        iconView.tintColor = UIColor(red: 1, green: 0.71, blue: 0.35, alpha: 1)
        openMainApp()
    }

    @objc private func copyAndCloseTapped() {
        cancelTapped()
    }

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private enum ShareLink {
    static func isSupported(_ url: URL) -> Bool {
        YouTubeLinkID.videoID(from: url) != nil
            || isYouTubePlaylist(url)
            || isTelegram(url)
    }

    static func normalized(_ url: URL) -> URL {
        if isYouTubePlaylist(url), !hasVideoID(url) {
            return url
        }
        if let videoID = YouTubeLinkID.videoID(from: url) {
            return URL(string: "https://www.youtube.com/watch?v=\(videoID)") ?? url
        }
        return url
    }

    static func containsSupportedLink(inText text: String) -> Bool {
        guard let url = YouTubeLinkID.extractURL(from: text) else { return false }
        return isSupported(url)
    }

    private static func isYouTubePlaylist(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host.contains("youtube.com") || host.contains("youtube-nocookie.com") else {
            return false
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "list" && !($0.value ?? "").isEmpty }) == true
    }

    private static func hasVideoID(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true
    }

    private static func isTelegram(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let knownHosts = [
            "t.me", "www.t.me",
            "telegram.me", "www.telegram.me",
            "telegram.dog", "www.telegram.dog",
            "telegram.space", "www.telegram.space",
        ]
        guard knownHosts.contains(host) else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first?.lowercased(), !first.isEmpty else { return false }
        let reserved: Set<String> = [
            "c", "joinchat", "addstickers", "share", "iv", "proxy", "socks",
            "login", "confirmphone", "setlanguage", "addemoji",
        ]
        guard !reserved.contains(first) else { return false }
        return true
    }
}

private enum YouTubeLinkID {
    static func videoID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }

        if host.contains("youtu.be"), let first = parts.first {
            return valid(first)
        }
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value {
                return valid(value)
            }
            if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0].lowercased()) {
                return valid(parts[1])
            }
        }
        return videoID(inText: url.absoluteString)
    }

    static func videoID(inText text: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|shorts/|live/|embed/)|youtu\.be/)([0-9A-Za-z_-]{11})"#,
            #"(?:[?&]v=)([0-9A-Za-z_-]{11})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let idRange = Range(match.range(at: 1), in: text) {
                return String(text[idRange])
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

    private static func valid(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/?&"))
        guard cleaned.count == 11 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return cleaned
    }
}
