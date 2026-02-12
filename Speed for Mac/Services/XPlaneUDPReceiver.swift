import Foundation
import Darwin

final class XPlaneUDPReceiver {
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    private var listenHost: String = "127.0.0.1"
    private var listenPort: Int = 49_005
    private var listeningEnabled: Bool = true

    private var totalPackets: UInt64 = 0
    private var invalidPackets: UInt64 = 0
    private var datasetMismatchPackets: UInt64 = 0

    private var packetsInWindow: UInt64 = 0
    private var packetsPerSecond: Double = 0
    private var lastWindowDate: Date?

    private var lastPacketDate: Date?
    private var lastValidPacketDate: Date?
    private var latestTelemetry: SimTelemetrySnapshot?
    private var lastDetail: String?

    func configure(enabled: Bool, host: String = "127.0.0.1", port: Int, queue: DispatchQueue) {
        listenHost = host
        listenPort = min(max(port, 1_024), 65_535)
        listeningEnabled = enabled

        guard enabled else {
            stop()
            return
        }

        if socketFD >= 0 {
            return
        }

        startListening(queue: queue)
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    func snapshot(now: Date) -> (telemetry: SimTelemetrySnapshot?, status: XPlaneUDPStatus) {
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

        if !listeningEnabled {
            state = .idle
            detail = "UDP listening is disabled."
        } else if socketFD < 0 {
            state = .misconfig
            detail = lastDetail ?? "Could not bind UDP listener. Check port availability and permissions."
        } else if let lastValid = lastValidPacketDate, now.timeIntervalSince(lastValid) <= 4 {
            state = .active
            detail = "Packets are flowing."
        } else if totalPackets == 0 {
            state = .listening
            detail = "No UDP packets received. Confirm Data Output IP/port match."
        } else if lastValidPacketDate == nil {
            state = .misconfig
            detail = lastDetail ?? "Packets received but format/index mismatch."
        } else {
            state = .listening
            detail = "Listening, but no recent valid packets."
        }

        let status = XPlaneUDPStatus(
            state: state,
            listenHost: listenHost,
            listenPort: listenPort,
            lastPacketDate: lastPacketDate,
            lastValidPacketDate: lastValidPacketDate,
            packetsPerSecond: packetsPerSecond,
            totalPackets: totalPackets,
            invalidPackets: invalidPackets,
            detail: detail
        )

        let telemetry: SimTelemetrySnapshot?
        if let latestTelemetry,
           let lastValidPacketDate,
           now.timeIntervalSince(lastValidPacketDate) <= 5 {
            telemetry = latestTelemetry
        } else {
            telemetry = nil
        }

        return (telemetry, status)
    }

    private func startListening(queue: DispatchQueue) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            lastDetail = "Failed to create UDP socket."
            return
        }

        var reuseAddress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(listenPort).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else {
            lastDetail = "Could not bind 127.0.0.1:\(listenPort). Another process may already be using this port."
            Darwin.close(fd)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readPackets()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()

        socketFD = fd
        readSource = source
        lastDetail = nil
    }

    private func readPackets() {
        guard socketFD >= 0 else { return }

        let now = Date()
        if lastWindowDate == nil {
            lastWindowDate = now
        }

        while true {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let readCount = recv(socketFD, &buffer, buffer.count, 0)

            if readCount > 0 {
                totalPackets += 1
                packetsInWindow += 1
                lastPacketDate = now

                let parseResult = parse(packet: Data(buffer.prefix(Int(readCount))), now: now)
                if parseResult.valid {
                    if let telemetry = parseResult.telemetry {
                        latestTelemetry = telemetry
                    }
                    lastValidPacketDate = now
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

            lastDetail = "UDP read error: \(String(cString: strerror(errno)))"
            break
        }
    }

    private func parse(packet: Data, now: Date) -> (valid: Bool, telemetry: SimTelemetrySnapshot?, detail: String?) {
        guard packet.count >= 5 else {
            return (false, nil, "Received tiny UDP packet (too small for X-Plane DATA format).")
        }

        guard packet[0] == 0x44, packet[1] == 0x41, packet[2] == 0x54, packet[3] == 0x41 else {
            return (false, nil, "Packets received but not X-Plane DATA packets. Check Data Output settings.")
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

        guard !records.isEmpty else {
            return (false, nil, "DATA packet had no readable records.")
        }

        let fps = readFPS(records: records)
        let frameTime = readFrameTime(records: records)
        let altitude = readAltitude(records: records)

        if fps == nil, frameTime == nil, altitude.aglFeet == nil, altitude.mslFeet == nil {
            datasetMismatchPackets += 1
            return (false, nil, "DATA packets are arriving but expected dataset fields are missing. Enable frame-rate and position output.")
        }

        let telemetry = SimTelemetrySnapshot(
            source: "X-Plane UDP Data Output",
            fps: fps,
            frameTimeMS: frameTime,
            altitudeAGLFeet: altitude.aglFeet,
            altitudeMSLFeet: altitude.mslFeet,
            lastPacketDate: now
        )

        return (true, telemetry, nil)
    }

    private func readFPS(records: [Int32: [Float]]) -> Double? {
        guard let frameRecord = records[0], !frameRecord.isEmpty else {
            return nil
        }

        let candidate = Double(frameRecord[0])
        guard candidate.isFinite, candidate > 1, candidate < 400 else {
            return nil
        }
        return candidate
    }

    private func readFrameTime(records: [Int32: [Float]]) -> Double? {
        guard let frameRecord = records[0], frameRecord.count >= 3 else {
            return nil
        }

        let secondsPerFrame = Double(frameRecord[2])
        guard secondsPerFrame.isFinite, secondsPerFrame > 0.001, secondsPerFrame < 0.5 else {
            return nil
        }
        return secondsPerFrame * 1_000.0
    }

    private func readAltitude(records: [Int32: [Float]]) -> (aglFeet: Double?, mslFeet: Double?) {
        // Data set 20 commonly contains latitude/longitude/altitude fields in X-Plane Data Output.
        if let positionRecord = records[20], positionRecord.count >= 4 {
            let msl = normalizeAltitude(Double(positionRecord[2]), min: -1_500, max: 80_000)
            let agl = normalizeAltitude(Double(positionRecord[3]), min: -200, max: 50_000)
            return (agl, msl)
        }

        return (nil, nil)
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
}
