import Foundation
import UIKit

/// "Sign in with Slime ID", the same slimeos.com device endpoints the Membrane
/// and the Android app use (android/.../SlimeId.kt): a device-code sign-in
/// approved on a phone, the account's Brain list, saving a Brain to the
/// account, and a paid Brain's Windows sign-in. Slime ID never holds the
/// WireGuard credential: a Brain from the list still needs this device's
/// pairing to reach it.
enum SlimeId {
    private static let api = "https://www.slimeos.com/api/device"

    struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let qr: UIImage?
        let expiresIn: TimeInterval
        let interval: TimeInterval
    }

    enum Poll {
        case pending, expired
        case approved(SlimeIdSession)
    }

    /// A Brain on the account (brains-list.ts). kind is "free" or "paid".
    struct RemoteBrain: Identifiable, Equatable {
        let id: String
        let kind: String
        let name: String
        let host: String
        let port: Int
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// device/start: a code to approve at slimeos.com/device.
    static func start() async throws -> DeviceCode {
        let (code, json) = try await post("start", ["label": deviceLabel()], timeout: 10)
        guard let json, (200..<300).contains(code),
              let deviceCode = json["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = json["user_code"] as? String, !userCode.isEmpty else {
            throw Failure(errorDescription: "HTTP \(code): \((json?["error"] as? String) ?? "no code")")
        }
        return DeviceCode(deviceCode: deviceCode, userCode: userCode,
                          verificationUri: json["verification_uri"] as? String ?? "",
                          qr: decodeDataUrl(json["qr_data_url"] as? String ?? ""),
                          expiresIn: TimeInterval(json["expires_in"] as? Int ?? 900),
                          interval: TimeInterval(max(json["interval"] as? Int ?? 4, 1)))
    }

    /// device/poll. Network trouble reads as pending: the caller just asks again.
    static func poll(_ deviceCode: String) async -> Poll {
        guard let (_, json) = try? await post("poll", ["device_code": deviceCode], timeout: 5), let json else {
            return .pending
        }
        switch json["status"] as? String {
        case "approved":
            let user = json["user"] as? [String: Any]
            guard let token = json["session_token"] as? String, !token.isEmpty else { return .expired }
            return .approved(SlimeIdSession(token: token, email: user?["email"] as? String ?? "",
                                            name: user?["name"] as? String ?? ""))
        case "expired": return .expired
        default: return .pending
        }
    }

    /// Best effort: the device forgets the session either way.
    static func logout(_ token: String) async {
        _ = try? await post("logout", ["session_token": token], timeout: 5)
    }

    /// device/brains-list; nil when it couldn't be fetched (keep what's shown).
    static func brains(_ token: String) async -> [RemoteBrain]? {
        guard let (code, json) = try? await post("brains-list", ["session_token": token], timeout: 5),
              (200..<300).contains(code), let json else { return nil }
        let list = json["brains"] as? [[String: Any]] ?? []
        return list.compactMap { b in
            guard let id = b["id"] as? String, !id.isEmpty else { return nil }
            // Server data: only well-formed addresses reach the picker (#37).
            let host = (b["host"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let port = Int((b["port"] as? String ?? "").trimmingCharacters(in: .whitespaces)) ?? 3389
            guard validHost(host), (1...65535).contains(port) else { return nil }
            let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return RemoteBrain(id: id, kind: b["kind"] as? String ?? "free",
                               name: name.isEmpty ? "Untitled Brain" : name, host: host, port: port)
        }
    }

    /// device/brains-save: the opt-in "Save to your Slime ID?".
    static func saveBrain(_ token: String, name: String, host: String, port: Int) async -> Bool {
        let body: [String: Any] = ["session_token": token, "name": name, "host": host, "port": String(port)]
        guard let (code, json) = try? await post("brains-save", body, timeout: 5) else { return false }
        return (200..<300).contains(code) && json?["ok"] as? Bool == true
    }

    /// device/brain-credential: a paid Brain's Windows sign-in, fetched fresh
    /// before a connect and never stored. nil for any failure.
    static func credential(_ token: String, brainId: String) async -> (username: String, password: String)? {
        guard let (code, json) = try? await post("brain-credential", ["session_token": token, "brainId": brainId],
                                                 timeout: 5),
              (200..<300).contains(code), let json, json["ok"] as? Bool == true,
              let password = json["password"] as? String, !password.isEmpty else { return nil }
        return (json["username"] as? String ?? "", password)
    }

    /// j***e@example.com.
    static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return email }
        let local = parts[0]
        let masked = local.count <= 2 ? "\(first)*" : "\(first)***\(local.last!)"
        return "\(masked)@\(parts[1])"
    }

    /// XXXX-XXXX, as on the kiosk.
    static func displayCode(_ userCode: String) -> String {
        userCode.count == 8 ? "\(userCode.prefix(4))-\(userCode.suffix(4))" : userCode
    }

    static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let pattern = #"^(?:(?:\d{1,3}\.){3}\d{1,3}|[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)$"#
        return host.range(of: pattern, options: .regularExpression) != nil
    }

    /// Names this device on slimeos.com/device and in the account's device list.
    private static func deviceLabel() -> String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespaces)
        return String((name.isEmpty ? "Slime OS iPhone" : name).prefix(40))
    }

    private static func decodeDataUrl(_ url: String) -> UIImage? {
        guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]),
                              options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    private static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws
        -> (Int, [String: Any]?) {
        var request = URLRequest(url: URL(string: "\(api)/\(path)")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
