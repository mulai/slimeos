import CommonCrypto
import Foundation

/// The app's PIN (android/.../AppLock.kt): chosen on first run, asked when the
/// app opens and after a while in the background. Only a salted PBKDF2 hash is
/// kept (Keychain). Wrong PINs lock entry for longer and longer. A forgotten
/// PIN means resetting the app, never a way around it.
enum AppLock {
    static let pinLength = 6

    enum Check: Equatable {
        case ok
        case wrong(triesBeforeWait: Int)
        case wait(until: Date)
    }

    private struct State: Codable {
        var salt: Data
        var hash: Data
        var failures = 0
        var retryAt: Date?
    }

    private static let iterations: UInt32 = 60_000
    private static let freeTries = 5
    /// After freeTries wrong PINs: 30 s, 1 min, 5 min, then 15 min a try.
    private static let lockout: [TimeInterval] = [30, 60, 5 * 60, 15 * 60]

    static var isSet: Bool { state != nil }

    /// Until when entry is locked, nil when it isn't.
    static var retryAt: Date? {
        guard let at = state?.retryAt, at > Date() else { return nil }
        // A clock set back must not lengthen the wait past the longest step.
        return min(at, Date().addingTimeInterval(lockout.last!))
    }

    /// Slow on purpose (PBKDF2): call off the main thread.
    static func set(_ pin: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        state = State(salt: salt, hash: hash(pin, salt))
    }

    /// Slow on purpose (PBKDF2): call off the main thread.
    static func check(_ pin: String) -> Check {
        if let wait = retryAt { return .wait(until: wait) }
        guard var s = state else { return .ok }
        if constantTimeEqual(hash(pin, s.salt), s.hash) {
            s.failures = 0
            s.retryAt = nil
            state = s
            return .ok
        }
        s.failures += 1
        defer { state = s }
        if s.failures < freeTries { return .wrong(triesBeforeWait: freeTries - s.failures) }
        let step = lockout[min(s.failures - freeTries, lockout.count - 1)]
        s.retryAt = Date().addingTimeInterval(step)
        return .wait(until: s.retryAt!)
    }

    static func clear() {
        Keychain.delete("applock")
    }

    private static var state: State? {
        get { Keychain.get("applock").flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Keychain.set("applock", data)
            } else {
                Keychain.delete("applock")
            }
        }
    }

    private static func hash(_ pin: String, _ salt: Data) -> Data {
        var out = Data(count: 32)
        let pinBytes = Array(pin.utf8)
        _ = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pinBytes.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
