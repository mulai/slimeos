import SwiftUI

@main
struct SlimeOSApp: App {
    var body: some Scene {
        WindowGroup {
            TestConnectView()
                .preferredColorScheme(.dark)
        }
    }
}
