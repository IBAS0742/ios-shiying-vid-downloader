import SwiftUI
import UIKit

struct AddLinkView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorText: String?
    @State private var didAttemptAutoPaste = false
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("添加视频")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.secondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white.opacity(0.07)))
                    }
                }

                Text("粘贴 YouTube 视频 / 播放列表，或 Telegram 公开频道 / 帖子链接。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(2)

                HStack(spacing: 10) {
                    Label("下载画质", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)

                    Spacer()

                    Menu {
                        ForEach(DownloadQuality.allCases) { quality in
                            Button {
                                store.downloadQuality = quality
                            } label: {
                                if quality == store.downloadQuality {
                                    Label(quality.title, systemImage: "checkmark")
                                } else {
                                    Text(quality.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(store.downloadQuality.shortLabel)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.amber)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.amber)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Palette.amber.opacity(0.12)))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        )
                )

                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://youtube.com/... 或 https://t.me/...", text: $text, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .padding(15)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Palette.cardLift)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            errorText == nil ? Palette.line : Palette.danger.opacity(0.55),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .onChange(of: text) { _, _ in
                            errorText = nil
                        }

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.danger)
                    }

                    if isWorking, let activity = store.importActivity {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Palette.amber)
                            Text(activity)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.amber)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.text)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(ScaleButtonStyle())

                        Spacer()

                        Button(action: add) {
                            HStack(spacing: 6) {
                                if isWorking {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(Palette.background)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(isWorking ? "正在解析…" : "开始下载")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.background)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(Palette.amber))
                        }
                        .disabled(isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                        .buttonStyle(ScaleButtonStyle())
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.amber)
                    Text("更顺手的方式：在 YouTube 或 Telegram 里点分享，选择「拾影」，链接会自动进入下载队列。Telegram 仅支持公开频道和公开帖子。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                        .lineSpacing(2)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
        }
        .presentationDetents([.height(545)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focused = true
            }
        }
        .task {
            await autoFillFromClipboard()
        }
    }

    @MainActor
    private func autoFillFromClipboard() async {
        guard store.autoReadClipboard, !didAttemptAutoPaste else { return }
        didAttemptAutoPaste = true

        try? await Task.sleep(for: .milliseconds(450))
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else { return }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, LinkExtractor.hasSupportedLink(in: trimmed) else { return }

        text = trimmed
        errorText = nil
        AppLog.info("auto filled clipboard link")
    }

    private func pasteFromClipboard() {
        guard let value = UIPasteboard.general.string, !value.isEmpty else {
            errorText = "剪贴板里没有文字"
            return
        }
        text = value
    }

    private func add() {
        guard !isWorking else { return }
        let value = text
        isWorking = true
        errorText = nil

        Task {
            let result = await store.importInput(value)
            isWorking = false
            switch result {
            case .success, .duplicate:
                dismiss()
            case .invalid(let message):
                errorText = message
            }
        }
    }
}
