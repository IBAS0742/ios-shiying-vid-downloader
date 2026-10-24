import SwiftUI

struct VideoRow: View {
    @ObservedObject var store: AppStore
    let item: VideoItem
    var inTrash: Bool = false
    var inDownloads: Bool = false
    var selectionEnabled: Bool = false
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onPlay: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if selectionEnabled {
                Button {
                    onSelect?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundStyle(isSelected ? Palette.amber : Palette.tertiary.opacity(0.6))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(ScaleButtonStyle())
            }

            Button(action: selectionEnabled ? (onSelect ?? {}) : primaryAction) {
                HStack(alignment: .center, spacing: 12) {
                    VideoThumbnail(item: item, width: 132)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            if !item.channel.isEmpty {
                                Text(item.channel)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.secondary)
                                    .lineLimit(1)
                            }

                            Text(item.source.shortLabel)
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color(hex: item.source.accentHex))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(hex: item.source.accentHex).opacity(0.13)))
                        }

                        StatusLine(store: store, item: item)
                            .font(.system(size: 11, weight: .medium))

                        if item.status == .downloading {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.08))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: store.downloadsPaused
                                                    ? [Palette.secondary.opacity(0.7), Palette.secondary.opacity(0.4)]
                                                    : [Palette.amber, Palette.coral],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(5, proxy.size.width * (store.progress[item.id] ?? 0)))
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(ScaleButtonStyle())

            if !selectionEnabled {
                Menu {
                    if item.status == .ready {
                        Button {
                            onPlay()
                        } label: {
                            Label("播放", systemImage: "play.fill")
                        }
                    }

                    if item.status == .failed {
                        Button {
                            store.retry(itemID: item.id)
                        } label: {
                            Label("重新下载", systemImage: "arrow.clockwise")
                        }
                    }

                    if item.status == .retrying {
                        Button {
                            store.abortAutoRetry(itemID: item.id)
                        } label: {
                            Label("取消自动重试", systemImage: "xmark.circle")
                        }
                    }

                    if inTrash {
                        Button {
                            store.restore(itemID: item.id)
                        } label: {
                            Label("恢复到片库", systemImage: "arrow.uturn.backward")
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("彻底删除", systemImage: "trash.fill")
                        }
                    } else if inDownloads {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("删除任务", systemImage: "trash.fill")
                        }
                    } else {
                        Button(role: .destructive) {
                            store.moveToTrash(itemID: item.id)
                        } label: {
                            Label("移到废纸篓", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.055)))
                }
            }
        }
        .padding(10)
        .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? Palette.amber.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .contextMenu {
            if item.status == .ready {
                Button {
                    onPlay()
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
            }
            if item.status == .failed {
                Button {
                    store.retry(itemID: item.id)
                } label: {
                    Label("重新下载", systemImage: "arrow.clockwise")
                }
            }
            if item.status == .retrying {
                Button {
                    store.abortAutoRetry(itemID: item.id)
                } label: {
                    Label("取消自动重试", systemImage: "xmark.circle")
                }
            }
            if inTrash {
                Button {
                    store.restore(itemID: item.id)
                } label: {
                    Label("恢复到片库", systemImage: "arrow.uturn.backward")
                }
            } else if inDownloads {
                Button(role: .destructive) {
                    store.deletePermanently(itemID: item.id)
                } label: {
                    Label("删除任务", systemImage: "trash.fill")
                }
            } else {
                Button(role: .destructive) {
                    store.moveToTrash(itemID: item.id)
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("彻底删除这个视频？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("彻底删除", role: .destructive) {
                store.deletePermanently(itemID: item.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("视频文件会立即从手机中删除，无法恢复。")
        }
    }

    private func primaryAction() {
        switch item.status {
        case .ready:
            onPlay()
        case .failed:
            store.retry(itemID: item.id)
        case .queued, .resolving, .downloading, .retrying:
            break
        }
    }
}
