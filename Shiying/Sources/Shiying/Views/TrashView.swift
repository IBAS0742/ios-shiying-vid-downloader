import SwiftUI

struct TrashView: View {
    @ObservedObject var store: AppStore

    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteSelected = false

    private var allTrashIDs: Set<UUID> {
        Set(store.trash.map(\.id))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                policyCard

                if store.trash.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 11) {
                        SectionLabel(title: "待清理", count: store.trash.count)
                        LazyVStack(spacing: 10) {
                            ForEach(store.trash) { item in
                                VideoRow(
                                    store: store,
                                    item: item,
                                    inTrash: true,
                                    selectionEnabled: selecting,
                                    isSelected: selectedIDs.contains(item.id),
                                    onSelect: { toggle(item.id) },
                                    onPlay: {},
                                    allowsContextMenu: false
                                )
                            }
                        }
                    }
                }

                Color.clear.frame(height: selecting ? 140 : 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .refreshable {
            await store.refresh()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selecting)
        .confirmationDialog(
            "清空废纸篓？",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("全部彻底删除", role: .destructive) {
                store.deleteAllTrash()
                exitSelection()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("废纸篓里的 \(store.trash.count) 个视频会立即从手机中删除，无法恢复。")
        }
        .confirmationDialog(
            "彻底删除选中的 \(selectedIDs.count) 个视频？",
            isPresented: $confirmDeleteSelected,
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) {
                store.deleteBatchPermanently(selectedIDs)
                exitSelection()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("视频文件会立即从手机中删除，无法恢复。")
        }
        .onChange(of: store.trash.count) { _, newCount in
            if newCount == 0 {
                exitSelection()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("废纸篓")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("看过的内容会在这里等待 7 天。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()

            if !store.trash.isEmpty {
                VStack(alignment: .trailing, spacing: 9) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selecting.toggle()
                            if !selecting {
                                selectedIDs.removeAll()
                            }
                        }
                    } label: {
                        Text(selecting ? "完成" : "批量选择")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selecting ? Palette.background : Palette.text)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(selecting ? Palette.amber : Color.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(selecting ? Color.clear : Palette.line, lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle())

                    if !selecting {
                        Button {
                            confirmDeleteAll = true
                        } label: {
                            Label("一键清空", systemImage: "trash.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.coral)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Palette.coral.opacity(0.1)))
                                .overlay(Capsule().strokeBorder(Palette.coral.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button {
                if selectedIDs.count == store.trash.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = allTrashIDs
                }
            } label: {
                Text(selectedIDs.count == store.trash.count && !store.trash.isEmpty ? "取消全选" : "全选")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())

            Spacer()

            Button {
                store.restoreBatch(selectedIDs)
                exitSelection()
            } label: {
                Label("恢复 (\(selectedIDs.count))", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(selectedIDs.isEmpty)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)

            Button {
                confirmDeleteSelected = true
            } label: {
                Label("删除 (\(selectedIDs.count))", systemImage: "trash.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.coral)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Palette.coral.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Palette.coral.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(selectedIDs.isEmpty)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)
        }
        .padding(10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func exitSelection() {
        selecting = false
        selectedIDs.removeAll()
    }

    private var policyCard: some View {
        HStack(spacing: 13) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.coral)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.coral.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                Text("默认 7 天后自动删除")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("废纸篓中的视频不支持播放；右滑恢复到片库后可播放，左滑彻底删除。支持批量恢复、批量删除和一键清空。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .glassPanel(cornerRadius: 22, fill: Palette.card.opacity(0.65))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.tertiary)
            Text("废纸篓是空的")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text.opacity(0.9))
            Text("播放过的视频会出现在这里，\n并在 7 天后自动永久删除。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}
