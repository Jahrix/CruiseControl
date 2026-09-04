import Foundation
import Darwin

struct GovernorBridgeSendResult {
    let sent: Bool
    let error: String?
    let statusText: String
    let ackState: GovernorAckState
    let ackMessage: String?
    let skipReason: String?
}

enum GovernorBridgeWriteError: LocalizedError, Equatable {
    case directWriteBlocked
    case invalidCapability
    case missingAcknowledgement
    case appliedValueMismatch
    case acknowledgementRequestMismatch
    case missingReadback
    case staleReadback
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .directWriteBlocked:
            return "Direct LOD commands are disabled; use the safe settings gateway."
        case .invalidCapability:
            return "The requested setting is not the verified LOD bridge capability."
        case .missingAcknowledgement:
            return "The bridge did not return a value-bearing LOD acknowledgement."
        case .appliedValueMismatch:
            return "The bridge acknowledgement did not match the requested LOD value."
        case .acknowledgementRequestMismatch:
            return "The bridge acknowledgement did not match this LOD request."
        case .missingReadback:
            return "The bridge did not publish an LOD readback for this request."
        case .staleReadback:
            return "The bridge LOD readback was not fresh."
        case .readbackMismatch:
            return "The bridge LOD readback did not match the requested value."
        }
    }
}

struct GovernorFileBridgeStatus {
    var enabled: Bool?
    var currentLOD: Double?
    var targetLOD: Double?
    /// Per-write nonce emitted only after the Lua bridge has read the dataref
    /// back following that specific SET_LOD command.
    var lastLODWriteID: String?
    var tier: String?
    var lodWriteSupported: Bool?
    var lodVerificationCandidate: Bool?
    var pluginSessionID: String?
    var simulatorBuild: String?
    var transactionState: String?
    /// Native bridge terminal-transaction identifiers. These make a status
    /// readback attributable to one request rather than merely recent.
    var lastNativeNonce: String?
    var lastNativeSequence: UInt64?
    // Optional read-only context keys emitted by a compatible companion bridge.
    // Missing keys are expected with older bridge scripts.
    var simulatorVersion: String?
    var aircraftIdentifier: String?
    var aircraftName: String?
    var nearestAirportICAO: String?
    var isOnGround: Bool?
    var lastUpdateDate: Date?
    var fileModifiedDate: Date?
    var rawText: String?
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
    private(set) var lastAckRequestID: String?
    private(set) var ackState: GovernorAckState = .noAck
    private(set) var usingFileFallback: Bool = false
    private(set) var lastFileBridgeWriteAt: Date?

    private var enabledCommandSent: Bool = false
    private var disableSent: Bool = false
    private var noAckCounter: Int = 0

    private var socketFD: Int32?
    private var currentSocketHost: String?
    private var currentSocketPort: Int?

    private let fileManager = FileManager.default

    deinit {
        if let fd = socketFD {
            Darwin.close(fd)
        }
    }

    static func bridgeFolderURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CruiseControl", isDirectory: true)
    }

    static func targetFileURL() -> URL {
        bridgeFolderURL().appendingPathComponent("lod_target.txt")
    }

    static func modeFileURL() -> URL {
        bridgeFolderURL().appendingPathComponent("lod_mode.txt")
    }

    static func statusFileURL() -> URL {
        bridgeFolderURL().appendingPathComponent("lod_status.txt")
    }

    @discardableResult
    func ensureBridgeFolderExists() -> URL {
        let folder = Self.bridgeFolderURL()
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func send(
        lod: Double,
        tier: GovernorTier,
        host: String,
        port: Int,
        now: Date,
        minimumInterval: TimeInterval,
        minimumDelta: Double
    ) -> GovernorBridgeSendResult {
        blockedDirectWriteResult(now: now)
    }

    func sendTestLOD(lod: Double, host: String, port: Int, now: Date) -> GovernorBridgeSendResult {
        blockedDirectWriteResult(now: now)
    }

    func sendPing(host: String, port: Int, now: Date) -> GovernorBridgeSendResult {
        sendCommand(command: "PING", host: host, port: port, expectAck: true)
    }

    func sendDisable(host: String, port: Int) -> String? {
        GovernorBridgeWriteError.directWriteBlocked.localizedDescription
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
            return "Connected (file bridge)"
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

    func readFileBridgeStatus() -> GovernorFileBridgeStatus? {
        // The companion may start before CruiseControl has sent a command.
        // Create the app-owned folder so its read-only status writer has a
        // stable, sandbox-compatible destination.
        _ = ensureBridgeFolderExists()
        let statusURL = Self.statusFileURL()
        guard fileManager.fileExists(atPath: statusURL.path) else {
            return nil
        }

        let content = try? String(contentsOf: statusURL, encoding: .utf8)
        let attributes = try? fileManager.attributesOfItem(atPath: statusURL.path)
        let modified = attributes?[.modificationDate] as? Date

        var map: [String: String] = [:]
        if let content {
            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty,
                      let separatorIndex = line.firstIndex(of: "=") else {
                    continue
                }

                let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                map[key] = value
            }
        }

        let epochValue = map["last_update_epoch"].flatMap(Double.init)
        let updateFromEpoch = epochValue.map { Date(timeIntervalSince1970: $0) }

        return GovernorFileBridgeStatus(
            enabled: map["enabled"].flatMap(parseBool),
            currentLOD: map["current_lod"].flatMap(Double.init),
            targetLOD: map["target_lod"].flatMap(Double.init),
            lastLODWriteID: map["last_lod_write_id"],
            tier: map["tier"],
            lodWriteSupported: map["lod_write_supported"].flatMap(parseBool),
            lodVerificationCandidate: map["lod_candidate"].flatMap(parseBool),
            pluginSessionID: map["plugin_session_id"],
            simulatorBuild: map["simulator_build"],
            transactionState: map["transaction_state"],
            lastNativeNonce: map["last_nonce"],
            lastNativeSequence: map["last_sequence"].flatMap(UInt64.init),
            simulatorVersion: map["simulator_version"] ?? map["xplane_version"],
            aircraftIdentifier: map["aircraft_identifier"] ?? map["aircraft_icao"],
            aircraftName: map["aircraft_name"],
            nearestAirportICAO: map["nearest_airport_icao"] ?? map["airport_icao"],
            isOnGround: map["on_ground"].flatMap(parseBool),
            lastUpdateDate: updateFromEpoch ?? modified,
            fileModifiedDate: modified,
            rawText: content?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Converts only bridge-reported state into the typed capability snapshot.
    /// A missing or older companion script never grants write permission.
    func readSafeSettingsRuntime() -> SafeSettingsRuntime {
        guard let status = readFileBridgeStatus() else {
            return .unavailable
        }

        let simulatorVersion: XPlaneSimulatorVersion
        switch status.simulatorVersion?.uppercased() {
        case "XP11": simulatorVersion = .xp11
        case "XP12": simulatorVersion = .xp12
        default: simulatorVersion = .unknown
        }

        var currentValues: [SafeSettingID: SafeSettingValue] = [:]
        if let currentLOD = status.currentLOD, currentLOD.isFinite {
            currentValues[.lodBias] = .number(currentLOD)
        }

        let evidenceDate = status.lastUpdateDate ?? status.fileModifiedDate
        let hasFreshReadback = evidenceDate.map { Date().timeIntervalSince($0) <= 5 } ?? false
        let writableSettings: Set<SafeSettingID> = status.lodWriteSupported == true &&
            status.currentLOD?.isFinite == true &&
            hasFreshReadback ? [.lodBias] : []
        return SafeSettingsRuntime(
            simulatorVersion: simulatorVersion,
            currentValues: currentValues,
            writableSettings: writableSettings,
            // Candidate discovery is useful evidence only after a native
            // bridge identifies the exact plugin session and simulator build.
            // Older/read-only bridge files cannot initiate verification.
            lodVerificationCandidate: status.lodVerificationCandidate == true &&
                status.currentLOD?.isFinite == true &&
                status.pluginSessionID?.isEmpty == false &&
                status.simulatorBuild?.isEmpty == false &&
                hasFreshReadback
        )
    }

    /// The sole LOD transport adapter. Its caller must already have passed
    /// SafeSettingsWriteGateway validation. A transport send alone is never
    /// considered successful: this requires a matching value-bearing ACK and
    /// a fresh, nonce-correlated dataref readback from the bridge.
    func writeVerifiedLOD(_ value: SafeSettingValue, host: String, port: Int, now: Date) throws {
        guard case let .number(lod) = value, lod.isFinite else {
            throw GovernorBridgeWriteError.invalidCapability
        }

        // A native XPLM bridge advertises a plugin session. Its protocol has
        // stronger transaction evidence than the legacy Lua bridge, so never
        // fall back to a legacy command when that bridge is present.
        if let status = readFileBridgeStatus(), status.pluginSessionID != nil {
            try writeVerifiedNativeLOD(lod, initialStatus: status, host: host, port: port, now: now)
            return
        }

        if !enabledCommandSent {
            let enable = sendCommand(command: "ENABLE", host: host, port: port, expectAck: true)
            guard enable.sent, enable.ackState == .ackOK else {
                throw GovernorBridgeWriteError.missingAcknowledgement
            }
            enabledCommandSent = true
            disableSent = false
        }

        let requestID = UUID().uuidString
        // An acknowledgement from a previous request can never verify this
        // write, even if it happens to contain the same LOD value.
        lastAckAppliedLOD = nil
        lastAckRequestID = nil
        let result = sendCommand(command: String(format: "SET_LOD %.3f %@", lod, requestID), host: host, port: port, expectAck: true)
        guard result.sent, result.ackState == .ackOK else {
            throw GovernorBridgeWriteError.missingAcknowledgement
        }
        guard let applied = lastAckAppliedLOD, abs(applied - lod) <= 0.01 else {
            throw GovernorBridgeWriteError.appliedValueMismatch
        }
        guard lastAckRequestID == requestID else {
            throw GovernorBridgeWriteError.acknowledgementRequestMismatch
        }
        guard let status = readFileBridgeStatus() else {
            throw GovernorBridgeWriteError.missingReadback
        }
        let readback = LODWriteReadback(
            currentLOD: status.currentLOD,
            requestID: status.lastLODWriteID,
            observedAt: status.lastUpdateDate ?? status.fileModifiedDate
        )
        if let failure = LODWriteVerification.failure(
            requestedLOD: lod,
            requestID: requestID,
            readback: readback,
            now: now
        ) {
            throw GovernorBridgeWriteError(failure)
        }

        lastSentLOD = lod
        lastSentAt = now
        lastSuccessfulSendAt = now
        lastError = nil
    }

    /// Called only by GovernorSafeSettingsWriter after SafeSettingsWriteGateway
    /// has authorized the explicit verification capability.
    func verifyNativeLOD(host: String, port: Int, now: Date) throws {
        guard let status = readFileBridgeStatus(),
              status.lodVerificationCandidate == true,
              let session = status.pluginSessionID,
              let evidenceDate = status.lastUpdateDate ?? status.fileModifiedDate,
              now.timeIntervalSince(evidenceDate) >= 0,
              now.timeIntervalSince(evidenceDate) <= 5 else {
            throw GovernorBridgeWriteError.invalidCapability
        }
        let controller = UUID().uuidString, nonce = UUID().uuidString
        let sequence = UInt64(now.timeIntervalSince1970 * 1_000)
        clearNativeResult()
        let result = sendCommand(command: "CCLOD/1 VERIFY \(controller) \(nonce) \(sequence)", host: host, port: port, expectAck: true)
        guard result.sent, result.ackState == .ackOK,
              nativeResultMatches(session: session, nonce: nonce, sequence: sequence, result: "VERIFIED"),
              let updated = readFileBridgeStatus(),
              updated.pluginSessionID == session,
              updated.lastNativeNonce == nonce,
              updated.lastNativeSequence == sequence,
              updated.lodWriteSupported == true,
              let updatedDate = updated.lastUpdateDate ?? updated.fileModifiedDate,
              now.timeIntervalSince(updatedDate) >= 0,
              now.timeIntervalSince(updatedDate) <= 5 else {
            throw GovernorBridgeWriteError.missingAcknowledgement
        }
        nativeControllerLease = controller
        nativeControllerSessionID = session
    }

    private func writeVerifiedNativeLOD(
        _ lod: Double,
        initialStatus: GovernorFileBridgeStatus,
        host: String,
        port: Int,
        now: Date
    ) throws {
        guard initialStatus.lodWriteSupported == true,
              let session = initialStatus.pluginSessionID,
              let controller = nativeControllerLease,
              nativeControllerSessionID == session,
              let evidenceDate = initialStatus.lastUpdateDate ?? initialStatus.fileModifiedDate,
              now.timeIntervalSince(evidenceDate) >= 0,
              now.timeIntervalSince(evidenceDate) <= 5 else {
            throw GovernorBridgeWriteError.invalidCapability
        }
        let nonce = UUID().uuidString
        let sequence = UInt64(now.timeIntervalSince1970 * 1_000)
        clearNativeResult()
        let result = sendCommand(
            command: String(format: "CCLOD/1 SET %@ %@ %llu %.3f", controller, nonce, sequence, lod),
            host: host,
            port: port,
            expectAck: true
        )
        guard result.sent, result.ackState == .ackOK,
              nativeResultMatches(session: session, nonce: nonce, sequence: sequence, result: "APPLIED"),
              let updated = readFileBridgeStatus(),
              updated.pluginSessionID == session,
              updated.lastNativeNonce == nonce,
              updated.lastNativeSequence == sequence,
              let observed = updated.currentLOD,
              abs(observed - lod) <= 0.01,
              let updatedDate = updated.lastUpdateDate ?? updated.fileModifiedDate,
              now.timeIntervalSince(updatedDate) >= 0,
              now.timeIntervalSince(updatedDate) <= 5 else {
            throw GovernorBridgeWriteError.missingAcknowledgement
        }
        lastSentLOD = lod
        lastSentAt = now
        lastSuccessfulSendAt = now
        lastError = nil
    }

    private var lastNativeResultSessionID: String?
    private var lastNativeResultNonce: String?
    private var lastNativeResultSequence: UInt64?
    private var lastNativeResultState: String?
    private var nativeControllerLease: String?
    private var nativeControllerSessionID: String?

    private func clearNativeResult() {
        lastNativeResultSessionID = nil
        lastNativeResultNonce = nil
        lastNativeResultSequence = nil
        lastNativeResultState = nil
    }

    private func nativeResultMatches(session: String, nonce: String, sequence: UInt64, result: String) -> Bool {
        lastNativeResultSessionID == session &&
        lastNativeResultNonce == nonce &&
        lastNativeResultSequence == sequence &&
        lastNativeResultState == result
    }

    private func blockedDirectWriteResult(now: Date) -> GovernorBridgeSendResult {
        let error = GovernorBridgeWriteError.directWriteBlocked.localizedDescription
        lastError = error
        ackState = .paused
        return GovernorBridgeSendResult(
            sent: false,
            error: error,
            statusText: GovernorAckState.paused.displayName,
            ackState: .paused,
            ackMessage: nil,
            skipReason: "Direct governor write blocked"
        )
    }

    private func sendCommand(command: String, host: String, port: Int, expectAck: Bool) -> GovernorBridgeSendResult {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        lastCommand = normalized
        lastCommandAt = now

        let udpResult = sendUDP(message: normalized + "\n", host: host, port: port, waitForResponse: expectAck)
        
        var fallbackError: String? = nil
        let udpFailed = udpResult.sendError != nil
        // A file write cannot provide a request-correlated ACK or a fresh
        // readback. Never use it for a setting mutation.
        if udpFailed, normalized.uppercased() != "PING" {
            ackState = .noAck
            usingFileFallback = false
            noAckCounter += 1
            let message = udpResult.sendError ?? "The UDP bridge is unavailable."
            lastError = message
            return GovernorBridgeSendResult(
                sent: false,
                error: message,
                statusText: commandStatusText(now: now),
                ackState: ackState,
                ackMessage: nil,
                skipReason: "File fallback is disabled for LOD writes"
            )
        }
        
        if udpFailed {
            fallbackError = writeFallbackCommand(command: normalized, now: now)
        }
        
        let usingFallbackThisCommand = udpFailed && fallbackError == nil

        let sent = udpResult.sendError == nil || fallbackError == nil

        if let sendError = udpResult.sendError, fallbackError != nil {
            ackState = .noAck
            usingFileFallback = false
            noAckCounter += 1
            let message = "\(sendError) File bridge write failed: \(fallbackError ?? "unknown")"
            lastError = message
            return GovernorBridgeSendResult(
                sent: false,
                error: message,
                statusText: commandStatusText(now: now),
                ackState: ackState,
                ackMessage: nil,
                skipReason: nil
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
                lastAckMessage = "No ACK (file bridge)"
                lastAckAt = nil
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
            ackMessage: lastAckMessage,
            skipReason: nil
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
                if components.count == 4,
                   let valueString = components.dropFirst(2).first,
                   let value = Double(valueString) {
                    lastAckAppliedLOD = value
                    lastAckRequestID = String(components[3])
                }
            }
            return
        }

        if trimmed.uppercased().hasPrefix("CCLOD/1 RESULT") {
            let components = trimmed.split(separator: " ")
            // CCLOD/1 RESULT <session> <nonce> <sequence> <result>
            //                 <requested> <observed> <state>
            guard components.count == 9,
                  let sequence = UInt64(components[4]) else {
                ackState = .noAck
                return
            }
            lastNativeResultSessionID = String(components[2])
            lastNativeResultNonce = String(components[3])
            lastNativeResultSequence = sequence
            lastNativeResultState = String(components[5]).uppercased()
            ackState = ["VERIFIED", "APPLIED"].contains(lastNativeResultState ?? "") ? .ackOK : .noAck
            return
        }

        ackState = .connected
    }

    private func writeFallbackCommand(command: String, now: Date) -> String? {
        let folder = ensureBridgeFolderExists()
        let modeURL = folder.appendingPathComponent("lod_mode.txt")

        let upper = command.uppercased()
        guard upper == "PING" else {
            return "File fallback is unavailable for setting commands."
        }

        do {
            let payload = "PING=\(Int(now.timeIntervalSince1970))\n"
            try payload.write(to: modeURL, atomically: true, encoding: .utf8)

            lastFileBridgeWriteAt = now
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func sendUDP(message: String, host: String, port: Int, waitForResponse: Bool) -> (sendError: String?, response: String?) {
        if socketFD != nil && (currentSocketHost != host || currentSocketPort != port) {
            if let fd = socketFD {
                Darwin.close(fd)
                socketFD = nil
            }
        }

        let fd: Int32
        if let existingFD = socketFD {
            fd = existingFD
        } else {
            let newFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard newFD >= 0 else {
                return ("Regulator bridge failed to create UDP socket.", nil)
            }
            
            var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
            _ = withUnsafePointer(to: &timeout) { pointer in
                setsockopt(newFD, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }
            
            socketFD = newFD
            currentSocketHost = host
            currentSocketPort = port
            fd = newFD
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
            return ("Regulator bridge invalid host: \(host).", nil)
        }

        let bytes = Array(message.utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        if sent < 0 {
            let code = errno
            Darwin.close(fd)
            socketFD = nil
            return ("Regulator bridge send error: \(String(cString: strerror(code))).", nil)
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

        return ("Regulator bridge receive error: \(String(cString: strerror(code))).", nil)
    }

    private func parseBool(_ raw: String) -> Bool? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "1" || normalized == "true" || normalized == "yes" {
            return true
        }
        if normalized == "0" || normalized == "false" || normalized == "no" {
            return false
        }
        return nil
    }
}

private extension GovernorBridgeWriteError {
    init(_ failure: LODWriteVerificationFailure) {
        switch failure {
        case .missingReadback: self = .missingReadback
        case .staleReadback: self = .staleReadback
        case .readbackMismatch: self = .readbackMismatch
        }
    }
}

struct GovernorSafeSettingsWriter: SafeSettingsWriter {
    let bridge: GovernorCommandBridge
    let host: String
    let port: Int
    let now: Date

    func write(_ value: SafeSettingValue, for capability: SafeSettingsCapability) throws {
        switch (capability.id, capability.writeMechanism, value) {
        case (.lodBias, .bridgeCommand("SET_LOD"), _): try bridge.writeVerifiedLOD(value, host: host, port: port, now: now)
        case (.lodVerification, .bridgeCommand("VERIFY_LOD"), .choice("verify")): try bridge.verifyNativeLOD(host: host, port: port, now: now)
        default: throw GovernorBridgeWriteError.invalidCapability
        }
    }
}
