import Foundation
import Darwin

struct GovernorBridgeSendResult {
    let sent: Bool
    let error: String?
    let statusText: String
}

final class GovernorCommandBridge {
    private(set) var lastSentTier: GovernorTier?
    private(set) var lastSentLOD: Double?
    private(set) var lastSentAt: Date?
    private(set) var lastSuccessfulSendAt: Date?
    private(set) var lastError: String?

    private var enabledCommandSent: Bool = false
    private var disableSent: Bool = false
    private var commandSequence: UInt64 = 0

    private let fallbackFileURL = URL(fileURLWithPath: "/tmp/ProjectSpeed_lod_target.txt")

    func send(
        lod: Double,
        tier: GovernorTier,
        host: String,
        port: Int,
        now: Date,
        minimumInterval: TimeInterval,
        minimumDelta: Double
    ) -> GovernorBridgeSendResult {
        if !enabledCommandSent {
            if let enableError = sendCommand(command: "ENABLE", host: host, port: port) {
                lastError = enableError
                return GovernorBridgeSendResult(sent: false, error: enableError, statusText: "Not connected")
            }
            enabledCommandSent = true
            disableSent = false
        }

        if let lastSentAt,
           now.timeIntervalSince(lastSentAt) < max(minimumInterval, 0.1) {
            return GovernorBridgeSendResult(sent: false, error: nil, statusText: commandStatusText(now: now))
        }

        if let lastSentLOD,
           abs(lastSentLOD - lod) < max(minimumDelta, 0.005) {
            return GovernorBridgeSendResult(sent: false, error: nil, statusText: commandStatusText(now: now))
        }

        let command = String(format: "SET_LOD %.3f", lod)
        if let error = sendCommand(command: command, host: host, port: port) {
            lastError = error
            return GovernorBridgeSendResult(sent: false, error: error, statusText: "Not connected")
        }

        lastSentTier = tier
        lastSentLOD = lod
        lastSentAt = now
        lastSuccessfulSendAt = now
        lastError = nil
        disableSent = false

        return GovernorBridgeSendResult(sent: true, error: nil, statusText: commandStatusText(now: now))
    }

    func sendTestLOD(lod: Double, host: String, port: Int, now: Date) -> GovernorBridgeSendResult {
        if !enabledCommandSent {
            if let enableError = sendCommand(command: "ENABLE", host: host, port: port) {
                lastError = enableError
                return GovernorBridgeSendResult(sent: false, error: enableError, statusText: "Not connected")
            }
            enabledCommandSent = true
            disableSent = false
        }

        let command = String(format: "SET_LOD %.3f", lod)
        if let error = sendCommand(command: command, host: host, port: port) {
            lastError = error
            return GovernorBridgeSendResult(sent: false, error: error, statusText: "Not connected")
        }

        lastSentLOD = lod
        lastSentAt = now
        lastSuccessfulSendAt = now
        lastError = nil

        return GovernorBridgeSendResult(sent: true, error: nil, statusText: commandStatusText(now: now))
    }

    func sendDisable(host: String, port: Int) -> String? {
        guard !disableSent else { return nil }

        let error = sendCommand(command: "DISABLE", host: host, port: port)
        if error == nil {
            disableSent = true
            enabledCommandSent = false
            lastSentTier = nil
            lastSentLOD = nil
            lastSentAt = Date()
            lastError = nil
        } else {
            lastError = error
        }
        return error
    }

    func commandStatusText(now: Date) -> String {
        if lastError != nil {
            return "Not connected"
        }

        if let lastSuccessfulSendAt {
            let age = now.timeIntervalSince(lastSuccessfulSendAt)
            if age <= 10 {
                return "Connected"
            }
            if lastSentLOD != nil {
                return "Connected (idle)"
            }
            return "Not connected"
        }

        return "Not connected"
    }

    private func sendCommand(command: String, host: String, port: Int) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let udpError = sendUDP(message: normalized + "\n", host: host, port: port)
        let fileError = writeFallbackCommand(command: normalized)

        if udpError == nil || fileError == nil {
            return nil
        }

        return "\(udpError ?? "Unknown UDP error.") Fallback file command write failed: \(fileError ?? "Unknown file error.")"
    }

    private func writeFallbackCommand(command: String) -> String? {
        commandSequence &+= 1
        let payload = "\(commandSequence)|\(command)\n"

        do {
            try payload.write(to: fallbackFileURL, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
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

        let normalizedHost: String
        let lowered = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.isEmpty || lowered == "localhost" {
            normalizedHost = "127.0.0.1"
        } else {
            normalizedHost = lowered
        }

        let conversionResult = normalizedHost.withCString { cString in
            inet_pton(AF_INET, cString, &address.sin_addr)
        }
        guard conversionResult == 1 else {
            return "Governor bridge invalid host: \(host)."
        }

        let bytes = Array(message.utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        if sent < 0 {
            return "Governor bridge send error: \(String(cString: strerror(errno)))."
        }

        return nil
    }
}
