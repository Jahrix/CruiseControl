import Foundation

/// Pure protocol/state rules mirrored by the native XPLM plugin. It performs
/// no X-Plane I/O, making all failure paths deterministic to test.
enum XPLMBridgeTransactionState: String, Equatable {
    case unavailable, candidate, verifyingPersistence, verifyingRestoration
    case verifiedIdle, applying, restoring, lockedOut, recoveryRequired
}

struct XPLMBridgeIdentity: Equatable {
    var simulatorBuild: String
    var pluginSessionID: String
}

struct XPLMBridgeTransaction: Equatable {
    var nonce: String
    var sequence: UInt64
    var requested: Double
    var original: Double
    var matchingFrames: Int
    var isVerification: Bool
}

struct XPLMBridgeState: Equatable {
    var identity: XPLMBridgeIdentity
    var state: XPLMBridgeTransactionState
    var verifiedIdentity: XPLMBridgeIdentity?
    var activationOriginal: Double?
    var pending: XPLMBridgeTransaction?
    var lastTerminalNonce: String?
    var lastSequence: UInt64
    var leaseExpiresAt: Date?

    static func unavailable(build: String, session: String) -> XPLMBridgeState {
        XPLMBridgeState(identity: .init(simulatorBuild: build, pluginSessionID: session), state: .unavailable, verifiedIdentity: nil, activationOriginal: nil, pending: nil, lastTerminalNonce: nil, lastSequence: 0, leaseExpiresAt: nil)
    }
}

enum XPLMBridgeEvent: Equatable {
    case rejected(String), accepted, verified, applied, restored, recoveryRequired
}

enum XPLMBridgeProtocol {
    static let range = 0.20...3.00
    static let tolerance = 0.01
    static let requiredFrames = 3

    static func discover(candidate: Bool, state: XPLMBridgeState) -> XPLMBridgeState {
        var result = state
        result.state = candidate ? .candidate : .unavailable
        result.verifiedIdentity = nil
        return result
    }

    static func beginVerification(nonce: String, sequence: UInt64, current: Double?, state: XPLMBridgeState) -> (XPLMBridgeState, XPLMBridgeEvent) {
        guard state.state == .candidate, let current, range.contains(current) else { return (state, .rejected("candidate is not safely verifiable")) }
        guard sequence > state.lastSequence, nonce != state.lastTerminalNonce, state.pending == nil else { return (state, .rejected("nonce or sequence is not new")) }
        let delta = current <= 2.98 ? 0.01 : -0.01
        var result = state
        result.pending = .init(nonce: nonce, sequence: sequence, requested: current + delta, original: current, matchingFrames: 0, isVerification: true)
        result.state = .verifyingPersistence
        return (result, .accepted)
    }

    static func beginWrite(nonce: String, sequence: UInt64, requested: Double, current: Double?, leaseUntil: Date, state: XPLMBridgeState) -> (XPLMBridgeState, XPLMBridgeEvent) {
        guard state.verifiedIdentity == state.identity, state.state == .verifiedIdle, range.contains(requested), let current else { return (state, .rejected("capability is not verified for this session")) }
        guard sequence > state.lastSequence, nonce != state.lastTerminalNonce, state.pending == nil else { return (state, .rejected("nonce or sequence is not new")) }
        var result = state
        result.activationOriginal = result.activationOriginal ?? current
        result.pending = .init(nonce: nonce, sequence: sequence, requested: requested, original: current, matchingFrames: 0, isVerification: false)
        result.leaseExpiresAt = leaseUntil
        result.state = .applying
        return (result, .accepted)
    }

    /// Call once per X-Plane flight-loop frame after the plugin has performed
    /// its requested mutation/readback on that same thread.
    static func observe(_ value: Double?, state: XPLMBridgeState) -> (XPLMBridgeState, XPLMBridgeEvent?) {
        guard var transaction = state.pending else { return (state, nil) }
        var result = state
        let wasRestoring = result.state == .verifyingRestoration || result.state == .restoring
        let expected = wasRestoring ? transaction.original : transaction.requested
        guard let value, abs(value - expected) <= tolerance else {
            result.pending = nil
            result.state = transaction.isVerification ? .lockedOut : .recoveryRequired
            result.lastSequence = transaction.sequence
            result.lastTerminalNonce = transaction.nonce
            return (result, transaction.isVerification ? .rejected("persistence verification failed") : .recoveryRequired)
        }
        transaction.matchingFrames += 1
        result.pending = transaction
        guard transaction.matchingFrames >= requiredFrames else { return (result, nil) }
        transaction.matchingFrames = 0
        result.pending = transaction
        if result.state == .verifyingPersistence {
            result.state = .verifyingRestoration
            return (result, nil)
        }
        result.pending = nil
        result.lastSequence = transaction.sequence
        result.lastTerminalNonce = transaction.nonce
        if result.state == .verifyingRestoration {
            result.verifiedIdentity = result.identity
            result.state = .verifiedIdle
            return (result, .verified)
        }
        result.state = .verifiedIdle
        return (result, wasRestoring ? .restored : .applied)
    }

    static func leaseExpired(now: Date, state: XPLMBridgeState) -> (XPLMBridgeState, XPLMBridgeEvent?) {
        guard let lease = state.leaseExpiresAt, now >= lease, let original = state.activationOriginal, state.pending == nil else { return (state, nil) }
        var result = state
        result.pending = .init(nonce: "lease-expired", sequence: result.lastSequence + 1, requested: original, original: original, matchingFrames: 0, isVerification: false)
        result.state = .restoring
        return (result, .accepted)
    }
}
