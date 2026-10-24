import SwiftUI
import UIKit

enum Palette {
    static let background = Color(hex: 0x08090D)
    static let backgroundLift = Color(hex: 0x10121A)
    static let card = Color(hex: 0x141722)
    static let cardLift = Color(hex: 0x1A1E2B)
    static let line = Color.white.opacity(0.08)
    static let text = Color(hex: 0xF5F2EC)
    static let secondary = Color(hex: 0x9B9EAA)
    static let tertiary = Color(hex: 0x666B7A)
    static let amber = Color(hex: 0xFFB45A)
    static let coral = Color(hex: 0xFF6D5A)
    static let mint = Color(hex: 0x68D8B0)
    static let danger = Color(hex: 0xFF5E68)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Palette.background
            LinearGradient(
                colors: [Color(hex: 0x1A1320).opacity(0.95), Palette.background, Palette.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Palette.coral.opacity(0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: 170, y: -320)
            Circle()
                .fill(Palette.amber.opacity(0.08))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: -160, y: 260)
        }
        .ignoresSafeArea()
    }
}

struct AppMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.amber, Palette.coral],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.34, weight: .black))
                .foregroundStyle(Palette.background)
                .offset(x: size * 0.025)
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.22, weight: .black))
                .foregroundStyle(Palette.background.opacity(0.9))
                .offset(x: size * 0.26, y: size * 0.27)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.coral.opacity(0.28), radius: 14, y: 6)
    }
}

struct SectionLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            Spacer()
        }
    }
}

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 24
    var fill: Color = Palette.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 24, fill: Color = Palette.card) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, fill: fill))
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

enum ImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}
