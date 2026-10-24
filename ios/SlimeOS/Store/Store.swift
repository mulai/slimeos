import Foundation
import Security

/// What the app keeps (android/.../SavedPairing.kt): the saved Brains (their
/// Windows passwords included) and the Slime ID session, in the Keychain,
/// readable only while the device is unlocked and never synced or backed up to
/// another device. The tunnel's WireGuard config lives in the VPN configuration
/// iOS keeps for the extension (TunnelController).
struct SavedBrain: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var host: String
    var port: Int = 3389
    var username: String = ""
    var password: String = ""
    var kind: String = "free"
    /// Its id on the Slime ID account, when it came from (or matches) the account's
    /// list: a paid Brain's Windows sign-in is fetched by that id.
    var slimeIdBrainId: String?
    var lastConnected: Date?

    func sameAddress(_ host: String, _ port: Int) -> Bool {
        self.host.caseInsensitiveCompare(host) == .orderedSame && self.port == port
    }
}

struct SlimeIdSession: Codable, Equatable {
    var token: String
    var email: String
    var name: String
}

enum Store {
    static var brains: [SavedBrain] {
        get { read("brains", as: [SavedBrain].self) ?? [] }
        set { write("brains", newValue) }
    }

    static var slimeId: SlimeIdSession? {
        get { read("slimeid", as: SlimeIdSession.self) }
        set { write("slimeid", newValue) }
    }

    static func put(_ brain: SavedBrain) {
        var list = brains
        if let i = list.firstIndex(where: { $0.id == brain.id }) {
            list[i] = brain
        } else {
            list.append(brain)
        }
        brains = list
    }

    static func remove(_ id: String) {
        brains = brains.filter { $0.id != id }
    }

    static func wipe() {
        brains = []
        slimeId = nil
        Keychain.delete("applock")
    }

    /// iOS keeps Keychain items after the app is deleted, so a new install would
    /// start with the old PIN, Brains and sign-in. UserDefaults goes with the app:
    /// no marker there means a new install, which starts clean (as on Android).
    static func wipeIfReinstalled() {
        let marker = "installed"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        wipe()
        UserDefaults.standard.set(true, forKey: marker)
    }

    private static func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = Keychain.get(key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ key: String, _ value: T?) {
        if let value, let data = try? JSONEncoder().encode(value) {
            Keychain.set(key, data)
        } else {
            Keychain.delete(key)
        }
    }
}

/// Generic-password items for this app only, this device only.
enum Keychain {
    private static let service = "com.slimeos.app"

    static func get(_ key: String) -> Data? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ key: String, _ data: Data) {
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        if SecItemUpdate(base(key) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base(key).merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}
