import Foundation
import Darwin

final class XPlaneUDPReceiver {
    // A DATA datagram may contain many 36-byte X-Plane records. Keep the full
    // UDP payload so a valid packet is not mistaken for a truncated record.
    private static let maximumDatagramSize = 65_535
    private static let xPlaneHeaderByteCount = 5
    private static let xPlaneRecordByteCount = 36
    private static let rejectedPacketDiagnosticIntervalNanoseconds: UInt64 = 5_000_000_000

    private struct SocketError: Error {
        let op: String
        let code: Int32
        let message: String
    }

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    private var listenHost: String = "127.0.0.1"
    private var listenPort: Int = 49_005
    private var effectiveListenHost: String = "127.0.0.1"
    private var effectiveListenPort: Int = 49_005
    private var listeningEnabled: Bool = true

    private var totalPackets: UInt64 = 0
    private var invalidPackets: UInt64 = 0
    private var datasetMismatchPackets: UInt64 = 0

    private var packetsInWindow: UInt64 = 0
    private var packetsPerSecond: Double = 0
    private var lastWindowDate: Date?

    private var lastPacketDate: Date?
    private var lastValidPacketDate: Date?
    private var lastPacketUptimeNanoseconds: UInt64?
    private var lastValidPacketUptimeNanoseconds: UInt64?
    private var latestTelemetry: SimTelemetrySnapshot?
    private var pendingTelemetry: [SimTelemetrySnapshot] = []
    private let pendingTelemetryCapacity = 2_048
    private var droppedSamples: UInt64 = 0
    private var lastDetail: String?
    private var lastRejectedPacketDiagnosticUptimeNanoseconds: UInt64?
    private let parser: TelemetryParsing

    init(parser: TelemetryParsing = XPlaneTelemetryParser()) {
        self.parser = parser
    }

    func configure(enabled: Bool, host: String = "127.0.0.1", port: Int, queue: DispatchQueue) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedPort = min(max(port, 1_024), 65_535)
        let previousNormalizedHost = normalizedListenHost(from: listenHost)
        let normalizedHost = normalizedListenHost(from: trimmedHost)

        let endpointChanged =
            normalizedHost != previousNormalizedHost ||
            clampedPort != listenPort

        listenHost = trimmedHost
        listenPort = clampedPort
        effectiveListenHost = listenAddressLabel(for: listenHost)
        effectiveListenPort = listenPort
        listeningEnabled = enabled

        guard enabled else {
            stop(resetState: true)
            return
        }

        if socketFD >= 0 {
            if endpointChanged {
                stop(resetState: true)
                startListening(queue: queue)
            }
            return
        }

        resetPacketStats()
        startListening(queue: queue)
    }

    func stop(resetState: Bool = false) {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }

        readSource?.cancel()
        readSource = nil

        if resetState {
            resetPacketStats()
            lastDetail = listeningEnabled ? nil : "UDP listening is disabled."
        }
    }

    private func resetPacketStats() {
        totalPackets = 0
        invalidPackets = 0
        datasetMismatchPackets = 0
        packetsInWindow = 0
        packetsPerSecond = 0
        lastWindowDate = nil
        lastPacketDate = nil
        lastValidPacketDate = nil
        lastPacketUptimeNanoseconds = nil
        lastValidPacketUptimeNanoseconds = nil
        latestTelemetry = nil
        pendingTelemetry.removeAll(keepingCapacity: true)
        droppedSamples = 0
        lastRejectedPacketDiagnosticUptimeNanoseconds = nil
    }

    func drainTelemetry() -> [SimTelemetrySnapshot] {
        let drained = pendingTelemetry
        pendingTelemetry.removeAll(keepingCapacity: true)
        return drained
    }
    func snapshot(
        now: Date,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> (telemetry: SimTelemetrySnapshot?, status: XPlaneUDPStatus) {
        if let lastWindowDate {
            let elapsed = now.timeIntervalSince(lastWindowDate)
            if elapsed >= 1 {
                packetsPerSecond = Double(packetsInWindow) / elapsed
                packetsInWindow = 0
                self.lastWindowDate = now
            }
        } else {
            lastWindowDate = now
        }

        let state: XPlaneUDPConnectionState
        let detail: String

        let issue: XPlaneUDPConnectionIssue?
        if !listeningEnabled {
            state = .idle
            detail = "UDP listening is disabled."
            issue = .disabled
        } else if socketFD < 0 {
            state = .misconfig
            detail = lastDetail ?? "Could not bind UDP listener. Check port availability and permissions."
            if detail.localizedCaseInsensitiveContains("already in use") {
                issue = .portConflict
            } else if detail.localizedCaseInsensitiveContains("permission") {
                issue = .permissionDenied
            } else {
                issue = .malformedOrUnsupported
            }
        } else if let lastValidUptime = lastValidPacketUptimeNanoseconds,
                  monotonicAge(now: monotonicNanoseconds, then: lastValidUptime) <= 4 {
            state = .active
            if latestTelemetry?.cpuFrameTimeMS == nil || latestTelemetry?.gpuFrameTimeMS == nil {
                detail = "Frame-rate packets are flowing, but CPU/GPU timing fields are unavailable."
                issue = .missingRequiredFields
            } else {
                detail = "Frame-rate, CPU, and GPU timing packets are flowing."
                issue = nil
            }
        } else if totalPackets == 0 {
            state = .listening
            detail = "No UDP packets received. Confirm Data Output IP/port match."
            issue = .awaitingPackets
        } else if lastValidPacketDate == nil {
            state = .misconfig
            detail = lastDetail ?? "Packets received but format/index mismatch."
            issue = datasetMismatchPackets > 0 ? .missingRequiredFields : .malformedOrUnsupported
        } else {
            state = .listening
            detail = "Telemetry stopped after a valid connection. Check whether X-Plane paused, closed, or changed Data Output."
            issue = .connectionLost
        }

        let status = XPlaneUDPStatus(
            state: state,
            listenHost: effectiveListenHost,
            listenPort: effectiveListenPort,
            lastPacketDate: lastPacketDate,
            lastValidPacketDate: lastValidPacketDate,
            packetsPerSecond: packetsPerSecond,
            totalPackets: totalPackets,
            invalidPackets: invalidPackets,
            droppedSamples: droppedSamples,
            issue: issue,
            detail: detail
        )

        let telemetry: SimTelemetrySnapshot?
        if let latestTelemetry,
           let lastValidUptime = lastValidPacketUptimeNanoseconds,
           monotonicAge(now: monotonicNanoseconds, then: lastValidUptime) <= 5 {
            telemetry = latestTelemetry
        } else {
            telemetry = nil
        }

        return (telemetry, status)
    }

    private func startListening(queue: DispatchQueue) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let code = errno
            let error = makeSocketError(op: "socket", code: code)
            lastDetail = error.message
            return
        }

        var reuseAddress: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            let code = errno
            let error = makeSocketError(op: "setsockopt", code: code)
            lastDetail = error.message
            Darwin.close(fd)
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            let code = errno
            let error = makeSocketError(op: "fcntl(F_GETFL)", code: code)
            lastDetail = error.message
            Darwin.close(fd)
            return
        }

        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 {
            let code = errno
            let error = makeSocketError(op: "fcntl(F_SETFL)", code: code)
            lastDetail = error.message
            Darwin.close(fd)
            return
        }

        let normalizedHost = normalizedListenHost(from: listenHost)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(listenPort).bigEndian)

        if normalizedHost == "0.0.0.0" {
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else {
            var ipv4 = in_addr()
            let parseResult = normalizedHost.withCString { cString in
                inet_pton(AF_INET, cString, &ipv4)
            }

            guard parseResult == 1 else {
                lastDetail = "Invalid listen address '\(listenHost)'. Use 127.0.0.1 or 0.0.0.0."
                Darwin.close(fd)
                return
            }

            addr.sin_addr = ipv4
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else {
            let code = errno
            let error = makeSocketError(
                op: "bind",
                code: code,
                addressLabel: listenAddressLabel(for: normalizedHost),
                port: listenPort
            )
            lastDetail = error.message
            Darwin.close(fd)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readPackets()
        }
        source.setCancelHandler { }
        source.resume()

        socketFD = fd
        readSource = source
        effectiveListenHost = listenAddressLabel(for: normalizedHost)
        effectiveListenPort = listenPort
        lastDetail = nil
    }

    private func readPackets() {
        guard socketFD >= 0 else { return }

        let now = Date()
        if lastWindowDate == nil {
            lastWindowDate = now
        }

        var processedPackets = 0
        var buffer = [UInt8](repeating: 0, count: Self.maximumDatagramSize)
        while processedPackets < 256 {
            let readCount = recv(socketFD, &buffer, buffer.count, 0)

            if readCount > 0 {
                processedPackets += 1
                let packetNow = Date()
                let packetUptime = DispatchTime.now().uptimeNanoseconds
                totalPackets += 1
                packetsInWindow += 1
                lastPacketDate = packetNow
                lastPacketUptimeNanoseconds = packetUptime

                let parseResult = parse(
                    packet: Data(buffer.prefix(Int(readCount))),
                    now: packetNow,
                    monotonicNanoseconds: packetUptime
                )
                if parseResult.valid {
                    if let telemetry = parseResult.telemetry {
                        latestTelemetry = telemetry
                        pendingTelemetry.append(telemetry)
                        if pendingTelemetry.count > pendingTelemetryCapacity {
                            let overflow = pendingTelemetry.count - pendingTelemetryCapacity
                            pendingTelemetry.removeFirst(overflow)
                            droppedSamples += UInt64(overflow)
                        }
                    }
                    lastValidPacketDate = packetNow
                    lastValidPacketUptimeNanoseconds = packetUptime
                } else {
                    invalidPackets += 1
                    lastDetail = parseResult.detail
                }
                continue
            }

            if readCount == 0 {
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            let code = errno
            let error = makeSocketError(op: "recv", code: code)
            lastDetail = error.message
            break
        }
    }

    private func parse(
        packet: Data,
        now: Date,
        monotonicNanoseconds: UInt64
    ) -> (valid: Bool, telemetry: SimTelemetrySnapshot?, detail: String?) {
        let parsed: ParsedXPlaneTelemetry
        switch parser.parse(packet) {
        case .success(let telemetry):
            parsed = telemetry
        case .failure(let error):
            logRejectedPacketIfNeeded(packet: packet, error: error, monotonicNanoseconds: monotonicNanoseconds)
            if error == .missingFrameRateDataSet {
                datasetMismatchPackets += 1
                return (false, nil, "X-Plane packets are arriving, but Data Set 0 (frame rate) is not enabled.")
            }
            return (false, nil, parseErrorDetail(error))
        }

        var offset = 5
        let recordSize = 36
        var records: [Int32: [Float]] = [:]

        while offset + recordSize <= packet.count {
            let index = Int32(bitPattern: readUInt32LE(packet, offset: offset))
            var values: [Float] = []
            values.reserveCapacity(8)

            for valueIndex in 0..<8 {
                let valueOffset = offset + 4 + (valueIndex * 4)
                let raw = readUInt32LE(packet, offset: valueOffset)
                values.append(Float(bitPattern: raw))
            }

            records[index] = values
            offset += recordSize
        }

        let altitude = readAltitude(records: records)

        let telemetry = SimTelemetrySnapshot(
            source: "X-Plane UDP Data Output",
            fps: parsed.fps,
            frameTimeMS: parsed.frameTimeMilliseconds,
            cpuFrameTimeMS: parsed.simulatorCPUTimeMilliseconds,
            gpuFrameTimeMS: parsed.gpuTimeMilliseconds,
            altitudeAGLFeet: altitude.aglFeet,
            altitudeMSLFeet: altitude.mslFeet,
            nearestAirportICAO: nil,
            lastPacketDate: now,
            receivedUptimeNanoseconds: monotonicNanoseconds
        )

        return (true, telemetry, nil)
    }

    private func logRejectedPacketIfNeeded(
        packet: Data,
        error: TelemetryParseError,
        monotonicNanoseconds: UInt64
    ) {
#if DEBUG
        if let lastDiagnostic = lastRejectedPacketDiagnosticUptimeNanoseconds,
           monotonicNanoseconds >= lastDiagnostic,
           monotonicNanoseconds - lastDiagnostic < Self.rejectedPacketDiagnosticIntervalNanoseconds {
            return
        }
        lastRejectedPacketDiagnosticUptimeNanoseconds = monotonicNanoseconds

        let prefix = Array(packet.prefix(16))
        let detectedHeader = Array(packet.prefix(Self.xPlaneHeaderByteCount))
        let payloadLength = max(packet.count - Self.xPlaneHeaderByteCount, 0)
        let hasCompleteRecordLayout =
            payloadLength >= Self.xPlaneRecordByteCount &&
            payloadLength.isMultiple(of: Self.xPlaneRecordByteCount)
        let recordIndices = recordIndices(in: packet)

        NSLog("%@", """
        [XPlaneUDPReceiver] Rejected telemetry packet (rate-limited to one every 5 seconds)
          exact validation: \(validationDescription(for: error))
          datagram bytes: \(packet.count)
          first 16 bytes hex: \(hexString(prefix))
          first 16 bytes ASCII: \(printableASCII(prefix))
          detected header (first \(Self.xPlaneHeaderByteCount) bytes): hex=\(hexString(detectedHeader)) ASCII=\(printableASCII(detectedHeader))
          payload length after \(Self.xPlaneHeaderByteCount)-byte header: \(payloadLength)
          payload satisfies \(Self.xPlaneRecordByteCount)-byte record layout: \(hasCompleteRecordLayout)
          record indices encountered: \(recordIndices.map(String.init).joined(separator: ", ").isEmpty ? "none" : recordIndices.map(String.init).joined(separator: ", "))
        """)
#endif
    }

    private func recordIndices(in packet: Data) -> [Int32] {
        guard packet.count >= Self.xPlaneHeaderByteCount else { return [] }

        var indices: [Int32] = []
        var offset = Self.xPlaneHeaderByteCount
        while offset + Self.xPlaneRecordByteCount <= packet.count {
            indices.append(Int32(bitPattern: readUInt32LE(packet, offset: offset)))
            offset += Self.xPlaneRecordByteCount
        }
        return indices
    }

    private func validationDescription(for error: TelemetryParseError) -> String {
        switch error {
        case .tooShort(let actualBytes):
            return "tooShort: packet has \(actualBytes) bytes; parser requires the 5-byte DATA header plus one 36-byte record."
        case .unsupportedHeader:
            return "unsupportedHeader: first 4 bytes are not exactly DATA (44 41 54 41)."
        case .truncatedRecord(let trailingBytes):
            return "truncatedRecord: bytes after the 5-byte header are not divisible by 36; \(trailingBytes) trailing byte(s)."
        case .missingFrameRateDataSet:
            return "missingFrameRateDataSet: record layout is valid, but no complete record has index 0."
        case .invalidFPS:
            return "invalidFPS: Data Set 0 value[0] is non-finite or outside the accepted 1...500 FPS range."
        }
    }

    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func printableASCII(_ bytes: [UInt8]) -> String {
        String(bytes.map { byte in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        })
    }

    private func parseErrorDetail(_ error: TelemetryParseError) -> String {
        switch error {
        case .tooShort:
            return "Received a truncated UDP packet; it is not a complete X-Plane DATA record."
        case .unsupportedHeader:
            return "Packets are arriving on this port, but they are not X-Plane DATA packets."
        case .truncatedRecord:
            return "Received a malformed X-Plane DATA packet with an incomplete record."
        case .missingFrameRateDataSet:
            return "Data Set 0 (frame rate) is not enabled."
        case .invalidFPS:
            return "Data Set 0 arrived with an invalid or impossible FPS value."
        }
    }

    private func monotonicAge(now: UInt64, then: UInt64) -> TimeInterval {
        guard now >= then else { return 0 }
        return Double(now - then) / 1_000_000_000
    }

    private func readAltitude(records: [Int32: [Float]]) -> (aglFeet: Double?, mslFeet: Double?) {
        // Data Set 20 is the cross-version X-Plane position output row (XP11/XP12).
        guard let positionRecord = records[20], positionRecord.count >= 3 else {
            return (nil, nil)
        }

        let msl = normalizeAltitude(Double(positionRecord[2]), min: -1_500, max: 80_000)
        let agl: Double?
        if positionRecord.count >= 4 {
            agl = normalizeAltitude(Double(positionRecord[3]), min: -200, max: 50_000)
        } else {
            agl = nil
        }

        return (agl, msl)
    }

    private func normalizeAltitude(_ candidate: Double, min: Double, max: Double) -> Double? {
        guard candidate.isFinite, candidate >= min, candidate <= max else { return nil }
        return candidate
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private func normalizedListenHost(from host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.isEmpty || lowered == "localhost" {
            return "127.0.0.1"
        }
        if lowered == "0.0.0.0" || lowered == "*" || lowered == "all" || lowered == "any" {
            return "0.0.0.0"
        }
        return trimmed
    }

    private func listenAddressLabel(for host: String) -> String {
        let normalized = normalizedListenHost(from: host)
        if normalized == "0.0.0.0" {
            return "0.0.0.0 (all interfaces)"
        }
        return normalized
    }

    private func makeSocketError(
        op: String,
        code: Int32? = nil,
        addressLabel: String? = nil,
        port: Int? = nil
    ) -> SocketError {
        let errorCode = code ?? errno
        let errorText = String(cString: strerror(errorCode))
        let endpoint = "\(addressLabel ?? listenAddressLabel(for: listenHost)):\(port ?? listenPort)"

        let message: String
        switch errorCode {
        case EADDRINUSE:
            message = "Port \(port ?? listenPort) is already in use."
        case EACCES, EPERM:
            message = "Permission denied binding to \(endpoint). App Sandbox needs Incoming Network Connections enabled."
        case EADDRNOTAVAIL:
            message = "Address \(addressLabel ?? listenAddressLabel(for: listenHost)) is not available on this Mac."
        case ENETDOWN, ENETUNREACH:
            message = "Network unavailable."
        default:
            message = "\(op) failed (errno \(errorCode): \(errorText))."
        }

        return SocketError(op: op, code: errorCode, message: message)
    }
}
