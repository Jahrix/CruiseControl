import Foundation

enum AssistedPlanActionKind: Equatable {
    case manual
    case setting(SafeSettingsWriteRequest)
}

struct AssistedPlanAction: Identifiable, Equatable {
    let id: String
    let title: String
    let reason: String
    let kind: AssistedPlanActionKind
    let restartRequired: Bool
}

struct AssistedOptimizationPlan: Equatable {
    let recommendationID: String
    let evidence: String
    let actions: [AssistedPlanAction]
}

enum AssistedPlanActionOutcome: String, Equatable {
    case applied
    case manualActionRequired
    case queuedForRestart
    case failed
    case skipped
}

struct AssistedPlanActionReceipt: Identifiable, Equatable {
    let id: UUID
    let actionID: String
    let outcome: AssistedPlanActionOutcome
    let settingReceipt: SafeSettingsReceipt?
    let message: String
}

enum AssistedPlanStatus: Equatable {
    case cancelled
    case completed
}

struct AssistedPlanExecutionResult: Equatable {
    let status: AssistedPlanStatus
    let receipts: [AssistedPlanActionReceipt]
}

/// Produces a reviewable plan from the existing diagnosis recommendation.
/// A recommendation without a verified capability remains an explicit manual
/// step rather than being mapped to an inferred X-Plane setting.
enum AssistedOptimizationPlanEngine {
    static func makePlan(for recommendation: OptimizationRecommendation) -> AssistedOptimizationPlan {
        AssistedOptimizationPlan(
            recommendationID: recommendation.id,
            evidence: recommendation.evidence,
            actions: [
                AssistedPlanAction(
                    id: recommendation.id,
                    title: recommendation.title,
                    reason: recommendation.reason,
                    kind: .manual,
                    restartRequired: recommendation.restartRequired
                )
            ]
        )
    }
}

/// Executes only selected, already-approved actions. A setting action still
/// passes through SafeSettingsWriteGateway; manual actions never reach a
/// bridge or a preference file.
struct AssistedOptimizationPlanExecutor {
    func execute(
        plan: AssistedOptimizationPlan,
        approvedActionIDs: Set<String>,
        runtime: SafeSettingsRuntime,
        writer: SafeSettingsWriter?,
        now: Date = Date()
    ) -> AssistedPlanExecutionResult {
        guard !approvedActionIDs.isEmpty else {
            return AssistedPlanExecutionResult(status: .cancelled, receipts: [])
        }

        let receipts = plan.actions.map { action in
            guard approvedActionIDs.contains(action.id) else {
                return receipt(action, outcome: .skipped, message: "Not approved.")
            }
            if action.restartRequired {
                return receipt(action, outcome: .queuedForRestart, message: "Approved and queued for a separate restart confirmation.")
            }

            switch action.kind {
            case .manual:
                return receipt(action, outcome: .manualActionRequired, message: "Approved for a manual change; CruiseControl did not alter X-Plane.")
            case let .setting(request):
                guard let writer else {
                    return receipt(action, outcome: .failed, message: "No verified writer is available for this action.")
                }
                let settingReceipt = SafeSettingsWriteGateway().execute(request, runtime: runtime, writer: writer, now: now)
                return AssistedPlanActionReceipt(
                    id: UUID(),
                    actionID: action.id,
                    outcome: settingReceipt.outcome == .applied ? .applied : .failed,
                    settingReceipt: settingReceipt,
                    message: settingReceipt.message
                )
            }
        }

        return AssistedPlanExecutionResult(status: .completed, receipts: receipts)
    }

    private func receipt(_ action: AssistedPlanAction, outcome: AssistedPlanActionOutcome, message: String) -> AssistedPlanActionReceipt {
        AssistedPlanActionReceipt(id: UUID(), actionID: action.id, outcome: outcome, settingReceipt: nil, message: message)
    }
}
