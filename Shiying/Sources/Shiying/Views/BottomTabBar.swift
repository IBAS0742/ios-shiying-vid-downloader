import SwiftUI

enum AppTab {
    case youtube
    case telegram
    case downloads
    case trash
}

struct BottomTabBar: View {
    @Binding var selection: AppTab
    let downloadCount: Int
    let trashCount: Int

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.youtube, title: "Y", icon: "play.rectangle.fill", label: "YouTube")
            tabButton(.telegram, title: "T", icon: "paperplane.fill", label: "Telegram")
            tabButton(.downloads, title: "D", icon: "arrow.down.circle.fill", label: "正在下载", badge: downloadCount)
            tabButton(.trash, title: "废纸篓", icon: "trash", label: "废纸篓", badge: trashCount)
        }
        .padding(5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func tabButton(
        _ tab: AppTab,
        title: String,
        icon: String,
        label: String,
        badge: Int = 0
    ) -> some View {
        let selected = selection == tab
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Palette.background.opacity(0.75) : Palette.coral)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(selected ? Color.black.opacity(0.12) : Palette.coral.opacity(0.14))
                        )
                }
            }
            .foregroundStyle(selected ? Palette.background : Palette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    selected
                        ? AnyShapeStyle(LinearGradient(colors: [Palette.amber, Color(hex: 0xFFD38A)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.clear)
                )
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

struct ToastBanner: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
            Text(toast.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
        .padding(.horizontal, 24)
    }
}
