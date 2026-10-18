import SwiftUI

/// A Brain session, full screen, with a small bar: status, keyboard, close.
struct SessionScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RdpSession
    @State private var keyboardShown = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            SessionView(session: session, keyboardShown: $keyboardShown)
                .ignoresSafeArea()
            HStack(spacing: 10) {
                if case .reconnecting = session.state {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Reconnecting…").font(Slime.body(13, 600)).foregroundStyle(.white)
                    }
                } else if !session.hasLivePicture {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Reconnecting…").font(Slime.body(13, 600)).foregroundStyle(.white)
                    }
                }
                Button { keyboardShown.toggle() } label: {
                    Image(systemName: "keyboard").foregroundStyle(.white)
                }
                .accessibilityLabel("Keyboard")
                Button { model.closeSession() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.9))
                }
                .accessibilityLabel("Disconnect")
            }
            .font(.system(size: 17))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
