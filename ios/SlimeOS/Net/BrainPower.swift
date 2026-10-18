import Foundation
import Network

/// The hub's power service over the tunnel (android/.../BrainPower.kt,
/// membrane/freerdp/connect.sh's wake_brain): wake an idle-deallocated Brain,
/// the picker's badges, and the clean-end logoff (#17).
enum BrainPower {
    private static let powerURL = "http://10.10.0.1:7677"

    enum WakeState: Equatable {
        case ready, starting, failed
        /// The hub is still logging off the previous session (#17); ~10 s.
        case cleaning
        /// The hub is restarting the Brain after a frozen session.
        case restarting
        /// The hub refused: this device isn't on the Brain's POWER_VMS list.
        case notAllowed
        case error
    }

    /// notAllowed: asleep, and the hub won't wake it for this device.
    enum Status { case online, asleep, notAllowed, offline }

    static func wake(_ host: String) async -> WakeState {
        guard let (code, json) = try? await request("wake", method: "POST", body: ["host": host], timeout: 10) else {
            return .error
        }
        // A 403 carries no "managed" field, which must not read as "unmanaged,
        // go ahead": a managed Brain that's asleep would then just time out.
        if code == 403 { return .notAllowed }
        guard let json, json["managed"] as? Bool == true else { return .ready }
        switch json["state"] as? String {
        case "running": return .ready
        case "failed": return .failed
        case "cleaning": return .cleaning
        case "restarting": return .restarting
        default: return .starting
        }
    }

    /// The picker's badge: RDP answers -> online; else a Brain the hub manages
    /// is asleep (it wakes on connect); else offline. Read-only: /status never
    /// starts a VM.
    static func status(_ host: String, _ port: Int) async -> Status {
        if await rdpListening(host, port) { return .online }
        let query = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        guard let (code, json) = try? await request("status?host=\(query)", method: "GET", body: nil, timeout: 3) else {
            return .offline
        }
        if code == 403 { return .notAllowed }
        return json?["managed"] as? Bool == true ? .asleep : .offline
    }

    /// Round trip to the hub through the tunnel in ms, or nil without an answer.
    static func pingHubMs() async -> Int? {
        let start = Date()
        guard (try? await request("status", method: "GET", body: nil, timeout: 3)) != nil else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Fire-and-forget: after a clean end, the hub logs off the disconnected
    /// session so the next connect starts fresh (#17).
    static func notifySessionEnded(_ host: String) {
        Task.detached { _ = try? await request("session-ended", method: "POST", body: ["host": host], timeout: 5) }
    }

    /// Asks the hub to restart a frozen Brain; true when it took it on.
    static func restart(_ host: String) async -> Bool {
        guard let (code, json) = try? await request("restart", method: "POST", body: ["host": host], timeout: 10) else {
            return false
        }
        return code == 200 && json?["state"] as? String == "restarting"
    }

    /// Azure reports "running" well before Windows listens for RDP.
    static func rdpListening(_ host: String, _ port: Int, timeout: TimeInterval = 2) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { cont in
            let done = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if done.take() { connection.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled: if done.take() { cont.resume(returning: false) }
                case .waiting: if done.take() { connection.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if done.take() { connection.cancel(); cont.resume(returning: false) }
            }
        }
    }

    private static func request(_ path: String, method: String, body: [String: Any]?, timeout: TimeInterval)
        async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: URL(string: "\(powerURL)/\(path)")!, timeoutInterval: timeout)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Resumes a continuation once, whichever callback gets there first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
