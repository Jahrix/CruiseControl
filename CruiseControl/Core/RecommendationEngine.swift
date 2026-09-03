import Foundation

public struct OptimizationRecommendation: Equatable, Sendable {
    public enum VisualImpact: String, Equatable, Sendable { case none, low, medium, high }
    public enum PerformanceDirection: String, Equatable, Sendable { case likelyImproves, validateOnly }

    public let id: String
    public let title: String
    public let reason: String
    public let evidence: String
    public let confidence: DiagnosticConfidence
    public let visualImpact: VisualImpact
    public let performanceDirection: PerformanceDirection
    public let restartRequired: Bool
    public let canApplySafely: Bool
}

public struct RecommendationEngine: Sendable {
    public init() {}

    public func recommend(diagnosis: DiagnosticResult, flightContext: FlightContext, telemetryIsFresh: Bool) -> OptimizationRecommendation {
        guard telemetryIsFresh, diagnosis.bottleneck != .insufficientEvidence else {
            return unavailable(diagnosis)
        }
        let context = flightContext.nearestAirportICAO.map { " at \($0)" } ?? ""
        switch diagnosis.bottleneck {
        case .simulatorMainThread:
            return recommendation("world-objects", "Reduce World Objects one step", "X-Plane’s CPU frame work is leading the frame time\(context).", diagnosis, .medium, .likelyImproves, false)
        case .gpu:
            return recommendation("anti-aliasing", "Reduce anti-aliasing one step", "GPU frame work is leading the frame time\(context).", diagnosis, .medium, .likelyImproves, false)
        case .cpu:
            return recommendation("background-app", "Close one unnecessary background app", "Mac CPU pressure is elevated while X-Plane frame time is high.", diagnosis, .none, .likelyImproves, false)
        case .instability:
            return recommendation("frame-pacing", "Close one unnecessary background app", "Frame pacing has recurring slow spikes rather than a steady limiter.", diagnosis, .none, .likelyImproves, false)
        case .synchronizationCap:
            return recommendation("vsync-cap", "Check the X-Plane FPS cap or V-Sync setting", "The frame rate appears consistently capped with timing headroom.", diagnosis, .none, .validateOnly, false)
        case .insufficientEvidence:
            return unavailable(diagnosis)
        }
    }

    private func recommendation(_ id: String, _ title: String, _ reason: String, _ diagnosis: DiagnosticResult, _ impact: OptimizationRecommendation.VisualImpact, _ direction: OptimizationRecommendation.PerformanceDirection, _ restart: Bool) -> OptimizationRecommendation {
        .init(id: id, title: title, reason: reason, evidence: diagnosis.evidence, confidence: diagnosis.confidence, visualImpact: impact, performanceDirection: direction, restartRequired: restart, canApplySafely: false)
    }

    private func unavailable(_ diagnosis: DiagnosticResult) -> OptimizationRecommendation {
        .init(id: "collect-evidence", title: "No action needed yet", reason: diagnosis.recommendation, evidence: diagnosis.evidence, confidence: .low, visualImpact: .none, performanceDirection: .validateOnly, restartRequired: false, canApplySafely: false)
    }
}
