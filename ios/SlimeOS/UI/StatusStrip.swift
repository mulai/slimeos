import NetworkExtension
import SwiftUI

/// .status-strip: brand on the left, the tunnel and settings on the right. The
/// tunnel shows its quality in its own colour and words, never as bars, so it
/// can't be mistaken for the Wi-Fi or mobile signal in iOS's status bar.
struct StatusStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tunnel: TunnelController

    var body: some View {
        HStack(spacing: 10) {
            Image("SlimeMark").resizable().scaledToFit().frame(height: 18)
            Text("Slime OS").font(Slime.mono(12, 600)).foregroundStyle(Slime.textSoft)
            Spacer()
            if tunnel.isPaired {
                HStack(spacing: 6) {
                    Circle().fill(quality.color).frame(width: 7, height: 7)
                    Text(quality.label).font(Slime.mono(11, 600)).foregroundStyle(quality.color)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(quality.color.opacity(0.10), in: Capsule())
                .accessibilityLabel("Secure tunnel: \(quality.label)")
            }
            Button { model.settingsShown = true } label: {
                Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(Slime.textSoft)
                    .frame(width: 36, height: 30)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
    }

    private var quality: (label: String, color: Color) {
        switch tunnel.status {
        case .connected:
            guard let ms = model.hubPingMs else { return ("Secure tunnel", Slime.teal) }
            if ms >= 400 { return ("Tunnel weak", Slime.error) }
            if ms >= 200 { return ("Tunnel slow", Slime.amber) }
            return ("Secure tunnel", Slime.teal)
        case .connecting, .reasserting: return ("Connecting…", Slime.amber)
        default: return ("Tunnel off", Slime.textDim)
        }
    }
}
