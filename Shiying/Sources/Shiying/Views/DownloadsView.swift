import SwiftUI

struct DownloadsView: View {
    @ObservedObject var store: AppStore

    @State private var confirmDeleteAll = false

    private var activeCount: Int {
        store.items.filter {
            !$0.isTrashed && ($0.status == .resolving || $0.status == .downloading || $0.status == .retrying)
        }.count
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !store.downloadsGroup.isEmpty {
                    controls
                }

                if store.downloadsGroup.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.downloadsGroup) { item in
                            VideoRow(store: store, item: item, inDownloads: true) {}
                        }
                    }
                }

                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .refreshable {
            await store.refresh()
        }
        .confirmationDialog(
            "删除全部下载任务？",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("全部删除", role: .destructive) {
                store.deleteAllDownloads()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("正在下载的任务会被取消，排队中的任务会被移除，已下载好的视频不受影响。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("正在下载")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(headerStatus)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            Image(systemName: store.downloadsPaused ? "pause.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(store.downloadsPaused ? Palette.coral : Palette.amber)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(
                        (store.downloadsPaused ? Palette.coral : Palette.amber).opacity(0.1)
                    )
                )
        }
        .padding(.top, 2)
    }

    private var headerStatus: String {
        if store.downloadsPaused {
            return "已全部暂停"
        }
        let queued = store.queuedCount
        var text = queued > 0
            ? "同时下载 \(store.maxConcurrentDownloads) 个 · \(queued) 个排队中"
            : "同时最多下载 \(store.maxConcurrentDownloads) 个"
        if let speed = store.totalDownloadSpeedText {
            text += " · \(speed)"
        }
        return text
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                if store.downloadsPaused {
                    store.resumeAllDownloads()
                } else {
                    store.pauseAllDownloads()
                }
            } label: {
                Image(systemName: store.downloadsPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.background)
                    .frame(width: 44, height: 38)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel(store.downloadsPaused ? "全部开始" : "全部暂停")

            Menu {
                ForEach(1...4, id: \.self) { count in
                    Button {
                        store.maxConcurrentDownloads = count
                    } label: {
                        if store.maxConcurrentDownloads == count {
                            Label("同时下载 \(count) 个", systemImage: "checkmark")
                        } else {
                            Text("同时下载 \(count) 个")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(store.maxConcurrentDownloads) 个")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            }

            Spacer()

            Button {
                confirmDeleteAll = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.coral)
                    .frame(width: 44, height: 38)
                    .background(Capsule().fill(Palette.coral.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Palette.coral.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("全部删除")
        }
        .padding(12)
        .glassPanel(cornerRadius: 22, fill: Palette.card.opacity(0.7))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.tertiary)
            Text("没有正在下载的任务")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text.opacity(0.9))
            Text("从 YouTube 或 Telegram 分享视频后，\n下载任务会出现在这里。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}
