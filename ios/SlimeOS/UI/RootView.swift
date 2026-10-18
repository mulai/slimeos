import SwiftUI

/// PIN first, then the current screen; the session full screen without the strip.
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.pinSet || model.changingPin {
                PinSetupScreen()
            } else if model.locked {
                PinUnlockScreen()
            } else if case .session = model.screen, let session = model.session {
                SessionScreen(session: session)
            } else {
                VStack(spacing: 0) {
                    StatusStrip(tunnel: model.tunnel)
                    screen.frame(maxHeight: .infinity)
                }
                .background(SlimeBackground())
            }
        }
        .sheet(isPresented: $model.settingsShown) { SettingsView(tunnel: model.tunnel) }
        .alert(item: $model.modal) { modal in alert(for: modal) }
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .welcome: WelcomeScreen()
        case let .pair(hint): PairScreen(hint: hint)
        case let .working(title): WorkingScreen(title: title)
        case let .slimeIdEntry(code): SlimeIdEntryScreen(code: code)
        case .addBrain: AddBrainScreen()
        case let .credentials(brain): CredentialsScreen(brain: brain).id(brain.id)
        case .picker: PickerScreen()
        case let .connecting(name): ConnectingScreen(name: name)
        case let .reconnecting(name, attempt): ReconnectingScreen(name: name, attempt: attempt)
        case .session: ConnectingScreen(name: "your Brain")
        case let .error(title, body, detail, retry, reenter):
            ErrorScreen(title: title, body_: body, detail: detail, retry: retry, reenter: reenter)
        }
    }

    private func alert(for modal: AppModel.Modal) -> Alert {
        switch modal {
        case let .removeBrain(brain):
            return Alert(title: Text("Remove \(brain.name)?"),
                         message: Text("Its address and sign-in are removed from this device. The Brain itself isn't touched."),
                         primaryButton: .destructive(Text("Remove")) { model.remove(brain) },
                         secondaryButton: .cancel())
        case let .saveToSlimeId(brain):
            return Alert(title: Text("Save to your Slime ID?"),
                         message: Text("\(brain.name) will show on your other devices too. Its password stays on this device."),
                         primaryButton: .default(Text("Save")) { model.saveToSlimeId(brain) },
                         secondaryButton: .cancel(Text("Not now")))
        case .forgetPairing:
            return Alert(title: Text("Forget this device's pairing?"),
                         message: Text("You'll need a new pairing code to connect to your Brains again."),
                         primaryButton: .destructive(Text("Forget")) { model.forgetPairing() },
                         secondaryButton: .cancel())
        case .resetApp:
            return Alert(title: Text("Reset Slime OS?"),
                         message: Text("This removes the PIN, the pairing, your saved Brains and your Slime ID sign-in from this device. You'll need a new pairing code."),
                         primaryButton: .destructive(Text("Reset")) { model.resetApp() },
                         secondaryButton: .cancel())
        }
    }
}
