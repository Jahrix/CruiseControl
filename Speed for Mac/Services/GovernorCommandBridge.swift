import Foundation
import Darwin

struct GovernorBridgeSendResult {
    let sent: Bool
    let error: String?
    let statusText: String
    let ackState: GovernorAckState
    let ackMessage: String?
}

final class GovernorCommandBridge {
    private(set) var lastSentTier: GovernorTier?
    private(set) var lastSentLOD: Double?
    private(set) var lastSentAt: Date?
    private(set) var lastSuccessfulSendAt: Date?
    private(set) var lastError: String?

    private(set) var lastCommand: String?
    private(set) var lastCommandAt: Date?
    private(set) var lastAckMessage: String?
    private(set) var lastAckAt: Date?
    private(set) var lastAckAppliedLOD: Double?
    private(set) var ackState: GovernorAckState = .noAck
    private(set) var usingFileFallback: Bool = false

    private var enabledCommandSent: Bool = false
    private var disableSent: Bool = false
    private var commandSequence: UInt64 = 0
    private var noAckCounter: Int = 0

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
            let enableResult = sendCommand(command: "ENABLE", host: host, port: port, expectAck: true)
            if !enableResult.sent {
                return enableResult
            }
            enabledCommandSent = true
            disableSent = false
        }

        if let lastSentAt,
           now.timeIntervalSince(lastSentAt) < max(minimumInterval, 0.1) {
            return GovernorBridgeSendResult(
                sent: false,
                error: nil,
                statusText: commandStatusText(now: now),
                ackState: ackState,
                ackMessage: lastAckMessage
            )
        }

        if let lastSentLOD,
           abs(lastSentLOD - lod) < max(minimumDelta, 0.005) {
            return GovernorBridgeSendResult(
                sent: false,
                error: nil,
                statusText: commandStatusText(now: now),
                ackState: ackState,
                ackMessage: lastAckMessage
            )
        }

        let command = String(format: "SET_LOD %.3f", lod)
        let result = sendCommand(command: command, host: host, port: port, expectAck: true)
        if !result.sent {
            return result
        }

        lastSentTier = tier
        lastSentLOD = lod
        lastSentAt = now
        lastSuccessfulSendAt = now
        lastError = nil
        disableSent = false

        return result
    }

    func sendTestLOD(lod: Double, host: String, port: Int, now: Date) -> GovernorBridgeSendResult {
        if !enabledCommandSent {
            let enableResult = sendCommand(command: "ENABLE", host: host, port: port, expectAck: true)
            if !enableResult.sent {
                return enableResult
            }
            enabledCommandSent = true
            disableSent = false
        }

        let command = String(format: "SET_LOD %.3f", lod)
        let result = sendCommand(command: command, host: host, port: port, expectAck: true)
        if !result.sent {
            return result
        }

        lastSentLOD = lod
        lastSentAt = now
        lastSuccessfulSendAt = now
        lastError = nil

        return result
    }

    func sendPing(host: String, port: Int, now: Date) -> GovernorBridgeSendResult {
        sendCommand(command: "PING", host: host, port: port, expectAck: true)
    }

    func sendDisable(host: String, port: Int) -> String? {
        guard !disableSent else { return nil }

        let result = sendCommand(command: "DISABLE", host: host, port: port, expectAck: true)
        if result.sent {
            disableSent = true
            enabledCommandSent = false
            lastSentTier = nil
            lastSentLOD = nil
            lastSentAt = Date()
            lastError = nil
            ackState = .disabled
            usingFileFallback = false
        } else {
            lastError = result.error
        }

        return result.error
    }

    func setPausedState() {
        ackState = .paused
    }

    func setDisabledState() {
        ackState = .disabled
        usingFileFallback = false
    }

    func commandStatusText(now: Date) -> String {
        if usingFileFallback, ackState != .disabled, ackState != .paused {
            return "Connected (file fallback)"
        }

        switch ackState {
        case .disabled:
            return GovernorAckState.disabled.displayName
        case .paused:
            return GovernorAckState.paused.displayName
        case .ackOK:
            return GovernorAckState.ackOK.displayName
        case .connected:
            return GovernorAckState.connected.displayName
        case .noAck:
            if let lastAckAt, now.timeIntervalSince(lastAckAt) < 20 {
                return GovernorAckState.connected.displayName
            }
            return GovernorAckState.noAck.displayName
        }
    }

    private func sendCommand(command: String, host: String, port: Int, expectAck: Bool) -> GovernorBridgeSendResult {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        lastCommand = normalized
        lastCommandAt = now

        let fallbackError = writeFallbackCommand(command: normalized)
        let udpResult = sendUDP(message: normalized + "\n", host: host, port: port, waitForResponse: expectAck)
        let usingFallbackThisCommand = udpResult.sendError != nil && fallbackError == nil

        var sent = false
        if udpResult.sendError == nil || fallbackError == nil {
            sent = true
        }

        if let sendError = udpResult.sendError, fallbackError != nil {
            ackState = .noAck
            usingFileFallback = false
            noAckCounter += 1
            let message = "\(sendError) Fallback file write failed: \(fallbackError ?? "unknown")"
            lastError = message
            return GovernorBridgeSendResult(
                sent: false,
                error: message,
                statusText: commandStatusText(now: now),
                ackState: ackState,
                ackMessage: nil
            )
        }

        if let response = udpResult.response {
            usingFileFallback = false
            handleAck(response: response, now: now)
        } else if expectAck {
            if usingFallbackThisCommand {
                usingFileFallback = true
                ackState = .connected
                noAckCounter = 0
                lastAckMessage = "Fallback transport active (ACK unavailable)"
                lastAckAt = now
            } else {
                noAckCounter += 1
                if noAckCounter >= 2 {
                    ackState = .noAck
                } else {
                    ackState = .connected
                }
            }
        } else {
            ackState = .connected
        }

        if usingFallbackThisCommand {
            lastError = nil
            lastSuccessfulSendAt = now
        } else if let sendError = udpResult.sendError {
            lastError = sendError
        } else {
            lastError = nil
            lastSuccessfulSendAt = now
        }

        let errorText: String?
        if usingFallbackThisCommand {
            errorText = nil
        } else if expectAck, udpResult.sendError == nil, udpResult.response == nil {
            errorText = "No ACK received from Lua bridge."
        } else {
            errorText = udpResult.sendError
        }

        return GovernorBridgeSendResult(
            sent: sent,
            error: errorText,
            statusText: commandStatusText(now: now),
            ackState: ackState,
            ackMessage: lastAckMessage
        )
    }

    private func handleAck(response: String, now: Date) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        lastAckMessage = trimmed
        lastAckAt = now

        if trimmed.uppercased().hasPrefix("ERR") {
            ackState = .noAck
            lastError = trimmed
            noAckCounter += 1
            return
        }

        if trimmed.uppercased().hasPrefix("ACK") || trimmed.uppercased().hasPrefix("PONG") {
            ackState = .ackOK
            noAckCounter = 0
            lastError = nil

            if trimmed.uppercased().hasPrefix("ACK SET_LOD") {
                let components = trimmed.split(separator: " ")
                if let valueString = components.last,
                   let value = Double(valueString) {
                    lastAckAppliedLOD = value
                }
            }
            return
        }

        ackState = .connected
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

    private func sendUDP(message: String, host: String, port: Int, waitForResponse: Bool) -> (sendError: String?, response: String?) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return ("Governor bridge failed to create UDP socket.", nil)
        }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

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
            return ("Governor bridge invalid host: \(host).", nil)
        }

        let bytes = Array(message.utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        if sent < 0 {
            let code = errno
            return ("Governor bridge send error: \(String(cString: strerror(code))).", nil)
        }

        guard waitForResponse else {
            return (nil, nil)
        }

        var buffer = [UInt8](repeating: 0, count: 512)
        let readCount = recv(fd, &buffer, buffer.count, 0)

        if readCount > 0 {
            let data = Data(buffer.prefix(Int(readCount)))
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text)
        }

        if readCount == 0 {
            return (nil, nil)
        }

        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK {
            return (nil, nil)
        }

        return ("Governor bridge receive error: \(String(cString: strerror(code))).", nil)
    }
}
