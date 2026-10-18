import Foundation
import NetworkExtension

/// The app's side of the Slime OS tunnel: pairing (hub POST /pair, as
/// android/.../PairingApi.kt and membrane/session/pair.sh), the VPN
/// configuration iOS keeps for the SlimeTunnel extension, and its status.
@MainActor
final class TunnelController: ObservableObject {
    static let extensionBundleId = "com.slimeos.app.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isPaired = false
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.status = conn.status }
        }
        Task { await load() }
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == Self.extensionBundleId
            }
            isPaired = manager != nil
            status = manager?.connection.status ?? .invalid
        } catch {
            lastError = "Couldn't read the VPN settings: \(error.localizedDescription)"
        }
    }

    /// Fetches this device's WireGuard config with a pairing code, saves it as
    /// the Slime OS VPN (iOS asks to allow it the first time) and starts it.
    func pair(enrollmentHost: String, code: String) async {
        lastError = nil
        do {
            let config = try await Self.fetchConfig(host: enrollmentHost, code: code)
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionBundleId
            proto.serverAddress = Self.endpointHost(in: config) ?? enrollmentHost
            proto.providerConfiguration = ["wgQuickConfig": config]
            m.protocolConfiguration = proto
            m.localizedDescription = "Slime OS"
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences() // required before starting a just-saved config
            manager = m
            isPaired = true
            start()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start() {
        guard let manager else { return }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = "Couldn't start the tunnel: \(error.localizedDescription)"
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func forget() async {
        stop()
        try? await manager?.removeFromPreferences()
        manager = nil
        isPaired = false
        status = .invalid
    }

    // MARK: Pairing

    struct PairingError: LocalizedError {
        let errorDescription: String?
    }

    private static func fetchConfig(host: String, code: String) async throws -> String {
        guard let url = URL(string: "https://\(host)/pair") else {
            throw PairingError(errorDescription: "That enrollment address isn't valid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PairingError(errorDescription: "Couldn't pair (bad response, HTTP \(http)).")
        }
        guard json["ok"] as? Bool == true, let config = json["config"] as? String else {
            throw PairingError(errorDescription: "Couldn't pair: \(json["error"] as? String ?? "unknown error").")
        }
        return config
    }

    private static func endpointHost(in config: String) -> String? {
        for line in config.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "endpoint" {
                return parts[1].split(separator: ":").first.map(String.init)
            }
        }
        return nil
    }
}

extension NEVPNStatus {
    var label: String {
        switch self {
        case .invalid: return "Not paired"
        case .disconnected: return "Off"
        case .connecting: return "Connecting…"
        case .connected: return "Secure tunnel"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Turning off…"
        @unknown default: return "Unknown"
        }
    }
}
