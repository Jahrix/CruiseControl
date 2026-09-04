import Foundation

/// A bridge status snapshot used to prove the postcondition of one allowlisted
/// LOD write. It intentionally contains no transport or mutation behavior.
struct LODWriteReadback: Equatable {
    var currentLOD: Double?
    var requestID: String?
    var observedAt: Date?
}

enum LODWriteVerificationFailure: Equatable {
    case missingReadback
    case staleReadback
    case readbackMismatch
}

/// Requires a status snapshot that was produced for this exact request after
/// the bridge read the simulator dataref. A matching requested value alone is
/// never sufficient evidence of a successful setting mutation.
enum LODWriteVerification {
    static let maximumReadbackAge: TimeInterval = 5
    static let tolerance = 0.01

    static func failure(
        requestedLOD: Double,
        requestID: String,
        readback: LODWriteReadback,
        now: Date
    ) -> LODWriteVerificationFailure? {
        guard readback.requestID == requestID else {
            return .missingReadback
        }
        guard let observedAt = readback.observedAt,
              now.timeIntervalSince(observedAt) >= 0,
              now.timeIntervalSince(observedAt) <= maximumReadbackAge else {
            return .staleReadback
        }
        guard let observedLOD = readback.currentLOD,
              observedLOD.isFinite,
              abs(observedLOD - requestedLOD) <= tolerance else {
            return .readbackMismatch
        }
        return nil
    }
}
