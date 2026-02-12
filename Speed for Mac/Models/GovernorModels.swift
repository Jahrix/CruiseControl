import Foundation

enum GovernorTier: String, Codable, CaseIterable {
    case ground = "GROUND"
    case climbDescent = "CLIMB/DESCENT"
    case cruise = "CRUISE"
}

enum AltitudeResolutionSource: String, Codable {
    case aglTelemetry
    case mslHeuristic
    case unavailable
}

struct GovernorPolicyConfig: Codable {
    var enabled: Bool
    var groundMaxAGLFeet: Double
    var cruiseMinAGLFeet: Double
    var targetLODGround: Double
    var targetLODClimbDescent: Double
    var targetLODCruise: Double
    var clampMinLOD: Double
    var clampMaxLOD: Double
    var commandHost: String
    var commandPort: Int

    static let `default` = GovernorPolicyConfig(
        enabled: false,
        groundMaxAGLFeet: 1_500,
        cruiseMinAGLFeet: 10_000,
        targetLODGround: 1.45,
        targetLODClimbDescent: 1.15,
        targetLODCruise: 0.95,
        clampMinLOD: 0.75,
        clampMaxLOD: 1.80,
        commandHost: "127.0.0.1",
        commandPort: 49_006
    )
}

struct GovernorDecision: Codable {
    var tier: GovernorTier
    var resolvedAGLFeet: Double
    var resolvedAltitudeSource: AltitudeResolutionSource
    var targetLOD: Double
    var thresholdsText: String

    var statusLine: String {
        "Governor: \(tier.rawValue) | Thresholds: \(thresholdsText) | Current LOD target: \(String(format: "%.2f", targetLOD))"
    }
}

enum GovernorPolicyEngine {
    static func selectTier(
        aglFeet: Double,
        groundMaxAGLFeet: Double,
        cruiseMinAGLFeet: Double
    ) -> GovernorTier {
        if aglFeet < groundMaxAGLFeet {
            return .ground
        }
        if aglFeet < cruiseMinAGLFeet {
            return .climbDescent
        }
        return .cruise
    }

    static func resolveAGL(telemetry: SimTelemetrySnapshot) -> (feet: Double?, source: AltitudeResolutionSource) {
        if let agl = telemetry.altitudeAGLFeet, agl >= 0 {
            return (agl, .aglTelemetry)
        }

        if let msl = telemetry.altitudeMSLFeet, msl >= 0 {
            // Simple fallback heuristic when AGL isn't directly available.
            return (max(msl - 1_000, 0), .mslHeuristic)
        }

        return (nil, .unavailable)
    }

    static func decide(telemetry: SimTelemetrySnapshot?, config: GovernorPolicyConfig) -> GovernorDecision? {
        guard config.enabled, let telemetry else { return nil }

        let clampedGroundMax = max(config.groundMaxAGLFeet, 100)
        let clampedCruiseMin = max(config.cruiseMinAGLFeet, clampedGroundMax + 100)

        let resolved = resolveAGL(telemetry: telemetry)
        guard let aglFeet = resolved.feet else { return nil }

        let tier = selectTier(
            aglFeet: aglFeet,
            groundMaxAGLFeet: clampedGroundMax,
            cruiseMinAGLFeet: clampedCruiseMin
        )

        let unclampedTarget: Double
        switch tier {
        case .ground:
            unclampedTarget = config.targetLODGround
        case .climbDescent:
            unclampedTarget = config.targetLODClimbDescent
        case .cruise:
            unclampedTarget = config.targetLODCruise
        }

        let minClamp = min(config.clampMinLOD, config.clampMaxLOD)
        let maxClamp = max(config.clampMinLOD, config.clampMaxLOD)
        let target = min(max(unclampedTarget, minClamp), maxClamp)

        return GovernorDecision(
            tier: tier,
            resolvedAGLFeet: aglFeet,
            resolvedAltitudeSource: resolved.source,
            targetLOD: target,
            thresholdsText: String(format: "< %.0fft ground, %.0f-%.0fft climb/descent, > %.0fft cruise", clampedGroundMax, clampedGroundMax, clampedCruiseMin, clampedCruiseMin)
        )
    }
}
