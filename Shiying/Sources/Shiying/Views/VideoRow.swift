import SwiftUI
import UIKit

struct VideoRow: View {
    @ObservedObject var store: AppStore
    let item: VideoItem
    var inTrash: Bool = false
    var inDownloads: Bool = false
    var selectionEnabled: Bool = false
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onPlay: () -> Void
    var allowsContextMenu = true

    @State private var confirmDelete = false
    @State private var offsetX: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var dragDecided = false
    @State private var dragIsHorizontal = false
    @State private var rowWidth: CGFloat = 0

    /// A left swipe has to travel roughly to the middle of the row before it
    /// deletes; releasing earlier springs the row back.
    private var swipeThreshold: CGFloat {
        max(130, rowWidth * 0.45)
    }

    private var deleteProgress: CGFloat {
        min(1, max(0, -offsetX / swipeThreshold))
    }

    private var restoreProgress: CGFloat {
        min(1, max(0, offsetX / swipeThreshold))
    }

    var body: some View {
        ZStack {
            if !selectionEnabled {
                swipeBackdrop
            }

            card
                .offset(x: selectionEnabled ? 0 : offsetX)
                .simultaneousGesture(swipeGesture)
        }
        .onPreferenceChange(RowWidthPreferenceKey.self) { rowWidth = $0 }
        .confirmationDialog(deleteDialogTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteConfirmButtonTitle, role: .destructive) {
                store.deletePermanently(itemID: item.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
    }

    // MARK: - Card

    private var card: some View {
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

            Button(action: handlePrimaryAction) {
                HStack(alignment: .center, spacing: 12) {
                    VideoThumbnail(item: item, width: 132, showsPlayIcon: !inTrash)

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
        }
        .padding(10)
        .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.78))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? Palette.amber.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .accessibilityAction(named: Text(deleteActionTitle)) {
            guard !selectionEnabled else { return }
            requestDelete()
        }
        .contextMenu {
            if allowsContextMenu {
            if item.status == .ready && !inTrash {
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
                    requestDelete()
                } label: {
                    Label("彻底删除", systemImage: "trash.fill")
                }
            } else if inDownloads {
                Button(role: .destructive) {
                    requestDelete()
                } label: {
                    Label("删除任务", systemImage: "trash.fill")
                }
            } else {
                Button(role: .destructive) {
                    requestDelete()
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                }
            }
            }
        }
    }

    // MARK: - Swipe to delete

    private var swipeBackdrop: some View {
        ZStack {
            deleteBackdrop
                .opacity(deleteProgress)
            if inTrash {
                restoreBackdrop
                    .opacity(restoreProgress)
            }
        }
    }

    private var deleteBackdrop: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.danger.opacity(0.12 + 0.2 * deleteProgress))

            swipeHint(
                title: deleteProgress >= 1 ? "松手\(deleteActionTitle)" : deleteActionTitle,
                icon: deleteProgress >= 1 ? "trash.fill" : "trash",
                tint: Palette.danger,
                armed: deleteProgress >= 1
            )
            .padding(.trailing, 22)
        }
    }

    private var restoreBackdrop: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.mint.opacity(0.12 + 0.2 * restoreProgress))

            swipeHint(
                title: restoreProgress >= 1 ? "松手恢复" : "恢复",
                icon: restoreProgress >= 1 ? "checkmark.circle.fill" : "arrow.uturn.backward",
                tint: Palette.mint,
                armed: restoreProgress >= 1
            )
            .padding(.leading, 22)
        }
    }

    private func swipeHint(title: String, icon: String, tint: Color, armed: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(armed ? Color.white : tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(armed ? 0.85 : 0.18)))
        .scaleEffect(armed ? 1.05 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: armed)
        .allowsHitTesting(false)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !selectionEnabled else { return }

                if !dragDecided {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard max(dx, dy) >= 10 else { return }
                    dragDecided = true
                    dragIsHorizontal = dx > dy * 1.25
                    if dragIsHorizontal {
                        dragStartOffset = offsetX
                    }
                }

                guard dragIsHorizontal else { return }

                let limit = max(rowWidth, 320)
                let proposed = dragStartOffset + value.translation.width
                let upper: CGFloat = inTrash ? limit : 0
                offsetX = min(max(proposed, -limit), upper)
            }
            .onEnded { _ in
                let shouldSettle = dragIsHorizontal
                dragDecided = false
                dragIsHorizontal = false
                guard shouldSettle else { return }
                settleSwipe()
            }
    }

    private func settleSwipe() {
        if offsetX <= -swipeThreshold {
            triggerDelete()
        } else if inTrash && offsetX >= swipeThreshold {
            triggerRestore()
        } else {
            closeSwipe()
        }
    }

    private func triggerDelete() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard !inTrash && !inDownloads else {
            // Both are irreversible, so ask before wiping files.
            closeSwipe()
            confirmDelete = true
            return
        }

        slideOut(x: -max(rowWidth, 400))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190))
            store.moveToTrash(itemID: item.id)
            try? await Task.sleep(for: .milliseconds(320))
            offsetX = 0
        }
    }

    private func triggerRestore() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        slideOut(x: max(rowWidth, 400))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190))
            store.restore(itemID: item.id)
            try? await Task.sleep(for: .milliseconds(320))
            offsetX = 0
        }
    }

    private func slideOut(x: CGFloat) {
        withAnimation(.easeIn(duration: 0.19)) {
            offsetX = x
        }
    }

    private func closeSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            offsetX = 0
        }
    }

    private var deleteActionTitle: String {
        if inTrash { return "彻底删除" }
        if inDownloads { return "删除任务" }
        return "删除"
    }

    private var deleteDialogTitle: String {
        inDownloads ? "删除这个下载任务？" : "彻底删除这个视频？"
    }

    private var deleteConfirmButtonTitle: String {
        inDownloads ? "删除任务" : "彻底删除"
    }

    private var deleteDialogMessage: String {
        if inDownloads {
            return "任务会被取消，已下载的部分文件会从手机中删除。"
        }
        return "视频文件会立即从手机中删除，无法恢复。"
    }

    private func requestDelete() {
        closeSwipe()
        if inTrash || inDownloads {
            confirmDelete = true
        } else {
            store.moveToTrash(itemID: item.id)
        }
    }

    private func handlePrimaryAction() {
        if selectionEnabled {
            onSelect?()
            return
        }
        guard offsetX == 0 else {
            closeSwipe()
            return
        }
        primaryAction()
    }

    private func primaryAction() {
        guard !inTrash else { return }
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

private struct RowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
