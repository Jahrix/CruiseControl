import Foundation

public struct DiagnosticEngine: Sendable {
    public let observationWindowSeconds: TimeInterval
    public let minimumSamples: Int
    public let minimumDurationSeconds: TimeInterval

    public init(
        observationWindowSeconds: TimeInterval = 20,
        minimumSamples: Int = 15,
        minimumDurationSeconds: TimeInterval = 12
    ) {
        self.observationWindowSeconds = observationWindowSeconds
        self.minimumSamples = minimumSamples
        self.minimumDurationSeconds = minimumDurationSeconds
    }

    public func diagnose(samples: [FrameSample], telemetryIsStale: Bool) -> DiagnosticResult {
        guard !telemetryIsStale else {
            return insufficient("The last valid telemetry sample is stale.", samples: samples)
        }
        guard let stats = SamplePipeline.statistics(for: samples),
              stats.sampleCount >= minimumSamples,
              stats.durationSeconds >= minimumDurationSeconds else {
            return insufficient("Collecting a stable \(Int(observationWindowSeconds))-second evidence window.", samples: samples)
        }

        let timedSamples = samples.filter {
            $0.simulatorCPUTimeMilliseconds != nil && $0.gpuTimeMilliseconds != nil
        }
        let timingCoverage = Double(timedSamples.count) / Double(samples.count)
        let cpu = stats.medianSimulatorCPUTimeMilliseconds
        let gpu = stats.medianGPUTimeMilliseconds

        if timingCoverage >= 0.75, let cpu, let gpu {
            let dominance = max(cpu, gpu) / max(min(cpu, gpu), 0.1)
            if cpu >= gpu * 1.12, cpu >= stats.medianMilliseconds * 0.72 {
                return result(
                    bottleneck: .simulatorMainThread,
                    confidence: confidence(coverage: timingCoverage, dominance: dominance),
                    explanation: "X-Plane’s CPU frame work is taking longer than its GPU work.",
                    evidence: String(format: "Over %.0f seconds (%d samples), median simulator CPU time was %.1f ms versus %.1f ms on the GPU; median total frame time was %.1f ms.", stats.durationSeconds, stats.sampleCount, cpu, gpu, stats.medianMilliseconds),
                    recommendation: "Reduce world objects one step, keep the same aircraft and view, then run a 30-second comparison.",
                    validation: "Success means median frame time falls by at least 2 ms without a higher spike rate.",
                    revert: "Restore the previous world-objects setting if the median does not improve.",
                    stats: stats
                )
            }
            if gpu >= cpu * 1.12, gpu >= stats.medianMilliseconds * 0.72 {
                return result(
                    bottleneck: .gpu,
                    confidence: confidence(coverage: timingCoverage, dominance: dominance),
                    explanation: "X-Plane’s GPU frame work is taking longer than its simulator CPU work.",
                    evidence: String(format: "Over %.0f seconds (%d samples), median GPU time was %.1f ms versus %.1f ms for the simulator CPU; median total frame time was %.1f ms.", stats.durationSeconds, stats.sampleCount, gpu, cpu, stats.medianMilliseconds),
                    recommendation: "Reduce anti-aliasing one step, keep the same aircraft and view, then run a 30-second comparison.",
                    validation: "Success means median frame time falls by at least 2 ms without a higher spike rate.",
                    revert: "Restore the previous anti-aliasing setting if the median does not improve.",
                    stats: stats
                )
            }
        }

        if let hostCPU = stats.medianHostCPUPercent,
           hostCPU >= 88,
           stats.medianMilliseconds >= 20 {
            return result(
                bottleneck: .cpu,
                confidence: .medium,
                explanation: "The Mac is sustaining high total CPU pressure while X-Plane frame time is elevated.",
                evidence: String(format: "Over %.0f seconds (%d samples), median host CPU was %.0f%% and median frame time was %.1f ms.", stats.durationSeconds, stats.sampleCount, hostCPU, stats.medianMilliseconds),
                recommendation: "Quit the single highest-CPU nonessential app, keep the same X-Plane view, then run a 30-second comparison.",
                validation: "Success means median frame time falls by at least 2 ms or p95 improves by at least 10%%.",
                revert: "Reopen the app if the comparison shows no improvement.",
                stats: stats
            )
        }

        if let p95 = stats.p95Milliseconds,
           stats.spikeFrequency >= 0.05,
           p95 >= stats.medianMilliseconds * 1.25 {
            return result(
                bottleneck: .instability,
                confidence: stats.sampleCount >= 40 ? .high : .medium,
                explanation: "Typical frames are faster than the recurring slow spikes.",
                evidence: String(format: "Over %.0f seconds (%d samples), median frame time was %.1f ms, p95 was %.1f ms, and %.0f%% of frames were spikes.", stats.durationSeconds, stats.sampleCount, stats.medianMilliseconds, p95, stats.spikeFrequency * 100),
                recommendation: "Pause one background sync or recording tool, keep the same view, then run a 30-second comparison.",
                validation: "Success means spike frequency is cut in half without worsening median frame time.",
                revert: "Resume the paused tool if spike frequency does not improve.",
                stats: stats
            )
        }

        let commonCaps = [20.0, 24, 25, 30, 40, 45, 50, 60, 72, 75, 90, 120]
        let nearestCap = commonCaps.min(by: { abs($0 - stats.medianFPS) < abs($1 - stats.medianFPS) }) ?? 0
        let relativeDispersion = stats.medianAbsoluteDeviationMilliseconds / max(stats.medianMilliseconds, 0.1)
        let hasTimingHeadroom = if let cpu, let gpu {
            max(cpu, gpu) < stats.medianMilliseconds * 0.78
        } else {
            false
        }
        if abs(nearestCap - stats.medianFPS) <= 0.35,
           relativeDispersion <= 0.025,
           hasTimingHeadroom {
            return result(
                bottleneck: .synchronizationCap,
                confidence: .medium,
                explanation: "Frame rate is unusually stable at a common cap while both CPU and GPU timings have headroom.",
                evidence: String(format: "Over %.0f seconds (%d samples), median FPS was %.1f with %.2f ms median absolute deviation.", stats.durationSeconds, stats.sampleCount, stats.medianFPS, stats.medianAbsoluteDeviationMilliseconds),
                recommendation: "Change the X-Plane FPS cap or V-Sync mode one step, keep the same view, then run a 30-second comparison.",
                validation: "Success means the median moves away from the old cap without increasing p95 frame time.",
                revert: "Restore the previous cap or V-Sync mode if pacing becomes less stable.",
                stats: stats
            )
        }

        return insufficient("The evidence window does not show a sustained CPU, GPU, cap, or instability pattern.", samples: samples, stats: stats)
    }

    private func confidence(coverage: Double, dominance: Double) -> DiagnosticConfidence {
        if coverage >= 0.9 && dominance >= 1.25 { return .high }
        if coverage >= 0.75 && dominance >= 1.12 { return .medium }
        return .low
    }

    private func result(
        bottleneck: Bottleneck,
        confidence: DiagnosticConfidence,
        explanation: String,
        evidence: String,
        recommendation: String,
        validation: String,
        revert: String,
        stats: FrameStatistics
    ) -> DiagnosticResult {
        DiagnosticResult(
            bottleneck: bottleneck,
            confidence: confidence,
            explanation: explanation,
            evidence: evidence,
            recommendation: recommendation,
            validation: validation,
            revert: revert,
            statistics: stats
        )
    }

    private func insufficient(_ reason: String, samples: [FrameSample], stats: FrameStatistics? = nil) -> DiagnosticResult {
        DiagnosticResult(
            bottleneck: .insufficientEvidence,
            confidence: .low,
            explanation: reason,
            evidence: "No bottleneck claim is made until a fresh, sustained window contains the required timing fields.",
            recommendation: "Hold the same aircraft and camera view while CruiseControl collects at least \(Int(minimumDurationSeconds)) seconds of telemetry.",
            validation: "Diagnosis begins automatically when the evidence window is complete.",
            revert: "No setting change is recommended yet.",
            statistics: stats ?? SamplePipeline.statistics(for: samples)
        )
    }
}

public struct ExperimentTracker: Sendable {
    private var baseline: FrameStatistics?
    private var validationStartNanoseconds: UInt64?

    public init() {}

    public mutating func begin(baselineSamples: [FrameSample], nowNanoseconds: UInt64) -> Bool {
        guard let statistics = SamplePipeline.statistics(for: baselineSamples), statistics.sampleCount >= 10 else {
            return false
        }
        baseline = statistics
        validationStartNanoseconds = nowNanoseconds
        return true
    }

    public mutating func comparison(validationSamples: [FrameSample], minimumDurationSeconds: TimeInterval = 30) -> ExperimentComparison? {
        guard let baseline, let validationStartNanoseconds,
              let stats = SamplePipeline.statistics(for: validationSamples),
              stats.sampleCount >= 15,
              stats.durationSeconds >= minimumDurationSeconds else { return nil }
        guard validationSamples.allSatisfy({ $0.monotonicNanoseconds >= validationStartNanoseconds }) else { return nil }
        let change = stats.medianMilliseconds - baseline.medianMilliseconds
        let changePercent = change / max(baseline.medianMilliseconds, 0.1) * 100
        return ExperimentComparison(
            baselineMedianMilliseconds: baseline.medianMilliseconds,
            validationMedianMilliseconds: stats.medianMilliseconds,
            changeMilliseconds: change,
            changePercent: changePercent,
            improved: change <= -2 || changePercent <= -8,
            baselineSamples: baseline.sampleCount,
            validationSamples: stats.sampleCount
        )
    }

    public var isActive: Bool { baseline != nil && validationStartNanoseconds != nil }
    public var startedAtNanoseconds: UInt64? { validationStartNanoseconds }

    public mutating func reset() {
        baseline = nil
        validationStartNanoseconds = nil
    }
}
