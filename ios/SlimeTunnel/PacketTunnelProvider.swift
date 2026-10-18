import NetworkExtension
import WireGuardKit
import os

/// The Slime OS tunnel: WireGuard to the hub, routing only the hub's network
/// (the config's AllowedIPs), so the rest of the device's traffic is untouched.
/// The config comes from the app in providerConfiguration["wgQuickConfig"].
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.slimeos.app.tunnel", category: "tunnel")

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
        adapter.start(tunnelConfiguration: config) { [log] error in
            if let error {
                log.error("Tunnel didn't start: \(String(describing: error), privacy: .public)")
            } else {
                log.info("Tunnel up")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }
}
