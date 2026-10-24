import NetworkExtension
import WireGuardKit
import os

/// The Slime OS tunnel: WireGuard to the hub, routing only the hub's network
/// (the config's AllowedIPs), so the rest of the device's traffic is untouched.
/// The config comes from the app in providerConfiguration["wgQuickConfig"].
///
/// The tunnel is only on while the app is in use. The app turns it off when it
/// leaves the screen, but iOS keeps this extension running if the app is killed
/// without leaving it first (swiped away from the app switcher, a crash), so
/// the app also checks in every 20 s (TunnelController's heartbeat) and
/// the tunnel turns itself off when it stops hearing from it.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let appSilenceLimit: TimeInterval = 60
    private static let appWatchTick = 15

    private let log = Logger(subsystem: "com.slimeos.app.tunnel", category: "tunnel")
    private let watchQueue = DispatchQueue(label: "com.slimeos.app.tunnel.app-watch")
    private var appWatch: DispatchSourceTimer?
    private var lastAppCheckIn = Date()

    private lazy var adapter = WireGuardAdapter(with: self) { [log] level, message in
        log.log(level: level == .error ? .error : .info, "\(message, privacy: .public)")
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let text = proto.providerConfiguration?["wgQuickConfig"] as? String else {
            log.error("No tunnel config")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        let config: TunnelConfiguration
        do {
            config = try WgQuickConfig.parse(text)
        } catch {
            log.error("Bad tunnel config: \(String(describing: error), privacy: .public)")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        adapter.start(tunnelConfiguration: config) { [weak self, log] error in
            if let error {
                log.error("Tunnel didn't start: \(String(describing: error), privacy: .public)")
            } else {
                log.info("Tunnel up")
                self?.watchApp()
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        watchQueue.async {
            self.appWatch?.cancel()
            self.appWatch = nil
        }
        adapter.stop { _ in completionHandler() }
    }

    /// Any message from the app is a check-in.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        watchQueue.async { self.lastAppCheckIn = Date() }
        completionHandler?(nil)
    }

    private func watchApp() {
        watchQueue.async {
            self.lastAppCheckIn = Date()
            self.appWatch?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.watchQueue)
            timer.schedule(deadline: .now() + .seconds(Self.appWatchTick), repeating: .seconds(Self.appWatchTick))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let silent = Date().timeIntervalSince(self.lastAppCheckIn)
                guard silent >= Self.appSilenceLimit else { return }
                self.log.info("Nothing from the app for \(Int(silent)) s; turning the tunnel off")
                self.appWatch?.cancel()
                self.appWatch = nil
                self.cancelTunnelWithError(nil)
            }
            self.appWatch = timer
            timer.resume()
        }
    }
}
