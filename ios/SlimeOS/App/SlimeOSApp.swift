import SwiftUI

@main
struct SlimeOSApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Store.wipeIfReinstalled()   // before AppModel reads the Keychain
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Slime.teal)
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}
