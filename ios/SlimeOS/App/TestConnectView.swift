import SwiftUI

/// Milestone 1 test screen: connect straight to an RDP host on the local
/// network. Replaced by the real Slime ID / Brain list screens later.
struct TestConnectView: View {
    @AppStorage("test.host") private var host = ""
    @AppStorage("test.username") private var username = ""
    @State private var password = ""
    @State private var session: RdpSession?
    @StateObject private var tunnel = TunnelController()
    @AppStorage("test.enrollHost") private var enrollHost = ""
    @State private var pairCode = ""
    @State private var pairing = false

    var body: some View {
        if let session {
            SessionScreen(session: session) { self.session = nil }
        } else {
            Form {
                Section("Tunnel") {
                    LabeledContent("Status", value: tunnel.status.label)
                    if tunnel.isPaired {
                        if tunnel.status == .connected || tunnel.status == .connecting {
                            Button("Turn off") { tunnel.stop() }
                        } else {
                            Button("Turn on") { tunnel.start() }
                        }
                        Button("Forget pairing", role: .destructive) { Task { await tunnel.forget() } }
                    } else {
                        TextField("Enrollment host", text: $enrollHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Pairing code", text: $pairCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button(pairing ? "Pairing…" : "Pair") {
                            pairing = true
                            Task {
                                await tunnel.pair(enrollmentHost: enrollHost.trimmingCharacters(in: .whitespaces),
                                                  code: pairCode.trimmingCharacters(in: .whitespaces).uppercased())
                                pairing = false
                            }
                        }
                        .disabled(pairing || enrollHost.isEmpty || pairCode.isEmpty)
                    }
                    if let error = tunnel.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("Test connection") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Button("Connect") { connect() }
                    .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
    }

    private func connect() {
        let s = RdpSession()
        // Twice the screen in points, landscape, width a multiple of 4.
        let bounds = UIScreen.main.bounds
        let w = UInt32(max(bounds.width, bounds.height) * 2) & ~3
        let h = UInt32(min(bounds.width, bounds.height) * 2) & ~1
        var user = username
        var domain = ""
        if let slash = username.firstIndex(of: "\\") {
            domain = String(username[..<slash])
            user = String(username[username.index(after: slash)...])
        }
        s.connect(host: host, username: user, password: password, domain: domain, width: w, height: h)
        session = s
    }
}

struct SessionScreen: View {
    @ObservedObject var session: RdpSession
    let onClose: () -> Void
    @State private var keyboardShown = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SessionView(session: session, keyboardShown: $keyboardShown)
                .ignoresSafeArea()
            HStack(spacing: 8) {
                Text(status).font(.caption).foregroundStyle(.white.opacity(0.8))
                Button { keyboardShown.toggle() } label: { Image(systemName: "keyboard") }
                Button {
                    if case .ended = session.state { onClose() } else { session.disconnect() }
                } label: { Image(systemName: "xmark.circle.fill") }
            }
            .padding(8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: session.state) { _, state in
            if case .ended(0, _) = state { onClose() }
        }
    }

    private var status: String {
        switch session.state {
        case .idle, .connecting: return "Connecting…"
        case .connected: return ""
        case let .ended(error, info):
            return String(format: "Ended (error 0x%08X, info %u)", error, info)
        }
    }
}
