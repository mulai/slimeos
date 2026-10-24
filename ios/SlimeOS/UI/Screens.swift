import SwiftUI

// The home and flow screens (android/.../ui/SlimeScreens.kt).

struct WelcomeScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SlimeScreen {
            SlimeMark(size: 64).padding(.top, 8)
            ScreenTitle(text: "Welcome to Slime OS")
            Muted(text: "Your Brain is a computer in the cloud that does the heavy lifting. Add one so this device can connect to it.",
                  center: true)
                .frame(maxWidth: 420)
            DemoBrainCard { model.demoBrainShown = true }
                .frame(maxWidth: 360)
            VStack(spacing: 12) {
                PrimaryButton(title: "Add a Brain") { model.addBrain() }
                SlimeIdFooter()
            }
            .frame(maxWidth: 360)
        }
    }
}

/// The welcome screen's Demo Brain (the kiosk's demoBrainCardHTML).
private struct DemoBrainCard: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("D").font(Slime.display(20, 700)).foregroundStyle(Slime.onAccent)
                        .frame(width: 42, height: 42)
                        .background(Slime.teal, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Demo Brain").font(Slime.display(17, 600)).foregroundStyle(Slime.title)
                            Badge(kind: .demo)
                        }
                        Text("slimeos.com").font(Slime.mono(12)).foregroundStyle(Slime.textHost)
                    }
                    Spacer(minLength: 0)
                }
                Text("See what a Brain feels like").font(Slime.body(13)).foregroundStyle(Slime.textMuted)
                Text("Try it →").font(Slime.display(14, 600)).foregroundStyle(Slime.teal)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Slime.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Slime.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SlimeIdFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let email = model.slimeIdEmail {
            HStack(spacing: 6) {
                Text("Signed in as \(SlimeId.maskEmail(email))").font(Slime.body(13)).foregroundStyle(Slime.textMuted)
                TertiaryButton(title: "Sign out") { model.signOutSlimeId() }
            }
        } else {
            SecondaryButton(title: "Sign in with Slime ID") { model.startSlimeIdSignIn() }
        }
    }
}

struct SlimeIdEntryScreen: View {
    @EnvironmentObject var model: AppModel
    let code: SlimeId.DeviceCode
    var body: some View {
        SlimeScreen {
            ScreenTitle(text: "Sign in with Slime ID", size: 26)
            SlimeCard(maxWidth: 420) {
                Muted(text: "Scan this code with your phone, or visit \(code.verificationUri) and enter the code below.")
                if let qr = code.qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 180, height: 180).padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code")
                }
                Text(SlimeId.displayCode(code.userCode)).font(Slime.mono(28, 600)).foregroundStyle(Slime.title)
                    .kerning(3).frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    ProgressView().tint(Slime.teal)
                    StageText(text: "Waiting for approval…")
                }
                .frame(maxWidth: .infinity)
            }
            TertiaryButton(title: "Back") { model.cancelSlimeIdSignIn() }
        }
    }
}

struct PairScreen: View {
    @EnvironmentObject var model: AppModel
    let hint: String?
    @AppStorage("pair.host") private var host = ""
    @State private var code = ""

    var body: some View {
        SlimeScreen {
            ScreenTitle(text: "Pair with a Brain", size: 26)
            SlimeCard {
                Muted(text: hint ?? "Enter the enrollment address and the code your admin gave you.")
                SlimeField(label: "Enrollment host", text: $host, placeholder: "e.g. enroll.slimeos.com", keyboard: .URL)
                SlimeField(label: "Pairing code", text: $code, placeholder: "8 characters", capitalization: .characters)
                // App Review 5.4: say what the VPN does before iOS asks to add it.
                Text("Pairing adds a VPN configuration: a private, encrypted connection from this device to your Brain, on only while you use Slime OS. Your other apps and browsing don't go through it, and Slime OS doesn't collect or look at your traffic.")
                    .font(Slime.body(12.5)).foregroundStyle(Slime.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Pair", enabled: !host.trimmed.isEmpty && !code.trimmed.isEmpty) {
                    model.pair(host: host.trimmed, code: code.trimmed.uppercased())
                }
            }
            TertiaryButton(title: "Back") { model.showHome() }
        }
    }
}

struct WorkingScreen: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var cancel: (() -> Void)?
    var body: some View {
        SlimeScreen {
            PulsingMark().padding(.top, 30)
            ScreenTitle(text: title, size: 24)
            StageText(text: model.stage).frame(maxWidth: 420)
            if let cancel { TertiaryButton(title: "Cancel", action: cancel) }
        }
    }
}

struct AddBrainScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var host = ""
    @State private var port = "3389"
    @State private var error: String?

    var body: some View {
        SlimeScreen {
            ScreenTitle(text: "Add a Brain", size: 26)
            SlimeCard {
                Muted(text: "Enter its name and address to connect.")
                SlimeField(label: "Name", text: $name, placeholder: "My Brain", capitalization: .words)
                SlimeField(label: "Address", text: $host, placeholder: "IP address or hostname", keyboard: .URL)
                SlimeField(label: "Port", text: $port, placeholder: "3389", keyboard: .numberPad)
                FieldError(text: error)
                PrimaryButton(title: "Continue") {
                    let h = host.trimmed
                    guard SlimeId.validHost(h) else { error = "Enter a valid IP address or hostname."; return }
                    guard let p = Int(port.trimmed), (1...65535).contains(p) else {
                        error = "Port must be between 1 and 65535."; return
                    }
                    model.brainAdded(name: name.trimmed, host: h, port: p)
                }
            }
            TertiaryButton(title: "Cancel") { model.showHome() }
        }
    }
}

struct CredentialsScreen: View {
    @EnvironmentObject var model: AppModel
    let brain: SavedBrain
    @State private var username: String
    @State private var password = ""
    @State private var error: String?

    init(brain: SavedBrain) {
        self.brain = brain
        _username = State(initialValue: brain.username)
    }

    var body: some View {
        SlimeScreen {
            ScreenTitle(text: "Who signs in on \(brain.name)?", size: 24)
            SlimeCard {
                Muted(text: "We'll remember this, stored securely on this device.")
                SlimeField(label: "Username", text: $username, placeholder: "Windows username")
                SlimeField(label: "Password", text: $password, placeholder: "Password", secure: true)
                FieldError(text: error)
                PrimaryButton(title: "Connect") {
                    guard !username.trimmed.isEmpty else { error = "Enter the Windows username."; return }
                    guard !password.isEmpty else { error = "Enter the password."; return }
                    model.credentialsEntered(brain, username: username.trimmed, password: password)
                }
            }
            TertiaryButton(title: "Back") { model.showHome() }
        }
    }
}

struct PickerScreen: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)]

    var body: some View {
        SlimeScreen {
            VStack(spacing: 4) {
                ScreenTitle(text: "Choose a Brain", size: 28)
                Text("Tap a card to connect").font(Slime.body(14)).foregroundStyle(Slime.textMuted)
            }
            if let notice = model.notice {
                Text(notice).font(Slime.body(14)).foregroundStyle(Slime.amber)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.pickerItems) { item in BrainCard(item: item) }
                AddCard { model.addBrain() }
            }
            .frame(maxWidth: 1100)
            SlimeIdFooter().frame(maxWidth: 360)
        }
        .refreshable {
            model.refreshBrainStatus()
            model.refreshRemoteBrains()
        }
    }
}

private struct BrainCard: View {
    let item: AppModel.PickerItem

    var body: some View {
        Button(action: item.action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(String(item.name.prefix(1)).uppercased())
                        .font(Slime.display(20, 700)).foregroundStyle(Slime.onAccent)
                        .frame(width: 42, height: 42)
                        .background(accent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(item.name).font(Slime.display(17, 600)).foregroundStyle(Slime.title).lineLimit(1)
                            if let badge { Badge(kind: badge) }
                        }
                        Text(item.host).font(Slime.mono(12)).foregroundStyle(Slime.textHost).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(subtitle).font(Slime.body(13)).foregroundStyle(Slime.textMuted).lineLimit(2)
                Text(item.remote ? "Tap to reconnect →" : "Connect →").font(Slime.display(14, 600))
                    .foregroundStyle(Slime.teal)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Slime.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Slime.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let remove = item.remove {
                Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private var accent: Color {
        // Stable across launches (hashValue isn't).
        Slime.accents[item.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Slime.accents.count]
    }

    private var badge: BadgeKind? {
        if item.remote { return .slimeId }
        switch item.status {
        case .online: return .online
        case .asleep, .notAllowed: return .asleep
        case .offline: return .offline
        case nil: return nil
        }
    }

    private var subtitle: String {
        if item.remote { return "Not paired on this device" }
        switch item.status {
        case .asleep: return "Wakes up when you connect"
        case .notAllowed: return "Asleep; this device can't wake it"
        case .offline: return "Not reachable right now"
        default:
            guard let last = item.lastConnected else { return "Not connected yet" }
            return "Last connected \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))"
        }
    }
}

private struct AddCard: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Slime.teal)
                Text("Add a Brain").font(Slime.display(16, 600)).foregroundStyle(Slime.textSoft)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }
        .buttonStyle(.plain)
    }
}

struct ConnectingScreen: View {
    @EnvironmentObject var model: AppModel
    let name: String
    var body: some View {
        WorkingScreen(title: "Connecting to \(name)", cancel: { model.cancelConnect() })
    }
}

struct ReconnectingScreen: View {
    @EnvironmentObject var model: AppModel
    let name: String
    let attempt: Int
    var body: some View {
        WorkingScreen(title: "Reconnecting to \(name)…", cancel: { model.cancelConnect() })
    }
}

struct ErrorScreen: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let body_: String?
    let detail: String?
    let retry: Bool
    let reenter: Bool
    @State private var showDetail = false

    var body: some View {
        SlimeScreen {
            SlimeCard(maxWidth: 440, border: Color(hex: 0xFF6F6F).opacity(0.18)) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Color(hex: 0xFF6B6B))
                    .frame(width: 52, height: 52).background(Color(hex: 0xFF6B6B).opacity(0.12), in: Circle())
                Text(title).font(Slime.display(20, 700)).foregroundStyle(Slime.title)
                if let body_ { Muted(text: body_) }
                if let detail {
                    DisclosureGroup(isExpanded: $showDetail) {
                        Text(detail).font(Slime.mono(12)).foregroundStyle(Slime.textMuted).textSelection(.enabled)
                    } label: {
                        Text("Technical details").font(Slime.mono(12)).foregroundStyle(Slime.textDim)
                    }
                    .tint(Slime.textDim)
                }
                VStack(spacing: 10) {
                    if retry { PrimaryButton(title: "Try again") { model.retry() } }
                    if reenter { SecondaryButton(title: "Re-enter password") { model.reenterPassword() } }
                    TertiaryButton(title: "Back") { model.showHome() }
                }
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
