import XCTest
@testable import CruiseControlCore

final class TelemetryParserTests: XCTestCase {
    private let parser = XPlaneTelemetryParser()

    func testParsesRecordedDataSetZeroFixture() throws {
        let packet = try fixture(named: "valid-data-set-0")
        let telemetry = try parser.parse(packet).get()

        XCTAssertEqual(telemetry.fps, 40, accuracy: 0.001)
        XCTAssertEqual(telemetry.frameTimeMilliseconds, 25, accuracy: 0.001)
        XCTAssertEqual(telemetry.simulatorCPUTimeMilliseconds ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(telemetry.gpuTimeMilliseconds ?? 0, 12, accuracy: 0.01)
    }

    func testRejectsMalformedAndTruncatedPackets() {
        XCTAssertEqual(parser.parse(Data([0x44, 0x41])).failure, .tooShort(actualBytes: 2))
        XCTAssertEqual(parser.parse(Data([0x58, 0x41, 0x54, 0x41, 0x2A])).failure, .unsupportedHeader)
        var truncated = Data([0x44, 0x41, 0x54, 0x41, 0x00])
        truncated.append(Data(repeating: 0, count: 37))
        XCTAssertEqual(parser.parse(truncated).failure, .truncatedRecord(trailingBytes: 1))
    }

    func testParsesCapturedDataAsteriskPacketWithFrameRateAndPositionRecords() throws {
        var data = Data([0x44, 0x41, 0x54, 0x41, 0x2A]) // DATA*
        append(UInt32(0), to: &data)
        [
            Float(14.917225), Float(19.899998), Float(-999.0), Float(0.0670366),
            Float(0.06616097), 0, 1, 1
        ].forEach { append($0.bitPattern, to: &data) }
        append(UInt32(20), to: &data)
        [Float(37.6188), Float(-122.375), Float(13), Float(0), 0, 0, 0, 0].forEach {
            append($0.bitPattern, to: &data)
        }

        XCTAssertEqual(data.count, 77)
        let telemetry = try parser.parse(data).get()
        XCTAssertEqual(telemetry.fps, 14.917225, accuracy: 0.000_001)
        XCTAssertEqual(telemetry.frameTimeMilliseconds, 67.0366, accuracy: 0.001)
        XCTAssertEqual(telemetry.simulatorCPUTimeMilliseconds ?? 0, 67.0366, accuracy: 0.001)
        XCTAssertEqual(telemetry.gpuTimeMilliseconds ?? 0, 66.16097, accuracy: 0.001)
    }

    func testReportsMissingRequiredDataSet() throws {
        XCTAssertEqual(
            parser.parse(try fixture(named: "missing-frame-rate")).failure,
            .missingFrameRateDataSet
        )
    }

    func testParsesFrameRateAfterMoreThanLegacyReceiverBufferSize() throws {
        var data = Data([0x44, 0x41, 0x54, 0x41, 0x00])
        for dataSet in 1...57 {
            append(UInt32(dataSet), to: &data)
            for _ in 0..<8 { append(Float.zero.bitPattern, to: &data) }
        }
        append(UInt32(0), to: &data)
        [Float(50), 50, 0.02, 0.015, 0.01, 0, 0, 0].forEach { append($0.bitPattern, to: &data) }

        XCTAssertGreaterThan(data.count, 2_048)
        let telemetry = try parser.parse(data).get()
        XCTAssertEqual(telemetry.fps, 50, accuracy: 0.001)
        XCTAssertEqual(telemetry.frameTimeMilliseconds, 20, accuracy: 0.001)
    }

    func testRejectsZeroAndImpossibleFPS() {
        XCTAssertEqual(parser.parse(packet(fps: 0)).failure, .invalidFPS)
        XCTAssertEqual(parser.parse(packet(fps: 501)).failure, .invalidFPS)
        XCTAssertEqual(try? parser.parse(packet(fps: 1)).get().frameTimeMilliseconds, 1_000)
        XCTAssertEqual(try? parser.parse(packet(fps: 500)).get().frameTimeMilliseconds, 2)
    }

    private func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "hex", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return decodeHex(text)
    }

    private func packet(fps: Float) -> Data {
        var data = Data([0x44, 0x41, 0x54, 0x41, 0x00])
        append(UInt32(0), to: &data)
        let values: [Float] = [fps, fps, fps > 0 ? 1 / fps : 0, 0.02, 0.01, 0, 0, 0]
        values.forEach { append($0.bitPattern, to: &data) }
        return data
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func decodeHex(_ text: String) -> Data {
        let hex = text.filter { $0.isHexDigit }
        return Data(stride(from: 0, to: hex.count, by: 2).compactMap { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }
}

final class SamplePipelineTests: XCTestCase {
    func testBufferIsBoundedAndRejectsReordering() {
        var pipeline = SamplePipeline(capacity: 3)
        for index in 1...5 {
            XCTAssertNil(pipeline.append(sample(UInt64(index), frameTime: 20)))
        }
        XCTAssertEqual(pipeline.samples.map(\.monotonicNanoseconds), [3, 4, 5])
        XCTAssertEqual(pipeline.append(sample(4, frameTime: 20)), .reordered)
        XCTAssertEqual(pipeline.rejectedReorderedCount, 1)
    }

    func testStaleBehaviorUsesMonotonicTime() {
        var pipeline = SamplePipeline(capacity: 10, staleAfterSeconds: 4)
        pipeline.append(sample(10_000_000_000, frameTime: 20))
        XCTAssertFalse(pipeline.isStale(nowNanoseconds: 14_000_000_000))
        XCTAssertTrue(pipeline.isStale(nowNanoseconds: 14_000_000_001))
    }

    func testAggregationCalculatesPercentilesAndSpikes() throws {
        var samples: [FrameSample] = []
        for index in 0..<100 {
            let frameTime = index == 99 ? 80.0 : Double(10 + index % 10)
            samples.append(sample(UInt64(index + 1), frameTime: frameTime))
        }
        let stats = try XCTUnwrap(SamplePipeline.statistics(for: samples))
        XCTAssertEqual(stats.sampleCount, 100)
        XCTAssertNotNil(stats.p95Milliseconds)
        XCTAssertNotNil(stats.p99Milliseconds)
        XCTAssertEqual(stats.spikeCount, 1)
        XCTAssertEqual(stats.spikeFrequency, 0.01, accuracy: 0.0001)
    }

    func testExtendedSessionRemainsBounded() {
        var pipeline = SamplePipeline(capacity: 1_800)
        for index in 1...100_000 {
            pipeline.append(sample(UInt64(index), frameTime: 20 + Double(index % 5)))
        }
        XCTAssertEqual(pipeline.samples.count, 1_800)
    }

    private func sample(_ monotonic: UInt64, frameTime: Double) -> FrameSample {
        FrameSample(
            capturedAt: Date(timeIntervalSince1970: Double(monotonic)),
            monotonicNanoseconds: monotonic,
            fps: 1_000 / frameTime,
            frameTimeMilliseconds: frameTime
        )
    }
}

final class ConnectionMonitorTests: XCTestCase {
    func testLossAndRecoveryAreDistinct() {
        var monitor = ConnectionMonitor()
        monitor.xPlaneIsRunning = true
        monitor.listenerStarted(at: 1)
        let telemetry = ParsedXPlaneTelemetry(
            fps: 40,
            frameTimeMilliseconds: 25,
            simulatorCPUTimeMilliseconds: 20,
            gpuTimeMilliseconds: 12
        )
        monitor.observedPacket(at: 1_000_000_000, outcome: .success(telemetry))
        XCTAssertEqual(monitor.phase(nowNanoseconds: 2_000_000_000), .collecting)
        XCTAssertEqual(monitor.phase(nowNanoseconds: 6_000_000_001), .connectionLost)

        monitor.observedPacket(at: 7_000_000_000, outcome: .success(telemetry))
        XCTAssertEqual(monitor.phase(nowNanoseconds: 7_000_000_001), .collecting)
    }

    func testExplainsNoPacketsPortConflictAndMalformedPackets() {
        var monitor = ConnectionMonitor()
        monitor.xPlaneIsRunning = true
        monitor.listenerStarted(at: 1)
        XCTAssertEqual(monitor.phase(nowNanoseconds: 7_000_000_000), .incorrectDataOutput)
        monitor.listenerFailed(.portConflict)
        XCTAssertEqual(monitor.phase(nowNanoseconds: 7_000_000_000), .portConflict)

        monitor.listenerStarted(at: 8_000_000_000)
        monitor.observedPacket(at: 9_000_000_000, outcome: .failure(.unsupportedHeader))
        XCTAssertEqual(monitor.phase(nowNanoseconds: 9_000_000_001), .malformedOrUnsupported)
    }
}

final class FlightContextTests: XCTestCase {
    func testUnknownContextHasNoInferredValues() {
        let context = FlightContext.normalized(
            simulatorVersionRaw: nil,
            aircraftIdentifier: nil,
            aircraftName: "   ",
            nearestAirportICAO: nil,
            altitudeAGLFeet: nil,
            altitudeMSLFeet: nil,
            isOnGround: nil
        )

        XCTAssertEqual(context.simulatorVersion, .unknown)
        XCTAssertNil(context.aircraftIdentifier)
        XCTAssertNil(context.aircraftName)
        XCTAssertNil(context.nearestAirportICAO)
        XCTAssertNil(context.altitudeAGLFeet)
        XCTAssertNil(context.altitudeMSLFeet)
        XCTAssertNil(context.isOnGround)
        XCTAssertEqual(context.aircraftDisplayName, "Not available yet")
        XCTAssertEqual(context.phaseOfFlightDetail, "Not available yet")
    }

    func testNormalizesReliableBridgeAndTelemetryValues() {
        let context = FlightContext.normalized(
            simulatorVersionRaw: "X-Plane 12.1",
            aircraftIdentifier: "  B738  ",
            aircraftName: "  Boeing 737-800  ",
            nearestAirportICAO: " kjfk ",
            altitudeAGLFeet: 42.4,
            altitudeMSLFeet: 13,
            isOnGround: true
        )

        XCTAssertEqual(context.simulatorVersion, .xp12)
        XCTAssertEqual(context.aircraftIdentifier, "B738")
        XCTAssertEqual(context.aircraftName, "Boeing 737-800")
        XCTAssertEqual(context.aircraftDisplayName, "Boeing 737-800")
        XCTAssertEqual(context.nearestAirportICAO, "KJFK")
        XCTAssertEqual(context.altitudeAGLFeet, 42.4)
        XCTAssertEqual(context.altitudeMSLFeet, 13)
        XCTAssertEqual(context.isOnGround, true)
        XCTAssertEqual(context.phaseOfFlightDetail, "42 ft AGL · On ground")
    }

    func testRejectsMalformedContextValuesRatherThanGuessing() {
        let context = FlightContext.normalized(
            simulatorVersionRaw: "X-Plane 13",
            aircraftIdentifier: "",
            aircraftName: nil,
            nearestAirportICAO: "near-airport",
            altitudeAGLFeet: .infinity,
            altitudeMSLFeet: 100_000,
            isOnGround: nil
        )

        XCTAssertEqual(context.simulatorVersion, .unknown)
        XCTAssertNil(context.nearestAirportICAO)
        XCTAssertNil(context.altitudeAGLFeet)
        XCTAssertNil(context.altitudeMSLFeet)
        XCTAssertNil(context.isOnGround)
    }
}

final class SessionHistoryTests: XCTestCase {
    func testRoundTripsVersionedCompactSessionHistory() throws {
        let record = makeRecord()
        let encoded = try SessionHistoryPersistence.encode(.init(records: [record]))
        let decoded = try SessionHistoryPersistence.decode(encoded)

        XCTAssertEqual(decoded.schemaVersion, SessionHistoryDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.records, [record])
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("frameSamples") ?? true)
    }

    func testMigratesLegacyBareRecordArray() throws {
        let record = makeRecord()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode([record])

        let migrated = try SessionHistoryPersistence.decode(legacyData)
        XCTAssertEqual(migrated.schemaVersion, SessionHistoryDocument.currentSchemaVersion)
        XCTAssertEqual(migrated.records, [record])
    }

    func testRejectsFutureSessionHistorySchema() {
        let data = Data(#"{"schemaVersion":2,"records":[]}"#.utf8)
        XCTAssertThrowsError(try SessionHistoryPersistence.decode(data)) { error in
            XCTAssertEqual(error as? SessionHistoryPersistence.Error, .unsupportedSchema(2))
        }
    }

    func testBoundsStoredActionDetails() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let actions = (0..<20).map {
            FlightSessionRecord.ActionSummary(
                timestamp: startedAt.addingTimeInterval(TimeInterval($0)),
                kind: "Action \($0)",
                succeeded: true,
                message: "Recorded action"
            )
        }
        let record = FlightSessionRecord(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            flightContext: .unknown,
            averageFPS: 30,
            stability: .init(sampleCount: 20, averageFrameTimeMilliseconds: 33, lowestFPS: 20, spikeCount: 1),
            stutterCount: 1,
            actions: actions
        )

        XCTAssertEqual(record.actions.count, 12)
        XCTAssertEqual(record.actions.first?.kind, "Action 8")
    }

    private func makeRecord() -> FlightSessionRecord {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        return FlightSessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            flightContext: .normalized(
                simulatorVersionRaw: "XP12",
                aircraftIdentifier: "A339",
                aircraftName: "Airbus A330-900",
                nearestAirportICAO: "KJFK",
                altitudeAGLFeet: 35,
                altitudeMSLFeet: 10,
                isOnGround: true
            ),
            averageFPS: 42.5,
            stability: .init(sampleCount: 1_800, averageFrameTimeMilliseconds: 23.5, lowestFPS: 27, spikeCount: 12),
            stutterCount: 3,
            actions: [
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    timestamp: startedAt.addingTimeInterval(20),
                    kind: "Close background app",
                    succeeded: true,
                    message: "Closed successfully"
                )
            ]
        )
    }
}

final class BenchmarkModelsTests: XCTestCase {
    func testCalculatesDeltasForComparableRuns() {
        let baseline = makeRun(fps: 30, frameTime: 33, stutters: 4, airport: "KMCO")
        let comparison = makeRun(fps: 36, frameTime: 27, stutters: 1, airport: "KMCO")
        let pair = BenchmarkPair(name: "Objects one step lower", baseline: baseline, comparison: comparison)

        XCTAssertEqual(pair.averageFPSDelta, 6, accuracy: 0.001)
        XCTAssertEqual(pair.medianFrameTimeDelta, -6, accuracy: 0.001)
        XCTAssertEqual(pair.stutterDelta, -3)
        XCTAssertEqual(pair.compatibility, .comparable)
    }

    func testFlagsDifferentReliableContextAsQuestionable() {
        let baseline = makeRun(fps: 30, frameTime: 33, stutters: 4, airport: "KMCO", aircraft: "B738")
        let comparison = makeRun(fps: 30, frameTime: 33, stutters: 4, airport: "KJFK", aircraft: "A339")
        let pair = BenchmarkPair(name: "Mismatch", baseline: baseline, comparison: comparison)

        guard case .questionable(let reasons) = pair.compatibility else {
            return XCTFail("Expected a context mismatch")
        }
        XCTAssertEqual(reasons, ["Aircraft identifiers differ.", "Airport ICAO codes differ."])
    }

    func testRoundTripsVersionedBenchmarkHistory() throws {
        let pair = BenchmarkPair(
            name: "Round trip",
            createdAt: Date(timeIntervalSince1970: 2_000),
            baseline: makeRun(fps: 30, frameTime: 33, stutters: 1, airport: "KMCO"),
            comparison: makeRun(fps: 31, frameTime: 32, stutters: 0, airport: "KMCO")
        )
        let decoded = try BenchmarkHistoryPersistence.decode(BenchmarkHistoryPersistence.encode(.init(pairs: [pair])))

        XCTAssertEqual(decoded.schemaVersion, BenchmarkHistoryDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.pairs, [pair])
    }

    private func makeRun(fps: Double, frameTime: Double, stutters: Int, airport: String, aircraft: String = "B738") -> BenchmarkRun {
        let start = Date(timeIntervalSince1970: 1_000)
        return BenchmarkRun(
            startedAt: start,
            endedAt: start.addingTimeInterval(30),
            flightContext: .normalized(simulatorVersionRaw: "XP11", aircraftIdentifier: aircraft, aircraftName: nil, nearestAirportICAO: airport, altitudeAGLFeet: 0, altitudeMSLFeet: 0, isOnGround: true),
            settingsSnapshot: ["workload_profile": "generalPerformance"],
            sampleCount: 600,
            averageFPS: fps,
            lowestFPS: fps - 5,
            medianFrameTimeMilliseconds: frameTime,
            p95FrameTimeMilliseconds: frameTime + 5,
            spikeFraction: 0.02,
            stutterCount: stutters
        )
    }
}

final class DiagnosticEngineTests: XCTestCase {
    func testClassifiesSimulatorCPUOnlyWithTimingEvidence() {
        let samples = timedSamples(cpu: 25, gpu: 12, frame: 27)
        let result = DiagnosticEngine().diagnose(samples: samples, telemetryIsStale: false)
        XCTAssertEqual(result.bottleneck, .simulatorMainThread)
        XCTAssertNotEqual(result.confidence, .low)
    }

    func testClassifiesGPUOnlyWithTimingEvidence() {
        let samples = timedSamples(cpu: 10, gpu: 24, frame: 26)
        XCTAssertEqual(
            DiagnosticEngine().diagnose(samples: samples, telemetryIsStale: false).bottleneck,
            .gpu
        )
    }

    func testReturnsInsufficientForMissingOrStaleEvidence() {
        let missing = timedSamples(cpu: nil, gpu: nil, frame: 25)
        XCTAssertEqual(DiagnosticEngine().diagnose(samples: missing, telemetryIsStale: false).bottleneck, .insufficientEvidence)
        XCTAssertEqual(DiagnosticEngine().diagnose(samples: missing, telemetryIsStale: true).bottleneck, .insufficientEvidence)
    }

    func testClassifiesInstabilityFromSustainedSpikeDistribution() {
        var samples = timedSamples(cpu: nil, gpu: nil, frame: 20, count: 40)
        for index in stride(from: 4, to: 40, by: 5) {
            samples[index] = makeSample(index: index, frame: 50, cpu: nil, gpu: nil)
        }
        XCTAssertEqual(DiagnosticEngine().diagnose(samples: samples, telemetryIsStale: false).bottleneck, .instability)
    }

    func testClassifiesStableCommonCapOnlyWithTimingHeadroom() {
        let samples = timedSamples(cpu: 8, gpu: 7, frame: 1_000 / 60, count: 25)
        XCTAssertEqual(
            DiagnosticEngine().diagnose(samples: samples, telemetryIsStale: false).bottleneck,
            .synchronizationCap
        )
    }

    func testExperimentComparesOnlyPostChangeSamples() throws {
        var tracker = ExperimentTracker()
        let baseline = timedSamples(cpu: 18, gpu: 10, frame: 25, count: 20)
        XCTAssertTrue(tracker.begin(baselineSamples: baseline, nowNanoseconds: 30_000_000_000))

        let validation = (30...60).map {
            makeSample(index: $0, frame: 22, cpu: 16, gpu: 10)
        }
        let comparison = try XCTUnwrap(tracker.comparison(validationSamples: validation))
        XCTAssertEqual(comparison.baselineMedianMilliseconds, 25, accuracy: 0.001)
        XCTAssertEqual(comparison.validationMedianMilliseconds, 22, accuracy: 0.001)
        XCTAssertTrue(comparison.improved)

        XCTAssertNil(tracker.comparison(validationSamples: [baseline[0]] + validation))
    }

    private func timedSamples(cpu: Double?, gpu: Double?, frame: Double, count: Int = 25) -> [FrameSample] {
        (0..<count).map { makeSample(index: $0, frame: frame, cpu: cpu, gpu: gpu) }
    }

    private func makeSample(index: Int, frame: Double, cpu: Double?, gpu: Double?) -> FrameSample {
        FrameSample(
            capturedAt: Date(timeIntervalSince1970: Double(index)),
            monotonicNanoseconds: UInt64(index + 1) * 1_000_000_000,
            fps: 1_000 / frame,
            frameTimeMilliseconds: frame,
            simulatorCPUTimeMilliseconds: cpu,
            gpuTimeMilliseconds: gpu
        )
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
