import Foundation

public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public struct ParsedXPlaneTelemetry: Equatable, Sendable {
    public let fps: Double
    public let frameTimeMilliseconds: Double
    public let simulatorCPUTimeMilliseconds: Double?
    public let gpuTimeMilliseconds: Double?

    public init(
        fps: Double,
        frameTimeMilliseconds: Double,
        simulatorCPUTimeMilliseconds: Double?,
        gpuTimeMilliseconds: Double?
    ) {
        self.fps = fps
        self.frameTimeMilliseconds = frameTimeMilliseconds
        self.simulatorCPUTimeMilliseconds = simulatorCPUTimeMilliseconds
        self.gpuTimeMilliseconds = gpuTimeMilliseconds
    }
}

public enum TelemetryParseError: Error, Equatable, Sendable {
    case tooShort(actualBytes: Int)
    case unsupportedHeader
    case truncatedRecord(trailingBytes: Int)
    case missingFrameRateDataSet
    case invalidFPS
}

public struct FrameSample: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let capturedAt: Date
    public let monotonicNanoseconds: UInt64
    public let sourceSequence: UInt64?
    public let fps: Double
    public let frameTimeMilliseconds: Double
    public let simulatorCPUTimeMilliseconds: Double?
    public let gpuTimeMilliseconds: Double?
    public let hostCPUPercent: Double?

    public init(
        capturedAt: Date,
        monotonicNanoseconds: UInt64,
        sourceSequence: UInt64? = nil,
        fps: Double,
        frameTimeMilliseconds: Double,
        simulatorCPUTimeMilliseconds: Double? = nil,
        gpuTimeMilliseconds: Double? = nil,
        hostCPUPercent: Double? = nil
    ) {
        self.id = monotonicNanoseconds
        self.capturedAt = capturedAt
        self.monotonicNanoseconds = monotonicNanoseconds
        self.sourceSequence = sourceSequence
        self.fps = fps
        self.frameTimeMilliseconds = frameTimeMilliseconds
        self.simulatorCPUTimeMilliseconds = simulatorCPUTimeMilliseconds
        self.gpuTimeMilliseconds = gpuTimeMilliseconds
        self.hostCPUPercent = hostCPUPercent
    }

    public var isValid: Bool {
        fps.isFinite && fps >= 1 && fps <= 500 &&
        frameTimeMilliseconds.isFinite && frameTimeMilliseconds >= 2 && frameTimeMilliseconds <= 1_000
    }
}

public enum SampleRejection: Equatable, Sendable {
    case invalid
    case reordered
}

public enum ConnectionPhase: String, Equatable, Sendable {
    case xPlaneNotRunning
    case awaitingTelemetry
    case incorrectDataOutput
    case portConflict
    case permissionDenied
    case malformedOrUnsupported
    case collecting
    case missingDiagnosticFields
    case connectionLost

    public var title: String {
        switch self {
        case .xPlaneNotRunning: return "X-Plane is not running"
        case .awaitingTelemetry: return "Waiting for X-Plane telemetry"
        case .incorrectDataOutput: return "Data Output is not configured"
        case .portConflict: return "Telemetry port is already in use"
        case .permissionDenied: return "Network permission is unavailable"
        case .malformedOrUnsupported: return "Unsupported telemetry received"
        case .collecting: return "Connected and collecting"
        case .missingDiagnosticFields: return "Connected, but diagnostic fields are missing"
        case .connectionLost: return "X-Plane connection was lost"
        }
    }
}

public enum TransportFailure: Equatable, Sendable {
    case portConflict
    case permissionDenied
    case other
}

public struct ConnectionMonitor: Sendable {
    public var xPlaneIsRunning = false
    public var listenerIsActive = false
    public var listenerStartedNanoseconds: UInt64?
    public var bindingFailure: TransportFailure?
    public var receivedPacketCount: UInt64 = 0
    public var malformedPacketCount: UInt64 = 0
    public var missingFieldPacketCount: UInt64 = 0
    public var lastValidPacketNanoseconds: UInt64?
    public var latestSampleHasDiagnosticTimings = false

    public init() {}

    public mutating func listenerStarted(at nanoseconds: UInt64) {
        listenerIsActive = true
        listenerStartedNanoseconds = nanoseconds
        bindingFailure = nil
    }

    public mutating func listenerFailed(_ failure: TransportFailure) {
        listenerIsActive = false
        bindingFailure = failure
    }

    public mutating func observedPacket(
        at nanoseconds: UInt64,
        outcome: Result<ParsedXPlaneTelemetry, TelemetryParseError>
    ) {
        receivedPacketCount += 1
        switch outcome {
        case .success(let telemetry):
            lastValidPacketNanoseconds = nanoseconds
            latestSampleHasDiagnosticTimings = telemetry.simulatorCPUTimeMilliseconds != nil && telemetry.gpuTimeMilliseconds != nil
        case .failure(.missingFrameRateDataSet):
            missingFieldPacketCount += 1
        case .failure:
            malformedPacketCount += 1
        }
    }

    public func phase(nowNanoseconds: UInt64) -> ConnectionPhase {
        guard xPlaneIsRunning else { return .xPlaneNotRunning }
        if bindingFailure == .portConflict { return .portConflict }
        if bindingFailure == .permissionDenied { return .permissionDenied }
        guard listenerIsActive else { return .awaitingTelemetry }

        if let lastValidPacketNanoseconds {
            let age = nowNanoseconds >= lastValidPacketNanoseconds ? nowNanoseconds - lastValidPacketNanoseconds : 0
            if age > 4_000_000_000 { return .connectionLost }
            return latestSampleHasDiagnosticTimings ? .collecting : .missingDiagnosticFields
        }
        if missingFieldPacketCount > 0 { return .missingDiagnosticFields }
        if malformedPacketCount > 0 { return .malformedOrUnsupported }

        let listeningAge: UInt64
        if let listenerStartedNanoseconds, nowNanoseconds >= listenerStartedNanoseconds {
            listeningAge = nowNanoseconds - listenerStartedNanoseconds
        } else {
            listeningAge = 0
        }
        return listeningAge >= 6_000_000_000 ? .incorrectDataOutput : .awaitingTelemetry
    }
}

public struct FrameStatistics: Equatable, Sendable {
    public let sampleCount: Int
    public let windowStart: Date
    public let windowEnd: Date
    public let durationSeconds: TimeInterval
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double?
    public let p99Milliseconds: Double?
    public let medianAbsoluteDeviationMilliseconds: Double
    public let varianceMillisecondsSquared: Double
    public let spikeCount: Int
    public let spikeFrequency: Double
    public let medianFPS: Double
    public let medianSimulatorCPUTimeMilliseconds: Double?
    public let medianGPUTimeMilliseconds: Double?
    public let medianHostCPUPercent: Double?
}

public enum Bottleneck: String, Equatable, Sendable, CaseIterable {
    case cpu
    case gpu
    case simulatorMainThread
    case synchronizationCap
    case instability
    case insufficientEvidence

    public var title: String {
        switch self {
        case .cpu: return "Mac CPU pressure"
        case .gpu: return "GPU"
        case .simulatorMainThread: return "Simulator / main thread"
        case .synchronizationCap: return "Synchronization or FPS cap"
        case .instability: return "Frame-time instability"
        case .insufficientEvidence: return "Insufficient evidence"
        }
    }
}

public enum DiagnosticConfidence: String, Equatable, Sendable {
    case low
    case medium
    case high
}

public struct DiagnosticResult: Equatable, Sendable {
    public let bottleneck: Bottleneck
    public let confidence: DiagnosticConfidence
    public let explanation: String
    public let evidence: String
    public let recommendation: String
    public let validation: String
    public let revert: String
    public let statistics: FrameStatistics?

    public init(
        bottleneck: Bottleneck,
        confidence: DiagnosticConfidence,
        explanation: String,
        evidence: String,
        recommendation: String,
        validation: String,
        revert: String,
        statistics: FrameStatistics?
    ) {
        self.bottleneck = bottleneck
        self.confidence = confidence
        self.explanation = explanation
        self.evidence = evidence
        self.recommendation = recommendation
        self.validation = validation
        self.revert = revert
        self.statistics = statistics
    }
}

public struct ExperimentComparison: Equatable, Sendable {
    public let baselineMedianMilliseconds: Double
    public let validationMedianMilliseconds: Double
    public let changeMilliseconds: Double
    public let changePercent: Double
    public let improved: Bool
    public let baselineSamples: Int
    public let validationSamples: Int
}

public struct DiagnosticChange: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let timestamp: Date
    public let monotonicNanoseconds: UInt64
    public let bottleneck: Bottleneck
    public let confidence: DiagnosticConfidence

    public init(
        timestamp: Date,
        monotonicNanoseconds: UInt64,
        bottleneck: Bottleneck,
        confidence: DiagnosticConfidence
    ) {
        id = monotonicNanoseconds
        self.timestamp = timestamp
        self.monotonicNanoseconds = monotonicNanoseconds
        self.bottleneck = bottleneck
        self.confidence = confidence
    }
}
