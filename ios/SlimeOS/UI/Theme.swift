import SwiftUI
import UIKit

/// The Membrane kiosk's and the Android app's look (android/.../ui/SlimeTheme.kt).
enum Slime {
    static let shell = Color(hex: 0x05080B)
    static let surface = Color(hex: 0x13191F)
    static let elevated = Color(hex: 0x1C2530)
    static let field = Color(hex: 0x0D1217)
    static let teal = Color(hex: 0x00C2A8)
    static let tealDeep = Color(hex: 0x008B99)
    static let cyan = Color(hex: 0x00F2FE)
    static let mint = Color(hex: 0x5FE6D2)
    static let auroraBlue = Color(hex: 0x4FACFE)
    static let auroraGreen = Color(hex: 0x00FF87)
    static let title = Color(hex: 0xF2F6FB)
    static let text = Color(hex: 0xEAF1F7)
    static let textSoft = Color(hex: 0xC9D3DF)
    static let textMuted = Color(hex: 0x8B97A7)
    static let textHost = Color(hex: 0x7D8A9A)
    static let textDim = Color(hex: 0x56616F)
    static let error = Color(hex: 0xFF8F8F)
    static let amber = Color(hex: 0xF5B955)
    static let onAccent = Color(hex: 0x04221F)

    static let border = Color.white.opacity(0.08)
    static let borderField = Color.white.opacity(0.12)
    static let borderButton = Color.white.opacity(0.14)

    /// .btn-primary: linear-gradient(150deg, #00F2FE, #00C2A8).
    static let accentGradient = LinearGradient(colors: [cyan, teal], startPoint: .topLeading,
                                               endPoint: .bottomTrailing)
    /// The Brain avatars' colours, in order.
    static let accents = [teal, auroraBlue, auroraGreen]

    // Variable fonts (android/app/src/main/res/font), weight set on the wght axis.
    static func display(_ size: CGFloat, _ weight: CGFloat = 600) -> Font { font("SpaceGrotesk-Light", size, weight) }
    static func body(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { font("PlusJakartaSans-Regular", size, weight) }
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { font("JetBrainsMono-Regular", size, weight) }

    private static func font(_ name: String, _ size: CGFloat, _ weight: CGFloat) -> Font {
        let wght = 0x7767_6874 // 'wght'
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: name,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// .app: the shell with two soft glows, teal top-left and blue bottom-right.
struct SlimeBackground: View {
    var body: some View {
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height)
            ZStack {
                Slime.shell
                RadialGradient(colors: [Slime.teal.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.15, y: 0.10), startRadius: 0, endRadius: r * 0.9)
                RadialGradient(colors: [Slime.auroraBlue.opacity(0.08), .clear],
                               center: UnitPoint(x: 0.90, y: 0.90), startRadius: 0, endRadius: r * 0.85)
            }
        }
        .ignoresSafeArea()
    }
}

/// A screen: background, centred content that scrolls when it doesn't fit.
struct SlimeScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            SlimeBackground()
            ScrollView {
                VStack(spacing: 18) { content }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct SlimeMark: View {
    var size: CGFloat = 56
    var body: some View {
        Image("SlimeMark").resizable().scaledToFit().frame(height: size)
    }
}

struct SlimeCard<Content: View>: View {
    var maxWidth: CGFloat = 460
    var border: Color = Slime.border
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(22)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(Slime.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(border, lineWidth: 1))
    }
}

struct ScreenTitle: View {
    let text: String
    var size: CGFloat = 30
    var body: some View {
        Text(text).font(Slime.display(size, 700)).foregroundStyle(Slime.title).multilineTextAlignment(.center)
    }
}

struct Muted: View {
    let text: String
    var center = false
    var body: some View {
        Text(text).font(Slime.body(15)).foregroundStyle(Slime.textMuted)
            .multilineTextAlignment(center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StageText: View {
    let text: String
    var body: some View {
        Text(text).font(Slime.mono(13)).foregroundStyle(Slime.textSoft).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Slime.display(16, 700)).foregroundStyle(Slime.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Slime.accentGradient, in: RoundedRectangle(cornerRadius: 12))
                .opacity(enabled ? 1 : 0.45)
        }
        .disabled(!enabled)
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Slime.display(16, 600)).foregroundStyle(Slime.text)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Slime.elevated, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Slime.borderButton, lineWidth: 1))
        }
    }
}

struct TertiaryButton: View {
    let title: String
    var color: Color = Slime.textMuted
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Slime.display(15, 600)).foregroundStyle(color).padding(.vertical, 8)
        }
    }
}

struct DangerButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Slime.display(16, 600)).foregroundStyle(Color(hex: 0xFF6B6B))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color(hex: 0x3A1414), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xFF6B6B).opacity(0.3), lineWidth: 1))
        }
    }
}

/// input.field with its mono label above.
struct SlimeField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Slime.mono(11, 600)).foregroundStyle(Slime.textMuted).kerning(1)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Slime.textDim))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Slime.textDim))
                        .keyboardType(keyboard)
                }
            }
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled()
            .font(Slime.body(16))
            .foregroundStyle(Slime.text)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Slime.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Slime.borderField, lineWidth: 1))
        }
    }
}

struct FieldError: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text).font(Slime.body(13)).foregroundStyle(Slime.error)
        }
    }
}

/// The ring + mark while something is in progress.
struct PulsingMark: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().stroke(Slime.teal.opacity(0.25), lineWidth: 2).frame(width: 110, height: 110)
                .scaleEffect(on ? 1.12 : 0.92).opacity(on ? 0 : 1)
            SlimeMark(size: 54)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

enum BadgeKind {
    case online, asleep, offline, slimeId, demo
    var label: String {
        switch self {
        case .online: return "Online"
        case .asleep: return "Asleep"
        case .offline: return "Offline"
        case .slimeId: return "Slime ID"
        case .demo: return "Demo"
        }
    }
    var color: Color {
        switch self {
        case .online: return Slime.auroraGreen
        case .asleep: return Slime.amber
        case .offline: return Slime.error
        case .slimeId: return Slime.auroraBlue
        case .demo: return Slime.teal
        }
    }
}

struct Badge: View {
    let kind: BadgeKind
    var body: some View {
        Text(kind.label.uppercased()).font(Slime.mono(10, 600)).kerning(0.8)
            .foregroundStyle(kind.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(kind.color.opacity(0.12), in: Capsule())
    }
}
