import Foundation

enum AdaptiveLODPhase: String, Codable, CaseIterable, Equatable {
    case ground
    case transition
    case cruise
}

struct AdaptiveLODConfiguration: Equatable {
    var groundTarget: Double
    var transitionTarget: Double
    var cruiseTarget: Double
    var minimumLOD: Double
    var maximumLOD: Double
    var maximumStep: Double
    var groundUpperAGLFeet: Double
    var cruiseLowerAGLFeet: Double
    var phaseHysteresisFeet: Double
    var minimumPhaseDwell: TimeInterval
    var targetFrameTimeMilliseconds: Double
    var degradeThresholdMultiplier: Double
    var restoreThresholdMultiplier: Double
    var degradationDwell: TimeInterval
    var restorationDwell: TimeInterval
    var degradationCooldown: TimeInterval
    var restorationCooldown: TimeInterval
    var minimumPerformanceSamples: Int
    var pendingVerificationTimeout: TimeInterval

    static let `default` = AdaptiveLODConfiguration(
        groundTarget: 1.45,
        transitionTarget: 1.15,
        cruiseTarget: 0.95,
        minimumLOD: 0.20,
        maximumLOD: 3.00,
        maximumStep: 0.05,
        groundUpperAGLFeet: 1_500,
        cruiseLowerAGLFeet: 10_000,
        phaseHysteresisFeet: 300,
        minimumPhaseDwell: 8,
        targetFrameTimeMilliseconds: 40,
        degradeThresholdMultiplier: 1.10,
        restoreThresholdMultiplier: 0.85,
        degradationDwell: 2,
        restorationDwell: 10,
        degradationCooldown: 2,
        restorationCooldown: 10,
        minimumPerformanceSamples: 20,
        pendingVerificationTimeout: 5
    )

    var clampedMinimum: Double { min(minimumLOD, maximumLOD) }
    var clampedMaximum: Double { max(minimumLOD, maximumLOD) }
    var boundedStep: Double { min(max(maximumStep, 0.01), 0.25) }

    func target(for phase: AdaptiveLODPhase) -> Double {
        let raw: Double
        switch phase {
        case .ground: raw = groundTarget
        case .transition: raw = transitionTarget
        case .cruise: raw = cruiseTarget
        }
        return min(max(raw, clampedMinimum), clampedMaximum)
    }
}

struct AdaptiveLODInput: Equatable {
    var now: Date
    var enabled: Bool
    var telemetryIsFresh: Bool
    var bridgeIsFresh: Bool
    var bridgeIsReachable: Bool
    var readbackIsFresh: Bool
    var runtime: SafeSettingsRuntime
    var observedLOD: Double?
    var altitudeAGLFeet: Double?
    var isOnGround: Bool?
    var movingAverageFrameTimeMilliseconds: Double?
    var movingAverageSampleCount: Int
}

enum AdaptiveLODDecision: Equatable {
    case hold(reason: String)
    case request(target: Double, reason: String, evidenceAge: TimeInterval)
    case restore(target: Double, reason: String, evidenceAge: TimeInterval)
}

struct AdaptiveLODState: Equatable {
    var phase: AdaptiveLODPhase?
    var phaseEnteredAt: Date?
    var originalLOD: Double?
    var pendingTarget: Double?
    var pendingSince: Date?
    var degradationSince: Date?
    var restorationSince: Date?
    var lastAdjustmentAt: Date?

    static let idle = AdaptiveLODState(
        phase: nil,
        phaseEnteredAt: nil,
        originalLOD: nil,
        pendingTarget: nil,
        pendingSince: nil,
        degradationSince: nil,
        restorationSince: nil,
        lastAdjustmentAt: nil
    )
}

struct AdaptiveLODStep: Equatable {
    var state: AdaptiveLODState
    var decision: AdaptiveLODDecision
}

/// Pure bounded-control logic for Adaptive LOD. It performs no bridge I/O;
/// callers must route any request through SafeSettingsWriteGateway and supply
/// later readback to clear a pending adjustment.
enum AdaptiveLODController {
    static func step(
        input: AdaptiveLODInput,
        state initialState: AdaptiveLODState,
        configuration: AdaptiveLODConfiguration
    ) -> AdaptiveLODStep {
        var state = initialState

        if !input.enabled {
            return restoreOrHold(input: input, state: state, reason: "Adaptive LOD disabled", configuration: configuration)
        }

        guard input.telemetryIsFresh else { return hold(state, "Telemetry is stale.") }
        guard input.bridgeIsFresh, input.bridgeIsReachable else { return hold(state, "Bridge status is unavailable or stale.") }
        guard input.readbackIsFresh else { return hold(state, "LOD readback is unavailable or stale.") }
        guard input.runtime.simulatorVersion != .unknown else { return hold(state, "Simulator version is unknown.") }
        guard input.runtime.writableSettings.contains(.lodBias) else { return hold(state, "LOD writability has not been verified.") }
        guard let observedLOD = normalized(input.observedLOD), let phaseCandidate = phase(for: input, previous: state.phase, configuration: configuration) else {
            return hold(state, "Authoritative flight phase or current LOD is unavailable.")
        }
        guard let averageFrameTime = input.movingAverageFrameTimeMilliseconds,
              averageFrameTime.isFinite,
              input.movingAverageSampleCount >= configuration.minimumPerformanceSamples else {
            return hold(state, "Insufficient moving-average performance evidence.")
        }

        if state.originalLOD == nil { state.originalLOD = observedLOD }

        if let pending = state.pendingTarget, let pendingSince = state.pendingSince {
            if abs(observedLOD - pending) <= 0.01 {
                state.pendingTarget = nil
                state.pendingSince = nil
            } else if input.now.timeIntervalSince(pendingSince) > configuration.pendingVerificationTimeout {
                state.pendingTarget = nil
                state.pendingSince = nil
                return hold(state, "LOD write verification timed out; no further adjustment was made.")
            } else {
                return hold(state, "Waiting for verified LOD readback.")
            }
        }

        updatePhase(&state, candidate: phaseCandidate, now: input.now, configuration: configuration)
        guard let phase = state.phase else { return hold(state, "Authoritative flight phase is unavailable.") }
        guard phaseCandidate == phase || phaseHasDwelled(state: state, now: input.now, configuration: configuration) else {
            return hold(state, "Waiting for flight-phase dwell.")
        }

        let baseTarget = configuration.target(for: phase)
        let degradeThreshold = configuration.targetFrameTimeMilliseconds * configuration.degradeThresholdMultiplier
        let restoreThreshold = configuration.targetFrameTimeMilliseconds * configuration.restoreThresholdMultiplier
        let desired: Double
        let direction: AdjustmentDirection
        if averageFrameTime >= degradeThreshold {
            state.degradationSince = state.degradationSince ?? input.now
            state.restorationSince = nil
            guard hasDwelled(state.degradationSince, now: input.now, duration: configuration.degradationDwell) else {
                return hold(state, "Waiting for sustained performance pressure.")
            }
            desired = configuration.clampedMaximum
            direction = .degrade
        } else if averageFrameTime <= restoreThreshold, observedLOD > baseTarget + 0.01 {
            state.restorationSince = state.restorationSince ?? input.now
            state.degradationSince = nil
            guard hasDwelled(state.restorationSince, now: input.now, duration: configuration.restorationDwell) else {
                return hold(state, "Waiting for sustained performance recovery.")
            }
            desired = baseTarget
            direction = .restore
        } else {
            state.degradationSince = nil
            state.restorationSince = nil
            if abs(observedLOD - baseTarget) <= 0.01 { return hold(state, "LOD is on the phase target.") }
            desired = baseTarget
            direction = desired > observedLOD ? .degrade : .restore
        }

        let cooldown = direction == .degrade ? configuration.degradationCooldown : configuration.restorationCooldown
        if let lastAdjustmentAt = state.lastAdjustmentAt,
           input.now.timeIntervalSince(lastAdjustmentAt) < cooldown {
            return hold(state, "Adjustment cooldown is active.")
        }

        let delta = min(abs(desired - observedLOD), configuration.boundedStep)
        guard delta >= 0.01 else { return hold(state, "LOD is within adjustment tolerance.") }
        let requested = min(max(observedLOD + (desired > observedLOD ? delta : -delta), configuration.clampedMinimum), configuration.clampedMaximum)
        state.pendingTarget = requested
        state.pendingSince = input.now
        state.lastAdjustmentAt = input.now
        let reason = direction == .degrade ? "Sustained frame-time pressure" : "Sustained frame-time recovery"
        return AdaptiveLODStep(state: state, decision: .request(target: requested, reason: reason, evidenceAge: 0))
    }

    static func markRestored(_ state: AdaptiveLODState) -> AdaptiveLODState {
        .idle
    }

    private enum AdjustmentDirection { case degrade, restore }

    private static func restoreOrHold(input: AdaptiveLODInput, state: AdaptiveLODState, reason: String, configuration: AdaptiveLODConfiguration) -> AdaptiveLODStep {
        guard let original = state.originalLOD else { return hold(.idle, reason) }
        guard input.bridgeIsFresh, input.bridgeIsReachable, input.readbackIsFresh,
              input.runtime.simulatorVersion != .unknown,
              input.runtime.writableSettings.contains(.lodBias),
              normalized(input.observedLOD) != nil else {
            return hold(state, "\(reason); original LOD restoration could not be verified.")
        }
        return AdaptiveLODStep(state: state, decision: .restore(target: min(max(original, configuration.clampedMinimum), configuration.clampedMaximum), reason: reason, evidenceAge: 0))
    }

    private static func hold(_ state: AdaptiveLODState, _ reason: String) -> AdaptiveLODStep {
        AdaptiveLODStep(state: state, decision: .hold(reason: reason))
    }

    private static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func phase(for input: AdaptiveLODInput, previous: AdaptiveLODPhase?, configuration: AdaptiveLODConfiguration) -> AdaptiveLODPhase? {
        if input.isOnGround == true { return .ground }
        guard let agl = normalized(input.altitudeAGLFeet), agl >= 0 else { return nil }
        let lower = configuration.groundUpperAGLFeet
        let upper = max(configuration.cruiseLowerAGLFeet, lower + configuration.phaseHysteresisFeet * 2)
        let hysteresis = max(configuration.phaseHysteresisFeet, 0)

        switch previous {
        case .ground:
            return agl <= lower + hysteresis ? .ground : (agl >= upper + hysteresis ? .cruise : .transition)
        case .transition:
            if agl <= lower - hysteresis { return .ground }
            if agl >= upper + hysteresis { return .cruise }
            return .transition
        case .cruise:
            return agl >= upper - hysteresis ? .cruise : (agl <= lower - hysteresis ? .ground : .transition)
        case nil:
            if agl < lower { return .ground }
            if agl > upper { return .cruise }
            return .transition
        }
    }

    private static func updatePhase(_ state: inout AdaptiveLODState, candidate: AdaptiveLODPhase, now: Date, configuration: AdaptiveLODConfiguration) {
        guard let current = state.phase else {
            state.phase = candidate
            state.phaseEnteredAt = now
            return
        }
        guard current != candidate else { return }
        guard hasDwelled(state.phaseEnteredAt, now: now, duration: configuration.minimumPhaseDwell) else { return }
        state.phase = candidate
        state.phaseEnteredAt = now
    }

    private static func phaseHasDwelled(state: AdaptiveLODState, now: Date, configuration: AdaptiveLODConfiguration) -> Bool {
        hasDwelled(state.phaseEnteredAt, now: now, duration: configuration.minimumPhaseDwell)
    }

    private static func hasDwelled(_ since: Date?, now: Date, duration: TimeInterval) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= max(duration, 0)
    }
}

struct AdaptiveLODAdjustmentReceipt: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let targetLOD: Double
    let appliedLOD: Double?
    let evidenceAge: TimeInterval
    let reason: String
    let succeeded: Bool
    let safeSettingsReceipt: SafeSettingsReceipt?
}
