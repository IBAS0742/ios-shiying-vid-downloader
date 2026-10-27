import SwiftUI
import UniformTypeIdentifiers

struct SourceGroupView: View {
    @ObservedObject var store: AppStore
    let source: MediaSource
    var onAdd: () -> Void
    var onPlay: (VideoItem) -> Void
    var onSettings: () -> Void

    @State private var confirmDeleteAll = false
    @State private var showSort = false
    @State private var draggedID: UUID?
    @State private var lastDropTargetID: UUID?

    private var groupItems: [VideoItem] {
        store.playlist.filter { $0.source == source && $0.status == .ready }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header

                if groupItems.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(groupItems) { item in
                            VideoRow(store: store, item: item, onPlay: {
                                onPlay(item)
                            }, allowsContextMenu: false)
                            .onDrag {
                                draggedID = item.id
                                lastDropTargetID = nil
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: PlaylistDropDelegate(
                                targetID: item.id,
                                source: source,
                                store: store,
                                draggedID: $draggedID,
                                lastDropTargetID: $lastDropTargetID
                            ))
                        }
                    }
                }

                if source == .youtube {
                    shareGuide
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
            "彻底删除「\(source.title)」分组的全部 \(groupItems.count) 个视频？",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("全部彻底删除", role: .destructive) {
                store.deleteAllPermanently(in: source)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("视频文件会立即从手机中删除，无法恢复。")
        }
        .sheet(isPresented: $showSort) {
            PlaylistSortView(store: store, source: source)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: source.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: source.accentHex))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(hex: source.accentHex).opacity(0.13))
                        )
                    Text(store.pageTitle(for: source))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text(groupStats)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                HStack(spacing: 8) {
                    Text("仅本组连播 · 长按拖动排序")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.06)))

                    if groupItems.count > 1 {
                        Button {
                            showSort = true
                        } label: {
                            Label("排序", systemImage: "arrow.up.arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(hex: source.accentHex))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(Color(hex: source.accentHex).opacity(0.12))
                                )
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .accessibilityLabel("调整播放顺序")
                    }
                }
                .padding(.top, 2)
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    if source == .youtube {
                        Button(action: onSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(Color.white.opacity(0.07)))
                                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .accessibilityLabel("设置")
                    }

                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.background)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Palette.amber))
                            .shadow(color: Palette.amber.opacity(0.25), radius: 14, y: 6)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel("添加视频链接")
                }

                if !groupItems.isEmpty {
                    Menu {
                        if groupItems.count > 1 {
                            Button {
                                showSort = true
                            } label: {
                                Label("调整播放顺序", systemImage: "arrow.up.arrow.down")
                            }

                            Divider()
                        }
                        Button {
                            store.moveAllToTrash(in: source)
                        } label: {
                            Label("全部移到废纸篓", systemImage: "trash")
                        }
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Label("全部彻底删除", systemImage: "trash.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.secondary)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Color.white.opacity(0.07)))
                            .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                    }
                    .accessibilityLabel("更多分组操作")
                }
            }
        }
    }

    private var groupStats: String {
        let bytes = groupItems.reduce(0) { $0 + $1.fileSize }
        return "\(groupItems.count) 部影片 · \(AppPaths.formatBytes(bytes))"
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color(hex: source.accentHex).opacity(0.1))
                    .frame(width: 92, height: 92)
                Circle()
                    .strokeBorder(Color(hex: source.accentHex).opacity(0.22), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: source.icon)
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(Color(hex: source.accentHex))
            }

            VStack(spacing: 7) {
                Text("还没有 \(source.title) 视频")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("在 \(source.title) 里点「分享」，选择「拾影」。\n下载完成后会自动出现在这个分组里。")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button(action: onAdd) {
                Label("粘贴链接添加", systemImage: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 18)
        .glassPanel(cornerRadius: 26, fill: Palette.card.opacity(0.6))
    }

    private var shareGuide: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.amber)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("分享后会自动下载")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text.opacity(0.85))
                Text("支持 YouTube 视频、YouTube 播放列表，以及 Telegram 公开频道或帖子链接。不同来源会分组到不同入口（Y / T），互不连播；下载中的任务统一在 D 入口查看。若分享面板里没有「拾影」，点「更多」并把它打开。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }
}

private struct PlaylistDropDelegate: DropDelegate {
    let targetID: UUID
    let source: MediaSource
    let store: AppStore
    @Binding var draggedID: UUID?
    @Binding var lastDropTargetID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID, lastDropTargetID != targetID else { return }
        lastDropTargetID = targetID
        guard draggedID != targetID else { return }
        var ids = store.playlist.filter { $0.source == source && $0.status == .ready }.map(\.id)
        guard let from = ids.firstIndex(of: draggedID), let to = ids.firstIndex(of: targetID), from != to else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            store.reorderPlaylist(source: source, orderedIDs: ids)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        lastDropTargetID = nil
        return true
    }
}
