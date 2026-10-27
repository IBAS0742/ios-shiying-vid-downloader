import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var telegram = TelegramSession.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showTelegramLogin = false
    @State private var hasCredentials = TelegramCredentials.isConfigured
    @State private var apiIDText = ""
    @State private var apiHashText = ""
    @State private var credentialError: String?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    qualitySection
                    playbackSpeedSection
                    youtubeSpeedSection
                    concurrencySection
                    sourceSection
                    playbackCleanupSection
                    telegramSection
                    diagnosticSection
                    clipboardSection
                    footer
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTelegramLogin) {
            TelegramLoginView(session: telegram)
        }
        .onAppear {
            hasCredentials = TelegramCredentials.isConfigured
            telegram.bootstrap()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Keychain reads can fail while the device is locked, so refresh
            // the cached credential state once the app is usable again.
            guard newPhase == .active else { return }
            hasCredentials = TelegramCredentials.isConfigured
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("设置")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("下载、播放与剪贴板偏好")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "下载画质")
            Text("只影响之后加入的下载，已经下载好的视频不会重新下载。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)

            VStack(spacing: 8) {
                ForEach(DownloadQuality.allCases) { quality in
                    qualityRow(quality)
                }
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.amber)
                    .padding(.top, 1)
                Text("为保证 iPhone 原生播放和画中画，最高下载 1080p。视频标题里的“4K”只是原标题，不代表实际下载分辨率。若所选画质不可用，会自动改用该视频更高的可用画质。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(3)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.amber.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.amber.opacity(0.14), lineWidth: 1)
                    )
            )
        }
    }

    private func qualityRow(_ quality: DownloadQuality) -> some View {
        let selected = store.downloadQuality == quality
        return Button {
            store.downloadQuality = quality
        } label: {
            HStack(spacing: 12) {
                Image(systemName: quality.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Palette.background : Palette.amber)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Palette.amber : Palette.amber.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(quality.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                    Text(quality.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiary)
                }

                Spacer(minLength: 8)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? Palette.amber : Palette.tertiary.opacity(0.5))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(selected ? Palette.amber.opacity(0.09) : Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(selected ? Palette.amber.opacity(0.35) : Palette.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var playbackSpeedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "播放速度")
            Text("所有视频默认使用这个倍速播放。在 App 内播放时，长按画面可再临时加速 0.5 倍，松开恢复。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                spacing: 8
            ) {
                ForEach(AppStore.playbackRateOptions, id: \.self) { rate in
                    playbackRateChip(rate)
                }
            }
        }
    }

    private func playbackRateChip(_ rate: Double) -> some View {
        let selected = abs(store.playbackRate - rate) < 0.001
        return Button {
            store.playbackRate = rate
        } label: {
            Text(playbackRateText(rate))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? Palette.background : Palette.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(selected ? Palette.amber : Palette.card.opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(selected ? Color.clear : Palette.line, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func playbackRateText(_ rate: Double) -> String {
        String(format: "%g×", rate)
    }

    private var youtubeSpeedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "YouTube 下载加速")
            Text("分片并发会为同一个视频同时建立多个连接，通常比单连接更快。流量消耗不变；服务器不支持分片时自动回退为单连接。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)

            HStack(spacing: 8) {
                speedChip(value: 1, title: "标准", detail: "单连接")
                speedChip(value: 4, title: "加速", detail: "4 连接")
                speedChip(value: 8, title: "极速", detail: "8 连接")
            }
        }
    }

    private func speedChip(value: Int, title: String, detail: String) -> some View {
        let selected = store.youtubeSegments == value
        return Button {
            store.youtubeSegments = value
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .opacity(0.8)
            }
            .foregroundStyle(selected ? Palette.background : Palette.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(selected ? Palette.amber : Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Palette.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var concurrencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "同时下载")
            Text("超出数量的任务会自动排队，前面的下载完成后依次开始。也可以在「D」下载页里随时调整。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)

            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { count in
                    concurrencyChip(count)
                }
            }
        }
    }

    private func concurrencyChip(_ count: Int) -> some View {
        let selected = store.maxConcurrentDownloads == count
        return Button {
            store.maxConcurrentDownloads = count
        } label: {
            VStack(spacing: 5) {
                Text("\(count)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("个")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selected ? Palette.background : Palette.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(selected ? Palette.amber : Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Palette.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "来源与播放列表")
            VStack(spacing: 0) {
                sourceRow(
                    source: .youtube,
                    title: "YouTube",
                    detail: "支持单个视频和播放列表。播放列表会整批加入 YouTube 分组。"
                )

                Divider()
                    .overlay(Palette.line)
                    .padding(.horizontal, 14)

                sourceRow(
                    source: .telegram,
                    title: "Telegram",
                    detail: "支持公开频道和公开帖子（t.me/...）。私密频道、群组和需要登录的内容暂不支持。"
                )

                Divider()
                    .overlay(Palette.line)
                    .padding(.horizontal, 14)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.amber)
                        .padding(.top, 1)
                    Text("不同来源会分组到不同播放列表。YouTube 播放完只会在 YouTube 分组内继续，Telegram 同理。")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
            )
        }
    }

    private func sourceRow(source: MediaSource, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: source.accentHex))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: source.accentHex).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var playbackCleanupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "播放后自动清理")
            Text("默认开启。开启后，视频播放时会移入废纸篓，并在 7 天后自动删除；关闭后，之后播放的视频会一直保留在片库中。两个列表互不影响。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)

            VStack(spacing: 0) {
                cleanupToggle(
                    source: .youtube,
                    title: "YouTube 列表（Y）",
                    isOn: $store.autoDeleteYouTubeAfterPlayback
                )

                Divider()
                    .overlay(Palette.line)
                    .padding(.horizontal, 14)

                cleanupToggle(
                    source: .telegram,
                    title: "Telegram 列表（T）",
                    isOn: $store.autoDeleteTelegramAfterPlayback
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
            )
        }
    }

    private func cleanupToggle(
        source: MediaSource,
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: source.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: source.accentHex))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: source.accentHex).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                    Text(isOn.wrappedValue ? "播放后自动移入废纸篓" : "播放后保留在片库中")
                        .font(.system(size: 10))
                        .foregroundStyle(isOn.wrappedValue ? Palette.tertiary : Palette.mint)
                }
            }
        }
        .tint(Color(hex: source.accentHex))
        .padding(14)
    }

    private var telegramSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Telegram 登录")
            Text("公开网页只能看到 20MB 以内的视频。扫码登录后，拾影可以直接下载 Telegram 里的大视频。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(hex: MediaSource.telegram.accentHex).opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(telegramStatusTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.text)
                        Text(telegramStatusDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.tertiary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    Circle()
                        .fill(telegramStatusColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
                .padding(14)

                Divider()
                    .overlay(Palette.line)
                    .padding(.horizontal, 14)

                if !hasCredentials {
                    credentialsForm
                } else {
                    HStack(spacing: 10) {
                        if telegram.phase.isReady {
                            Button {
                                telegram.logOut()
                            } label: {
                                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.danger)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(Palette.danger.opacity(0.12)))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        } else {
                            Button {
                                showTelegramLogin = true
                            } label: {
                                Label(
                                    telegram.phase == .waitingForQR ? "查看二维码" : "扫码登录",
                                    systemImage: "qrcode"
                                )
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.background)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Palette.amber))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }

                        Text(hasCredentials ? "API 凭证已保存在钥匙串" : "")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.tertiary)

                        Spacer(minLength: 0)
                    }
                    .padding(14)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
            )
        }
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API ID")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            TextField("例如 12345678", text: $apiIDText)
                .keyboardType(.numberPad)
                .font(.system(size: 14))
                .foregroundStyle(Palette.text)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.cardLift)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        )
                )

            Text("API Hash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            SecureField("32 位 API Hash", text: $apiHashText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))
                .foregroundStyle(Palette.text)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.cardLift)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        )
                )

            if let credentialError {
                Text(credentialError)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.danger)
            }

            Button {
                saveCredentials()
            } label: {
                Text("保存并扫码登录")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())

            Text("免费获取：用 Telegram 手机号登录 my.telegram.org → API development tools → 创建应用，复制 api_id 和 api_hash。")
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)
        }
        .padding(14)
    }

    private var telegramStatusTitle: String {
        guard hasCredentials else { return "未配置 API 凭证" }
        switch telegram.phase {
        case .ready:
            return "已登录"
        case .starting:
            return "正在连接…"
        case .waitingForQR:
            return "等待扫码确认"
        case .passwordRequired:
            return "需要两步验证密码"
        case .failed:
            return "登录遇到问题"
        default:
            return "未登录"
        }
    }

    private var telegramStatusDetail: String {
        guard hasCredentials else {
            return "填写 API ID / API Hash 后即可扫码登录"
        }
        switch telegram.phase {
        case .ready:
            return telegram.profileLabel
        case .starting:
            return "正在恢复 Telegram 会话…"
        case .waitingForQR:
            return "打开登录面板，用 Telegram 扫描二维码"
        case .passwordRequired:
            return "打开登录面板，输入两步验证密码"
        case .failed(let message):
            return message
        default:
            return "扫码登录后即可下载大视频"
        }
    }

    private var telegramStatusColor: Color {
        guard hasCredentials else { return Palette.tertiary }
        switch telegram.phase {
        case .ready:
            return Palette.mint
        case .starting, .waitingForQR, .passwordRequired:
            return Palette.amber
        case .failed:
            return Palette.danger
        default:
            return Palette.tertiary
        }
    }

    private func saveCredentials() {
        let idText = apiIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = apiHashText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let apiID = Int(idText), apiID > 0 else {
            credentialError = "API ID 应该是纯数字"
            return
        }
        guard hash.count >= 8 else {
            credentialError = "请填写正确的 API Hash"
            return
        }

        TelegramCredentials.save(apiID: apiID, apiHash: hash)
        apiIDText = ""
        apiHashText = ""
        credentialError = nil
        hasCredentials = true
        telegram.bootstrap()
        showTelegramLogin = true
        AppLog.info("telegram api credentials saved")
    }

    private var diagnosticSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "诊断")
            Text("日志只记录运行状态，不包含视频内容。遇到问题时可以导出并分享。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineSpacing(2)

            if let logFileURL {
                ShareLink(item: logFileURL) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.amber)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Palette.amber.opacity(0.12))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("导出运行日志")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.text)
                            Text("shiying.log，最多保留 512 KB")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.tertiary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Palette.card.opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Palette.line, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(ScaleButtonStyle())
            } else {
                Text("暂无日志文件")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Palette.card.opacity(0.8))
                    )
            }
        }
    }

    private var logFileURL: URL? {
        let url = URL(fileURLWithPath: AppLog.logPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "剪贴板")
            VStack(spacing: 0) {
                Toggle(isOn: $store.autoReadClipboard) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动读取剪贴板")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.text)
                        Text("打开 App 或回到前台时，检测到 YouTube / Telegram 链接会直接加入下载队列")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
                .tint(Palette.amber)
                .padding(14)

                Divider()
                    .overlay(Palette.line)
                    .padding(.horizontal, 14)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.amber)
                        .padding(.top, 1)
                    Text("首次读取时 iOS 会询问是否允许粘贴，选择“允许粘贴”即可。若不希望自动读取，可关闭上面的开关，仍可用添加页里的“粘贴剪贴板”按钮。")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.card.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "存储")
            Text("已下载视频在播放后默认进入废纸篓，并在 7 天后自动删除。可以在「播放后自动清理」里为 Y / T 列表单独关闭。废纸篓里的视频可以恢复或手动彻底删除。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }
}
