import Foundation

struct GovernorEvaluationResult {
    var decision: GovernorDecision?
    var statusLine: String
    var currentTier: GovernorTier?
    var currentTargetLOD: Double?
    var smoothedLOD: Double?
    var activeAGLFeet: Double?
    var lastSentLOD: Double?
    var commandStatus: String
    var ackState: GovernorAckState
    var lastCommand: String?
    var lastACK: String?
    var lastACKDate: Date?
    var pauseReason: String?
    var reasons: [String]
    var rampInProgress: Bool
}
