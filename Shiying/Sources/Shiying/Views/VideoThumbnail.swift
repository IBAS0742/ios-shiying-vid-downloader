import SwiftUI
import UIKit

struct VideoThumbnail: View {
    let item: VideoItem
    var width: CGFloat = 138
    var showsPlayIcon = true

    private var height: CGFloat { width * 9 / 16 }

    var body: some View {
        ZStack {
            if let image = ImageCache.image(at: item.thumbnailFileURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x2A2233), Color(hex: 0x171A24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Palette.secondary.opacity(0.5))
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center,
                endPoint: .bottom
            )

            if item.status == .ready && showsPlayIcon {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.black.opacity(0.42)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            }

            VStack {
                Spacer()
                HStack {
                    if let resolution = item.resolutionText, item.status == .ready {
                        Text(resolution)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.5)))
                    }
                    Spacer()
                    if item.duration > 0 {
                        Text(item.durationText)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
                    }
                }
                .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .opacity(item.isTrashed ? 0.7 : 1)
    }
}

struct StatusLine: View {
    @ObservedObject var store: AppStore
    let item: VideoItem

    var body: some View {
        switch item.status {
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .foregroundStyle(Palette.amber)
                Text("排队中 · 第 \(queuePosition) 位")
                    .foregroundStyle(Palette.amber)
            }
        case .resolving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.amber)
                Text("正在解析视频…")
                    .foregroundStyle(Palette.amber)
            }
        case .downloading:
            if store.downloadsPaused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(Palette.coral)
                    Text("已暂停 · \(Int((store.progress[item.id] ?? 0) * 100))%")
                        .foregroundStyle(Palette.coral)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Palette.amber)
                        Text("下载中 \(Int((store.progress[item.id] ?? 0) * 100))%")
                            .foregroundStyle(Palette.amber)
                        if let speed = store.downloadSpeedText(for: item.id) {
                            Text("·")
                                .foregroundStyle(Palette.tertiary)
                            Text(speed)
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    ProgressView(value: store.progress[item.id] ?? 0)
                        .tint(Palette.amber)
                        .scaleEffect(x: 1, y: 0.7, anchor: .center)
                }
            }
        case .retrying:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.amber)
                Text("正在重试 \(item.retryCount)/\(AppStore.maxAutoRetries)…")
                    .foregroundStyle(Palette.amber)
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.danger)
                Text(item.errorMessage ?? "下载失败，点按重试")
                    .foregroundStyle(Palette.danger.opacity(0.9))
                    .lineLimit(2)
            }
        case .ready:
            HStack(spacing: 7) {
                if item.isTrashed {
                    Image(systemName: "clock")
                    Text(item.deletionText)
                        .foregroundStyle(Palette.coral)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.mint)
                    Text(AppPaths.formatBytes(item.fileSize))
                        .foregroundStyle(Palette.secondary)
                    Text("·")
                        .foregroundStyle(Palette.tertiary)
                    Text("离线可用")
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private var queuePosition: Int {
        let waiting = store.items
            .filter { !$0.isTrashed && $0.status == .queued }
            .sorted { $0.addedAt < $1.addedAt }
        return (waiting.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
    }
}
