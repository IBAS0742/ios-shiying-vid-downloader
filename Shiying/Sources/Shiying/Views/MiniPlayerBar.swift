import SwiftUI

struct MiniPlayerBar: View {
    @ObservedObject var session: PlaybackSession
    @ObservedObject var model: PlayerViewModel
    @ObservedObject var store: AppStore
    let item: VideoItem

    @State private var glowPulse = false

    private var progress: Double {
        guard model.duration > 0.1 else { return 0 }
        return min(max(model.currentTime / model.duration, 0), 1)
    }

    private var glowColor: Color {
        model.isPlaying ? Palette.mint : Palette.danger
    }

    private var glowOpacity: Double {
        glowPulse ? 0.55 : 0.14
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    session.expand()
                } label: {
                    HStack(spacing: 10) {
                        thumbnail
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                            Text("\(timeText(model.currentTime)) / \(timeText(model.duration))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Palette.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开播放器")

                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.background)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.amber))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")

                Button {
                    session.playNext(using: store)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("播放下一个视频")

                Button {
                    AppLog.info("mini player closed")
                    session.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("关闭播放")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 7)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule()
                        .fill(Palette.amber)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.cardLift)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(glowColor.opacity(glowOpacity * 0.55), lineWidth: 3)
                .blur(radius: 4)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(glowColor.opacity(glowOpacity), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .animation(.easeInOut(duration: 0.45), value: model.isPlaying)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var thumbnail: some View {
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
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.secondary.opacity(0.7))
            }
        }
        .frame(width: 52, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
