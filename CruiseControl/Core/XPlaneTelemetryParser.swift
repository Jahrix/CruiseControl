import Foundation

public protocol TelemetryParsing: Sendable {
    func parse(_ packet: Data) -> Result<ParsedXPlaneTelemetry, TelemetryParseError>
}

public struct XPlaneTelemetryParser: TelemetryParsing {
    // X-Plane DATA packets reserve five bytes before the first record. The
    // first four identify the packet type; the fifth is a simulator suffix
    // (captured as both NUL and `*`), not a record delimiter to validate.
    private static let packetType: [UInt8] = [0x44, 0x41, 0x54, 0x41] // DATA
    private static let headerSize = 5
    private static let recordSize = 36

    public init() {}

    public func parse(_ packet: Data) -> Result<ParsedXPlaneTelemetry, TelemetryParseError> {
        guard packet.count >= Self.headerSize else {
            return .failure(.tooShort(actualBytes: packet.count))
        }
        guard Array(packet.prefix(Self.packetType.count)) == Self.packetType else {
            return .failure(.unsupportedHeader)
        }

        let payloadBytes = packet.count - Self.headerSize
        guard payloadBytes >= Self.recordSize else {
            return .failure(.tooShort(actualBytes: packet.count))
        }
        guard payloadBytes.isMultiple(of: Self.recordSize) else {
            return .failure(.truncatedRecord(trailingBytes: payloadBytes % Self.recordSize))
        }

        var offset = Self.headerSize
        while offset < packet.count {
            let dataSet = Int32(bitPattern: readUInt32LE(packet, offset: offset))
            if dataSet == 0 {
                return parseFrameRateRecord(packet, offset: offset + 4)
            }
            offset += Self.recordSize
        }
        return .failure(.missingFrameRateDataSet)
    }

    private func parseFrameRateRecord(_ packet: Data, offset: Int) -> Result<ParsedXPlaneTelemetry, TelemetryParseError> {
        let values = (0..<8).map { index in
            Float(bitPattern: readUInt32LE(packet, offset: offset + index * 4))
        }

        // X-Plane Data Output set 0: f-act, f-sim, frame, cpu, gpu, ...
        let fps = Double(values[0])
        guard fps.isFinite, fps >= 1, fps <= 500 else {
            return .failure(.invalidFPS)
        }

        // FPS is the authoritative public measurement. The derived frame time is
        // deliberately used as the headline so FPS and milliseconds cannot disagree.
        let frameTime = 1_000 / fps
        let cpu = millisecondsIfValid(values[3])
        let gpu = millisecondsIfValid(values[4])

        return .success(
            ParsedXPlaneTelemetry(
                fps: fps,
                frameTimeMilliseconds: frameTime,
                simulatorCPUTimeMilliseconds: cpu,
                gpuTimeMilliseconds: gpu
            )
        )
    }

    private func millisecondsIfValid(_ seconds: Float) -> Double? {
        let value = Double(seconds)
        guard value.isFinite, value >= 0.000_5, value <= 1 else { return nil }
        return value * 1_000
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}
