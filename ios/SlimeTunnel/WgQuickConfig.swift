import Foundation
import WireGuardKit

/// Parses the wg-quick config the hub's /pair returns (the same text the
/// Membrane writes to /etc/wireguard/wg0.conf and Android parses with
/// com.wireguard.config.Config). Only the keys the hub sends are read.
enum WgQuickConfig {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String, name: String = "Slime OS") throws -> TunnelConfiguration {
        // Pass 1: each section's keys (lowercased) and values.
        var interfaceKeys: [String: String]?
        var peerKeys: [[String: String]] = []
        var inPeer = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            switch line.lowercased() {
            case "[interface]":
                inPeer = false
                interfaceKeys = interfaceKeys ?? [:]
                continue
            case "[peer]":
                inPeer = true
                peerKeys.append([:])
                continue
            default:
                break
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw ParseError(description: "bad line: \(line)") }
            if inPeer {
                peerKeys[peerKeys.count - 1][parts[0].lowercased()] = parts[1]
            } else {
                interfaceKeys?[parts[0].lowercased()] = parts[1]
            }
        }

        // Pass 2: WireGuardKit's types.
        guard let i = interfaceKeys, let keyText = i["privatekey"], let key = PrivateKey(base64Key: keyText) else {
            throw ParseError(description: "no [Interface] PrivateKey")
        }
        var interface = InterfaceConfiguration(privateKey: key)
        interface.addresses = list(i["address"]).compactMap { IPAddressRange(from: $0) }
        interface.dns = list(i["dns"]).compactMap { DNSServer(from: $0) }
        interface.mtu = i["mtu"].flatMap { UInt16($0) }

        let peers = try peerKeys.map { p -> PeerConfiguration in
            guard let pubText = p["publickey"], let pub = PublicKey(base64Key: pubText) else {
                throw ParseError(description: "[Peer] without a valid PublicKey")
            }
            var peer = PeerConfiguration(publicKey: pub)
            peer.preSharedKey = p["presharedkey"].flatMap { PreSharedKey(base64Key: $0) }
            peer.allowedIPs = list(p["allowedips"]).compactMap { IPAddressRange(from: $0) }
            peer.endpoint = p["endpoint"].flatMap { Endpoint(from: $0) }
            peer.persistentKeepAlive = p["persistentkeepalive"].flatMap { UInt16($0) }
            return peer
        }
        guard !peers.isEmpty else { throw ParseError(description: "no [Peer]") }
        return TunnelConfiguration(name: name, interface: interface, peers: peers)
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
