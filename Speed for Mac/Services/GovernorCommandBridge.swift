import Foundation
import Darwin

final class GovernorCommandBridge {
    private var lastSentTier: GovernorTier?
    private var lastSentLOD: Double?
    private var lastSentAt: Date?
    private var disableSent: Bool = false

    func send(decision: GovernorDecision, host: String, port: Int) -> String? {
        let now = Date()
        if let lastSentTier,
           let lastSentLOD,
           let lastSentAt,
           lastSentTier == decision.tier,
           abs(lastSentLOD - decision.targetLOD) < 0.01,
           now.timeIntervalSince(lastSentAt) < 5 {
            return nil
        }

        let message = String(format: "PROJECT_SPEED|SET_LOD|%.3f|%@", decision.targetLOD, decision.tier.rawValue)
        let error = sendUDP(message: message, host: host, port: port)
        if error == nil {
            self.lastSentTier = decision.tier
            self.lastSentLOD = decision.targetLOD
            self.lastSentAt = now
            self.disableSent = false
        }
        return error
    }

    func sendDisable(host: String, port: Int) -> String? {
        guard !disableSent else { return nil }

        let error = sendUDP(message: "PROJECT_SPEED|DISABLE", host: host, port: port)
        if error == nil {
            disableSent = true
            lastSentTier = nil
            lastSentLOD = nil
            lastSentAt = Date()
        }
        return error
    }

    private func sendUDP(message: String, host: String, port: Int) -> String? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return "Governor bridge failed to create UDP socket."
        }
        defer { Darwin.close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)

        let conversionResult = host.withCString { cString in
            inet_pton(AF_INET, cString, &address.sin_addr)
        }
        guard conversionResult == 1 else {
            return "Governor bridge invalid host: \(host)."
        }

        let data = Array(message.utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, data, data.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        if sent < 0 {
            return "Governor bridge send error: \(String(cString: strerror(errno)))."
        }

        return nil
    }
}
