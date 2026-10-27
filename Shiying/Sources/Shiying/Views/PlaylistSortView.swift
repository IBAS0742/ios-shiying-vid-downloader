import SwiftUI

/// Drag-and-drop editor for a source playlist. The order is written back to
/// `AppStore` only when the user taps 完成, so swiping the sheet away is safe.
struct PlaylistSortView: View {
    @ObservedObject var store: AppStore
    let source: MediaSource

    @Environment(\.dismiss) private var dismiss
    @State private var orderedIDs: [UUID]
    @State private var showResetConfirm = false

    init(store: AppStore, source: MediaSource) {
        self.store = store
        self.source = source
        let ids = store.playlist
            .filter { $0.source == source && $0.status == .ready }
            .map(\.id)
        _orderedIDs = State(initialValue: ids)
    }

    private var items: [VideoItem] {
        orderedIDs.compactMap { id in
            store.items.first(where: { $0.id == id })
        }
    }

    private var accent: Color {
        Color(hex: source.accentHex)
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                header

                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                row(item)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(
                                        EdgeInsets(
                                            top: 5,
                                            leading: 20,
                                            bottom: 5,
                                            trailing: 20
                                        )
                                    )
                            }
                            .onMove(perform: move)
                        } header: {
                            Text("按住右侧手柄上下拖动；点「完成」后生效。")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.tertiary)
                                .textCase(nil)
                                .padding(.leading, 4)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, .constant(.active))
                    .tint(accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
        .confirmationDialog(
            "恢复最新优先排序？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复最新优先") {
                resetToNewestFirst()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按加入时间重新排列，你手动调整的顺序会被覆盖。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("调整播放顺序")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("\(source.title) · \(items.count) 个视频")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }

            Spacer(minLength: 8)

            Button {
                showResetConfirm = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(items.count < 2)
            .accessibilityLabel("恢复最新优先排序")

            Button {
                store.reorderPlaylist(source: source, orderedIDs: orderedIDs)
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private func row(_ item: VideoItem) -> some View {
        HStack(spacing: 12) {
            VideoThumbnail(item: item, width: 88)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if let resolution = item.resolutionText {
                        Text(resolution)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.secondary)
                    }
                    Text(item.durationText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiary)
                    Text(AppPaths.formatBytes(item.fileSize))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .glassPanel(cornerRadius: 18, fill: Palette.card.opacity(0.78))
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.number")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Text("这个列表还没有可排序的视频")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("下载完成后，视频会出现在这里。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func move(from source: IndexSet, to destination: Int) {
        orderedIDs.move(fromOffsets: source, toOffset: destination)
    }

    private func resetToNewestFirst() {
        orderedIDs = store.items
            .filter { $0.source == source && !$0.isTrashed && $0.status == .ready }
            .sorted { $0.addedAt > $1.addedAt }
            .map(\.id)
    }
}
