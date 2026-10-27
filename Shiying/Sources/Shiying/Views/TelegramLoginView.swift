import SwiftUI
import UIKit
import CoreImage

struct TelegramLoginView: View {
    @ObservedObject var session: TelegramSession
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var shareItem: ShareImage?
    @State private var hint = ""

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
        .preferredColorScheme(.dark)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.image])
        }
        .onAppear {
            session.bootstrap()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Telegram 登录")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("扫码后即可下载超过 20MB 的视频")
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

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .unconfigured:
            infoCard(
                icon: "key",
                title: "需要 API 凭证",
                text: "请先回到设置页填写 Telegram API ID 和 API Hash。免费申请方法：用你的 Telegram 手机号登录 my.telegram.org，进入「API development tools」创建一个应用。"
            )

        case .stopped:
            VStack(spacing: 14) {
                infoCard(
                    icon: "power",
                    title: "登录已停止",
                    text: "点下面的按钮重新生成登录二维码。"
                )
                primaryButton(title: "重新生成二维码", icon: "qrcode") {
                    session.bootstrap()
                }
            }

        case .starting:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.amber)
                Text("正在连接 Telegram…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)

        case .waitingForQR:
            qrSection

        case .passwordRequired:
            passwordSection

        case .ready:
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.mint)
                Text("已登录 Telegram")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(session.profileLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                Text("现在可以回到 T 面板，直接浏览已加入的群组和频道。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 10)

                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Palette.amber))
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)

        case .failed(let message):
            VStack(spacing: 14) {
                infoCard(icon: "exclamationmark.triangle", title: "登录遇到问题", text: message)
                primaryButton(title: "重试", icon: "arrow.clockwise") {
                    session.bootstrap()
                    session.refreshQRCode()
                }
            }
        }
    }

    private var qrSection: some View {
        VStack(spacing: 16) {
            if let link = session.qrLink {
                QRCodeImage(text: link)
                    .frame(width: 236, height: 236)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                    .padding(.top, 6)

                Text("用 Telegram 扫一扫")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)

                VStack(alignment: .leading, spacing: 9) {
                    step(1, "在已登录 Telegram 的手机上打开「设置 → 设备」")
                    step(2, "点「扫描二维码」，对准上面的码")
                    step(3, "手机不在身边？点“分享 / 发送到电脑”，把二维码发到电脑上，再用同一台手机的 Telegram 扫描屏幕")
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        )
                )

                HStack(spacing: 10) {
                    actionButton(title: "分享 / 发送到电脑", icon: "square.and.arrow.up") {
                        guard let image = QRCodeRenderer.image(from: link) else { return }
                        shareItem = ShareImage(image: image)
                    }
                    actionButton(title: "保存到相册", icon: "photo") {
                        guard let image = QRCodeRenderer.image(from: link) else { return }
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        hint = "已保存到相册，可在相册里打开并用同一台手机扫描"
                    }
                }

                Button {
                    UIPasteboard.general.string = link
                    hint = "登录链接已复制"
                } label: {
                    Text("复制登录链接")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }

                Text("二维码会自动刷新，扫码后在手机上确认即可。")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.amber)
                    .padding(.vertical, 60)
            }

            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.mint)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            infoCard(
                icon: "lock.shield",
                title: "需要两步验证密码",
                text: session.passwordHint.isEmpty
                    ? "这个账号开启了两步验证，请输入 Telegram 密码完成登录。"
                    : "密码提示：\(session.passwordHint)"
            )

            SecureField("Telegram 两步验证密码", text: $password)
                .font(.system(size: 14))
                .foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(15)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.cardLift)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        )
                )

            Button {
                let value = password
                password = ""
                Task { await session.submitPassword(value) }
            } label: {
                Text("确认密码")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.background)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.amber))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
        }
    }

    private func infoCard(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Palette.card.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)
                )
        )
    }

    private func primaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(Palette.amber))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct QRCodeImage: View {
    let text: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(Palette.background)
            }
        }
        .task(id: text) {
            image = QRCodeRenderer.image(from: text)
        }
    }
}

enum QRCodeRenderer {
    static func image(from text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = 720 / max(output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
