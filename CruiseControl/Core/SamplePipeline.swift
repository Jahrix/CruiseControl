import Foundation

public struct SamplePipeline: Sendable {
    public let capacity: Int
    public let staleAfterNanoseconds: UInt64
    private(set) public var samples: [FrameSample] = []
    private(set) public var rejectedInvalidCount = 0
    private(set) public var rejectedReorderedCount = 0
    private var lastSourceSequence: UInt64?

    public init(capacity: Int = 1_800, staleAfterSeconds: TimeInterval = 4) {
        self.capacity = max(capacity, 1)
        staleAfterNanoseconds = UInt64(max(staleAfterSeconds, 0.1) * 1_000_000_000)
    }

    @discardableResult
    public mutating func append(_ sample: FrameSample) -> SampleRejection? {
        guard sample.isValid else {
            rejectedInvalidCount += 1
            return .invalid
        }

        if let last = samples.last, sample.monotonicNanoseconds <= last.monotonicNanoseconds {
            rejectedReorderedCount += 1
            return .reordered
        }
        if let sequence = sample.sourceSequence,
           let lastSourceSequence,
           sequence <= lastSourceSequence {
            rejectedReorderedCount += 1
            return .reordered
        }

        samples.append(sample)
        if let sequence = sample.sourceSequence {
            lastSourceSequence = sequence
        }
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        return nil
    }

    public func isStale(nowNanoseconds: UInt64) -> Bool {
        guard let last = samples.last else { return true }
        guard nowNanoseconds >= last.monotonicNanoseconds else { return false }
        return nowNanoseconds - last.monotonicNanoseconds > staleAfterNanoseconds
    }

    public func samples(inLast seconds: TimeInterval, nowNanoseconds: UInt64) -> [FrameSample] {
        let duration = UInt64(max(seconds, 0) * 1_000_000_000)
        let cutoff = nowNanoseconds > duration ? nowNanoseconds - duration : 0
        return samples.filter { $0.monotonicNanoseconds >= cutoff && $0.monotonicNanoseconds <= nowNanoseconds }
    }

    public func statistics(inLast seconds: TimeInterval, nowNanoseconds: UInt64) -> FrameStatistics? {
        Self.statistics(for: samples(inLast: seconds, nowNanoseconds: nowNanoseconds))
    }

    public static func statistics(for samples: [FrameSample]) -> FrameStatistics? {
        guard let first = samples.first, let last = samples.last, !samples.isEmpty else { return nil }
        let values = samples.map(\.frameTimeMilliseconds).sorted()
        let median = percentile(values, fraction: 0.5)
        let deviations = values.map { abs($0 - median) }.sorted()
        let variance = values.reduce(0) { $0 + pow($1 - median, 2) } / Double(values.count)
        let spikeThreshold = max(median * 1.5, median + 8)
        let spikes = values.filter { $0 >= spikeThreshold }.count
        let cpuValues = samples.compactMap(\.simulatorCPUTimeMilliseconds).sorted()
        let gpuValues = samples.compactMap(\.gpuTimeMilliseconds).sorted()
        let hostCPUValues = samples.compactMap(\.hostCPUPercent).sorted()
        let duration: TimeInterval
        if last.monotonicNanoseconds >= first.monotonicNanoseconds {
            duration = Double(last.monotonicNanoseconds - first.monotonicNanoseconds) / 1_000_000_000
        } else {
            duration = 0
        }

        return FrameStatistics(
            sampleCount: samples.count,
            windowStart: first.capturedAt,
            windowEnd: last.capturedAt,
            durationSeconds: duration,
            medianMilliseconds: median,
            p95Milliseconds: values.count >= 20 ? percentile(values, fraction: 0.95) : nil,
            p99Milliseconds: values.count >= 100 ? percentile(values, fraction: 0.99) : nil,
            medianAbsoluteDeviationMilliseconds: percentile(deviations, fraction: 0.5),
            varianceMillisecondsSquared: variance,
            spikeCount: spikes,
            spikeFrequency: Double(spikes) / Double(values.count),
            medianFPS: percentile(samples.map(\.fps).sorted(), fraction: 0.5),
            medianSimulatorCPUTimeMilliseconds: cpuValues.isEmpty ? nil : percentile(cpuValues, fraction: 0.5),
            medianGPUTimeMilliseconds: gpuValues.isEmpty ? nil : percentile(gpuValues, fraction: 0.5),
            medianHostCPUPercent: hostCPUValues.isEmpty ? nil : percentile(hostCPUValues, fraction: 0.5)
        )
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
