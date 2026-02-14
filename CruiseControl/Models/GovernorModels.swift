import Foundation

enum GovernorTier: String, Codable, CaseIterable {
    case ground = "GROUND"
    case transition = "TRANSITION"
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
    var minimumTierHoldSeconds: Double
    var smoothingDurationSeconds: Double
    var minimumCommandIntervalSeconds: Double
    var minimumCommandDelta: Double
    var commandHost: String
    var commandPort: Int
    var useMSLFallbackWhenAGLUnavailable: Bool

    static let `default` = GovernorPolicyConfig(
        enabled: false,
        groundMaxAGLFeet: 1_500,
        cruiseMinAGLFeet: 10_000,
        targetLODGround: 1.45,
        targetLODClimbDescent: 1.15,
        targetLODCruise: 0.95,
        clampMinLOD: 0.20,
        clampMaxLOD: 3.00,
        minimumTierHoldSeconds: 8.0,
        smoothingDurationSeconds: 3.0,
        minimumCommandIntervalSeconds: 0.5,
        minimumCommandDelta: 0.05,
        commandHost: "127.0.0.1",
        commandPort: 49_006,
        useMSLFallbackWhenAGLUnavailable: true
    )

    var clampedGroundMax: Double {
        max(groundMaxAGLFeet, 100)
    }

    var clampedCruiseMin: Double {
        max(cruiseMinAGLFeet, clampedGroundMax + 100)
    }

    var clampedMinLOD: Double {
        min(clampMinLOD, clampMaxLOD)
    }

    var clampedMaxLOD: Double {
        max(clampMinLOD, clampMaxLOD)
    }

    func targetLOD(for tier: GovernorTier) -> Double {
        let rawTarget: Double
        switch tier {
        case .ground:
            rawTarget = targetLODGround
        case .transition:
            rawTarget = targetLODClimbDescent
        case .cruise:
            rawTarget = targetLODCruise
        }

        return min(max(rawTarget, clampedMinLOD), clampedMaxLOD)
    }

    func clampLOD(_ value: Double) -> Double {
        min(max(value, clampedMinLOD), clampedMaxLOD)
    }
}

struct GovernorDecision: Codable {
    var tier: GovernorTier
    var resolvedAGLFeet: Double
    var resolvedAltitudeSource: AltitudeResolutionSource
    var targetLOD: Double
    var thresholdsText: String

    var statusLine: String {
        "Regulator: \(tier.rawValue) | Thresholds: \(thresholdsText) | Current LOD target: \(String(format: "%.2f", targetLOD))"
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
            return .transition
        }
        return .cruise
    }

    static func resolveAGL(telemetry: SimTelemetrySnapshot, useMSLFallbackWhenAGLUnavailable: Bool) -> (feet: Double?, source: AltitudeResolutionSource) {
        if let agl = telemetry.altitudeAGLFeet, agl >= 0 {
            return (agl, .aglTelemetry)
        }

        if useMSLFallbackWhenAGLUnavailable, let msl = telemetry.altitudeMSLFeet, msl >= 0 {
            // Conservative fallback when AGL isn't directly available.
            return (max(msl - 1_000, 0), .mslHeuristic)
        }

        return (nil, .unavailable)
    }

    static func decide(telemetry: SimTelemetrySnapshot?, config: GovernorPolicyConfig) -> GovernorDecision? {
        guard config.enabled, let telemetry else { return nil }

        let resolved = resolveAGL(telemetry: telemetry, useMSLFallbackWhenAGLUnavailable: config.useMSLFallbackWhenAGLUnavailable)
        guard let aglFeet = resolved.feet else { return nil }

        let tier = selectTier(
            aglFeet: aglFeet,
            groundMaxAGLFeet: config.clampedGroundMax,
            cruiseMinAGLFeet: config.clampedCruiseMin
        )

        return GovernorDecision(
            tier: tier,
            resolvedAGLFeet: aglFeet,
            resolvedAltitudeSource: resolved.source,
            targetLOD: config.targetLOD(for: tier),
            thresholdsText: String(
                format: "GROUND < %.0fft, TRANSITION %.0f-%.0fft, CRUISE > %.0fft",
                config.clampedGroundMax,
                config.clampedGroundMax,
                config.clampedCruiseMin,
                config.clampedCruiseMin
            )
        )
    }
}

#if DEBUG
enum GovernorPolicyEngineSelfTests {
    static func run() {
        assert(
            GovernorPolicyEngine.selectTier(aglFeet: 800, groundMaxAGLFeet: 1500, cruiseMinAGLFeet: 10000) == .ground,
            "Tier test failed for low altitude"
        )
        assert(
            GovernorPolicyEngine.selectTier(aglFeet: 5000, groundMaxAGLFeet: 1500, cruiseMinAGLFeet: 10000) == .transition,
            "Tier test failed for transition altitude"
        )
        assert(
            GovernorPolicyEngine.selectTier(aglFeet: 18000, groundMaxAGLFeet: 1500, cruiseMinAGLFeet: 10000) == .cruise,
            "Tier test failed for cruise altitude"
        )
    }
}
#endif
