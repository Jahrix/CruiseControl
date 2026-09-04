import XCTest
@testable import CruiseControlCore

final class SafeSettingsCapabilityTests: XCTestCase {
    func testLODRegistryDescribesSupportedBridgeCapability() {
        let runtime = SafeSettingsRuntime(
            simulatorVersion: .xp12,
            currentValues: [.lodBias: .number(1.25)],
            writableSettings: [.lodBias]
        )

        let capability = SafeSettingsCapabilityRegistry.capability(for: .lodBias, runtime: runtime)

        XCTAssertTrue(capability.supports(.xp11))
        XCTAssertTrue(capability.supports(.xp12))
        XCTAssertEqual(capability.currentValue, .number(1.25))
        XCTAssertEqual(capability.readability, .readable)
        XCTAssertEqual(capability.writability, .writable)
        XCTAssertEqual(capability.writeMechanism, .bridgeCommand("SET_LOD"))
        XCTAssertEqual(capability.changeTiming, .live)
        XCTAssertEqual(capability.rollback, .restorePreviousValue)
    }

    func testGatewayRejectsUnverifiedAndOutOfRangeWritesWithoutCallingWriter() {
        let writer = RecordingSafeSettingsWriter()
        let gateway = SafeSettingsWriteGateway()
        let unverifiedRuntime = SafeSettingsRuntime(
            simulatorVersion: .xp12,
            currentValues: [.lodBias: .number(1)],
            writableSettings: []
        )

        let unverified = gateway.execute(
            SafeSettingsWriteRequest(settingID: .lodBias, value: .number(1.1)),
            runtime: unverifiedRuntime,
            writer: writer
        )
        XCTAssertEqual(unverified.outcome, .rejectedNotWritable)
        XCTAssertTrue(writer.values.isEmpty)

        let verifiedRuntime = SafeSettingsRuntime(
            simulatorVersion: .xp12,
            currentValues: [.lodBias: .number(1)],
            writableSettings: [.lodBias]
        )
        let invalid = gateway.execute(
            SafeSettingsWriteRequest(settingID: .lodBias, value: .number(3.1)),
            runtime: verifiedRuntime,
            writer: writer
        )
        XCTAssertEqual(invalid.outcome, .rejectedInvalidValue)
        XCTAssertTrue(writer.values.isEmpty)
    }

    func testGatewayProducesReceiptAndAllowsOnlyVerifiedSupportedWrite() {
        let writer = RecordingSafeSettingsWriter()
        let runtime = SafeSettingsRuntime(
            simulatorVersion: .xp11,
            currentValues: [.lodBias: .number(1.3)],
            writableSettings: [.lodBias]
        )

        let receipt = SafeSettingsWriteGateway().execute(
            SafeSettingsWriteRequest(settingID: .lodBias, value: .number(1.1)),
            runtime: runtime,
            writer: writer,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(receipt.outcome, .applied)
        XCTAssertEqual(receipt.previousValue, .number(1.3))
        XCTAssertEqual(receipt.rollback, .restorePreviousValue)
        XCTAssertEqual(writer.values, [.number(1.1)])
    }

    func testGatewayAllowsOnlyExplicitCandidateBridgeVerification() {
        let writer = RecordingSafeSettingsWriter()
        let runtime = SafeSettingsRuntime(
            simulatorVersion: .xp11,
            currentValues: [.lodBias: .number(1.2)],
            writableSettings: [],
            lodVerificationCandidate: true
        )

        let verification = SafeSettingsWriteGateway().execute(
            SafeSettingsWriteRequest(settingID: .lodVerification, value: .choice("verify")),
            runtime: runtime,
            writer: writer
        )
        XCTAssertEqual(verification.outcome, .applied)
        XCTAssertEqual(writer.values, [.choice("verify")])

        let lodWrite = SafeSettingsWriteGateway().execute(
            SafeSettingsWriteRequest(settingID: .lodBias, value: .number(1.1)),
            runtime: runtime,
            writer: writer
        )
        XCTAssertEqual(lodWrite.outcome, .rejectedNotWritable)
        XCTAssertEqual(writer.values, [.choice("verify")])
    }

    func testPreferenceBackupCanRestoreOriginalFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let preference = root.appendingPathComponent("preferences.txt")
        try "original".write(to: preference, atomically: true, encoding: .utf8)

        let store = SafeSettingsPreferenceBackupStore(fileManager: fileManager)
        let backup = try store.backup(fileURL: preference, into: root.appendingPathComponent("Backups", isDirectory: true))
        try "changed".write(to: preference, atomically: true, encoding: .utf8)
        try store.restore(backupURL: backup, to: preference)

        XCTAssertEqual(try String(contentsOf: preference, encoding: .utf8), "original")
    }

    private final class RecordingSafeSettingsWriter: SafeSettingsWriter {
        var values: [SafeSettingValue] = []

        func write(_ value: SafeSettingValue, for capability: SafeSettingsCapability) throws {
            values.append(value)
        }
    }
}

final class GovernorLODWriteVerificationTests: XCTestCase {
    func testRequiresNonceCorrelatedFreshMatchingReadback() {
        let now = Date(timeIntervalSince1970: 1_000)
        let readback = makeReadback(lod: 1.35, requestID: "write-1", updatedAt: now)

        XCTAssertNil(LODWriteVerification.failure(
            requestedLOD: 1.35,
            requestID: "write-1",
            readback: readback,
            now: now
        ))
    }

    func testRejectsMissingNonceStaleAndMismatchedReadback() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            LODWriteVerification.failure(
                requestedLOD: 1.35,
                requestID: "write-1",
                readback: makeReadback(lod: 1.35, requestID: nil, updatedAt: now),
                now: now
            ),
            .missingReadback
        )
        XCTAssertEqual(
            LODWriteVerification.failure(
                requestedLOD: 1.35,
                requestID: "write-1",
                readback: makeReadback(lod: 1.35, requestID: "write-1", updatedAt: now.addingTimeInterval(-6)),
                now: now
            ),
            .staleReadback
        )
        XCTAssertEqual(
            LODWriteVerification.failure(
                requestedLOD: 1.35,
                requestID: "write-1",
                readback: makeReadback(lod: 1.20, requestID: "write-1", updatedAt: now),
                now: now
            ),
            .readbackMismatch
        )
    }

    private func makeReadback(lod: Double, requestID: String?, updatedAt: Date) -> LODWriteReadback {
        LODWriteReadback(currentLOD: lod, requestID: requestID, observedAt: updatedAt)
    }
}

final class XPLMBridgeProtocolTests: XCTestCase {
    func testCandidateRemainsUnverifiedUntilPersistenceAndRestorationComplete() {
        var state = candidate()
        (state, _) = XPLMBridgeProtocol.beginVerification(nonce: "verify", sequence: 1, current: 1.0, state: state)
        XCTAssertEqual(state.state, .verifyingPersistence)
        for _ in 0..<3 { (state, _) = XPLMBridgeProtocol.observe(1.01, state: state) }
        XCTAssertEqual(state.state, .verifyingRestoration)
        var terminal: XPLMBridgeEvent?
        for _ in 0..<3 { (state, terminal) = XPLMBridgeProtocol.observe(1.0, state: state) }
        XCTAssertEqual(terminal, .verified)
        XCTAssertEqual(state.verifiedIdentity, state.identity)
    }

    func testPersistenceAndRestorationFailuresFailClosed() {
        var state = candidate()
        (state, _) = XPLMBridgeProtocol.beginVerification(nonce: "one", sequence: 1, current: 1.0, state: state)
        let failure = XPLMBridgeProtocol.observe(1.2, state: state)
        state = failure.0
        let event = failure.1
        XCTAssertEqual(event, .rejected("persistence verification failed"))
        XCTAssertEqual(state.state, .lockedOut)

        state = candidate()
        (state, _) = XPLMBridgeProtocol.beginVerification(nonce: "two", sequence: 1, current: 1.0, state: state)
        for _ in 0..<3 { (state, _) = XPLMBridgeProtocol.observe(1.01, state: state) }
        let restorationFailure = XPLMBridgeProtocol.observe(1.2, state: state)
        state = restorationFailure.0
        let restoreEvent = restorationFailure.1
        XCTAssertEqual(restoreEvent, .rejected("persistence verification failed"))
        XCTAssertEqual(state.state, .lockedOut)
    }

    func testSessionAndBuildChangesInvalidateVerification() {
        var state = verified()
        state.identity.pluginSessionID = "new-session"
        XCTAssertNotEqual(state.verifiedIdentity, state.identity)
        XCTAssertEqual(XPLMBridgeProtocol.beginWrite(nonce: "n", sequence: 2, requested: 1.1, current: 1.0, leaseUntil: Date(), state: state).1, .rejected("capability is not verified for this session"))
        state.identity.simulatorBuild = "XP12-120100"
        XCTAssertNotEqual(state.verifiedIdentity, state.identity)
    }

    func testRejectsDuplicateNonceAndSequenceMismatch() {
        var state = verified()
        state.lastTerminalNonce = "used"
        state.lastSequence = 4
        XCTAssertEqual(XPLMBridgeProtocol.beginWrite(nonce: "used", sequence: 5, requested: 1.1, current: 1.0, leaseUntil: Date(), state: state).1, .rejected("nonce or sequence is not new"))
        XCTAssertEqual(XPLMBridgeProtocol.beginWrite(nonce: "new", sequence: 4, requested: 1.1, current: 1.0, leaseUntil: Date(), state: state).1, .rejected("nonce or sequence is not new"))
    }

    func testFailedNormalWritePersistenceRequiresRecovery() {
        var state = verified()
        (state, _) = XPLMBridgeProtocol.beginWrite(nonce: "write", sequence: 1, requested: 1.1, current: 1.0, leaseUntil: Date().addingTimeInterval(5), state: state)
        let failure = XPLMBridgeProtocol.observe(1.0, state: state)
        state = failure.0
        let event = failure.1
        XCTAssertEqual(event, .recoveryRequired)
        XCTAssertEqual(state.state, .recoveryRequired)
    }

    func testLeaseExpiryRequestsRestoration() {
        var state = verified()
        state.activationOriginal = 1.0
        state.leaseExpiresAt = Date(timeIntervalSince1970: 1)
        let expiry = XPLMBridgeProtocol.leaseExpired(now: Date(timeIntervalSince1970: 2), state: state)
        state = expiry.0
        let event = expiry.1
        XCTAssertEqual(event, .accepted)
        XCTAssertEqual(state.state, .restoring)
    }

    private func candidate() -> XPLMBridgeState {
        XPLMBridgeProtocol.discover(candidate: true, state: .unavailable(build: "XP12-120000", session: "session"))
    }

    private func verified() -> XPLMBridgeState {
        var state = candidate()
        state.state = .verifiedIdle
        state.verifiedIdentity = state.identity
        return state
    }
}

final class AssistedOptimizationPlanTests: XCTestCase {
    func testCancellationCreatesNoReceiptsAndCannotWrite() {
        let writer = RecordingWriter()
        let result = AssistedOptimizationPlanExecutor().execute(
            plan: settingPlan(),
            approvedActionIDs: [],
            runtime: writableRuntime,
            writer: writer
        )

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(result.receipts.isEmpty)
        XCTAssertTrue(writer.values.isEmpty)
    }

    func testPartialApprovalWritesOnlySelectedCapability() {
        let writer = RecordingWriter()
        let result = AssistedOptimizationPlanExecutor().execute(
            plan: AssistedOptimizationPlan(recommendationID: "test", evidence: "test", actions: [settingAction(id: "one", value: 1.1), settingAction(id: "two", value: 1.2)]),
            approvedActionIDs: ["two"],
            runtime: writableRuntime,
            writer: writer
        )

        XCTAssertEqual(writer.values, [.number(1.2)])
        XCTAssertEqual(result.receipts.first { $0.actionID == "one" }?.outcome, .skipped)
        XCTAssertEqual(result.receipts.first { $0.actionID == "two" }?.outcome, .applied)
    }

    func testFailedWriteKeepsRollbackMetadataInReceipt() {
        let result = AssistedOptimizationPlanExecutor().execute(
            plan: settingPlan(),
            approvedActionIDs: ["lod"],
            runtime: writableRuntime,
            writer: FailingWriter()
        )

        let settingReceipt = result.receipts.first?.settingReceipt
        XCTAssertEqual(result.receipts.first?.outcome, .failed)
        XCTAssertEqual(settingReceipt?.rollback, .restorePreviousValue)
        XCTAssertEqual(settingReceipt?.previousValue, .number(1.3))
    }

    func testRestartRequiredActionIsQueuedWithoutWriting() {
        let writer = RecordingWriter()
        let restart = AssistedPlanAction(id: "restart", title: "Restart setting", reason: "test", kind: .setting(SafeSettingsWriteRequest(settingID: .lodBias, value: .number(1.1))), restartRequired: true)
        let plan = AssistedOptimizationPlan(recommendationID: "test", evidence: "test", actions: [restart])

        let result = AssistedOptimizationPlanExecutor().execute(plan: plan, approvedActionIDs: ["restart"], runtime: writableRuntime, writer: writer)

        XCTAssertEqual(result.receipts.first?.outcome, .queuedForRestart)
        XCTAssertTrue(writer.values.isEmpty)
    }

    private var writableRuntime: SafeSettingsRuntime {
        SafeSettingsRuntime(simulatorVersion: .xp12, currentValues: [.lodBias: .number(1.3)], writableSettings: [.lodBias])
    }

    private func settingPlan() -> AssistedOptimizationPlan {
        AssistedOptimizationPlan(recommendationID: "test", evidence: "test", actions: [settingAction(id: "lod", value: 1.1)])
    }

    private func settingAction(id: String, value: Double) -> AssistedPlanAction {
        AssistedPlanAction(id: id, title: "LOD", reason: "test", kind: .setting(SafeSettingsWriteRequest(settingID: .lodBias, value: .number(value))), restartRequired: false)
    }

    private final class RecordingWriter: SafeSettingsWriter {
        var values: [SafeSettingValue] = []
        func write(_ value: SafeSettingValue, for capability: SafeSettingsCapability) throws { values.append(value) }
    }

    private final class FailingWriter: SafeSettingsWriter {
        enum Failure: Error { case unavailable }
        func write(_ value: SafeSettingValue, for capability: SafeSettingsCapability) throws { throw Failure.unavailable }
    }
}

final class AdaptiveLODControllerTests: XCTestCase {
    func testUnknownCapabilityAndStaleTelemetryFailClosed() {
        var input = input(now: 10)
        input.runtime.writableSettings = []
        XCTAssertEqual(decision(input), .hold(reason: "LOD writability has not been verified."))

        input.runtime.writableSettings = [.lodBias]
        input.telemetryIsFresh = false
        XCTAssertEqual(decision(input), .hold(reason: "Telemetry is stale."))
    }

    func testUnknownSimulatorAndBridgeFailureFailClosed() {
        var unknownSimulator = input(now: 10)
        unknownSimulator.runtime.simulatorVersion = .unknown
        XCTAssertEqual(decision(unknownSimulator), .hold(reason: "Simulator version is unknown."))

        var bridgeFailure = input(now: 10)
        bridgeFailure.bridgeIsReachable = false
        XCTAssertEqual(decision(bridgeFailure), .hold(reason: "Bridge status is unavailable or stale."))
    }

    func testPhaseBoundaryNoiseDoesNotOscillateBeforeDwell() {
        var state = AdaptiveLODState.idle
        var first = input(now: 0, agl: 1_450)
        first.movingAverageFrameTimeMilliseconds = 40
        state = AdaptiveLODController.step(input: first, state: state, configuration: config).state
        XCTAssertEqual(state.phase, .ground)

        for (time, agl) in [(2.0, 1_550.0), (4.0, 1_480.0), (6.0, 1_560.0)] {
            var noisy = input(now: time, agl: agl)
            noisy.movingAverageFrameTimeMilliseconds = 40
            state = AdaptiveLODController.step(input: noisy, state: state, configuration: config).state
            XCTAssertEqual(state.phase, .ground)
        }
    }

    func testPerformancePressureUsesBoundedFastDegradeThenCooldown() {
        var state = AdaptiveLODState.idle
        state.phase = .ground
        state.phaseEnteredAt = date(0)
        var pressure = input(now: 3, agl: 0)
        pressure.movingAverageFrameTimeMilliseconds = 50
        state = AdaptiveLODController.step(input: pressure, state: state, configuration: config).state
        pressure.now = date(6)
        let requested = AdaptiveLODController.step(input: pressure, state: state, configuration: config)
        XCTAssertEqual(requested.decision, .request(target: 1.35, reason: "Sustained frame-time pressure", evidenceAge: 0))

        pressure.now = date(7)
        pressure.observedLOD = 1.35
        XCTAssertEqual(AdaptiveLODController.step(input: pressure, state: requested.state, configuration: config).decision, .hold(reason: "Adjustment cooldown is active."))
    }

    func testRecoveryRequiresLongerDwellAndMovesOneStepTowardPhaseTarget() {
        var state = AdaptiveLODState.idle
        state.phase = .ground
        state.phaseEnteredAt = date(0)
        var recovery = input(now: 5, agl: 0)
        recovery.observedLOD = 1.50
        recovery.movingAverageFrameTimeMilliseconds = 30
        state = AdaptiveLODController.step(input: recovery, state: state, configuration: config).state
        recovery.now = date(16)
        XCTAssertEqual(
            AdaptiveLODController.step(input: recovery, state: state, configuration: config).decision,
            .request(target: 1.45, reason: "Sustained frame-time recovery", evidenceAge: 0)
        )
    }

    func testPendingReadbackBlocksThenTimesOutWithoutAnotherWrite() {
        var state = AdaptiveLODState.idle
        state.phase = .ground
        state.phaseEnteredAt = date(0)
        state.originalLOD = 1.3
        state.pendingTarget = 1.35
        state.pendingSince = date(0)
        var pending = input(now: 2, agl: 0)
        XCTAssertEqual(AdaptiveLODController.step(input: pending, state: state, configuration: config).decision, .hold(reason: "Waiting for verified LOD readback."))
        pending.now = date(6)
        XCTAssertEqual(AdaptiveLODController.step(input: pending, state: state, configuration: config).decision, .hold(reason: "LOD write verification timed out; no further adjustment was made."))
    }

    func testDisableRequestsOriginalRestorationOnlyWhenCapabilityIsVerified() {
        var state = AdaptiveLODState.idle
        state.originalLOD = 1.2
        var disabling = input(now: 1)
        disabling.enabled = false
        XCTAssertEqual(AdaptiveLODController.step(input: disabling, state: state, configuration: config).decision, .restore(target: 1.2, reason: "Adaptive LOD disabled", evidenceAge: 0))

        disabling.runtime.writableSettings = []
        XCTAssertEqual(AdaptiveLODController.step(input: disabling, state: state, configuration: config).decision, .hold(reason: "Adaptive LOD disabled; original LOD restoration could not be verified."))
    }

    private var config: AdaptiveLODConfiguration {
        var value = AdaptiveLODConfiguration.default
        value.minimumPhaseDwell = 0
        value.degradationDwell = 2
        value.restorationDwell = 10
        value.degradationCooldown = 2
        value.restorationCooldown = 10
        value.minimumPerformanceSamples = 20
        return value
    }

    private func input(now: TimeInterval, agl: Double? = 0) -> AdaptiveLODInput {
        AdaptiveLODInput(
            now: date(now),
            enabled: true,
            telemetryIsFresh: true,
            bridgeIsFresh: true,
            bridgeIsReachable: true,
            readbackIsFresh: true,
            runtime: SafeSettingsRuntime(simulatorVersion: .xp12, currentValues: [.lodBias: .number(1.3)], writableSettings: [.lodBias]),
            observedLOD: 1.3,
            altitudeAGLFeet: agl,
            isOnGround: agl == 0,
            movingAverageFrameTimeMilliseconds: 40,
            movingAverageSampleCount: 20
        )
    }

    private func decision(_ input: AdaptiveLODInput) -> AdaptiveLODDecision {
        AdaptiveLODController.step(input: input, state: .idle, configuration: config).decision
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
}

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

final class RecommendationEngineTests: XCTestCase {
    private let engine = RecommendationEngine()

    func testRecommendsWorldObjectsForSimulatorMainThreadEvidence() {
        let recommendation = engine.recommend(diagnosis: diagnosis(.simulatorMainThread, confidence: .high), flightContext: .normalized(simulatorVersionRaw: "XP11", aircraftIdentifier: "B738", aircraftName: nil, nearestAirportICAO: "KMCO", altitudeAGLFeet: 0, altitudeMSLFeet: 0, isOnGround: true), telemetryIsFresh: true)
        XCTAssertEqual(recommendation.id, "world-objects")
        XCTAssertEqual(recommendation.visualImpact, .medium)
        XCTAssertFalse(recommendation.canApplySafely)
    }

    func testReturnsNoActionWhenEvidenceIsStale() {
        let recommendation = engine.recommend(diagnosis: diagnosis(.gpu, confidence: .high), flightContext: .unknown, telemetryIsFresh: false)
        XCTAssertEqual(recommendation.id, "collect-evidence")
        XCTAssertEqual(recommendation.performanceDirection, .validateOnly)
    }

    private func diagnosis(_ bottleneck: Bottleneck, confidence: DiagnosticConfidence) -> DiagnosticResult {
        DiagnosticResult(bottleneck: bottleneck, confidence: confidence, explanation: "Explanation", evidence: "Evidence", recommendation: "Hold the same view.", validation: "Validate", revert: "Revert", statistics: nil)
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
