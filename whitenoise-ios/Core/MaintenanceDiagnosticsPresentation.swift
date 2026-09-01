import Foundation
import MarmotKit

nonisolated enum MaintenanceDiagnosticsPresentation {
    static func phaseLabel(_ phase: MaintenancePhaseFfi) -> String {
        switch phase {
        case .catchUp: "Catch-up"
        case .eoseTimeout: "EOSE timeout"
        case .grace: "Grace"
        case .quiet: "Quiet"
        case .jitter: "Jitter"
        case .overdue: "Overdue"
        case .paused: "Paused"
        case .clockSkewBlocked: "Clock skew blocked"
        case .pendingPublication: "Pending publication"
        case .fanout: "Fanout"
        case .retry: "Retry"
        case .supersededByConvergence: "Superseded by convergence"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }

    static func triggerLabel(_ trigger: MaintenanceTriggerFfi) -> String {
        switch trigger {
        case .postJoin: "Post-join"
        case .periodic: "Periodic"
        case .manual: "Manual"
        }
    }

    static func evolutionPhaseLabel(_ phase: GroupEvolutionPhaseFfi) -> String {
        switch phase {
        case .preparing: "Preparing"
        case .prepared: "Prepared"
        case .attempting: "Attempting"
        case .confirmed: "Confirmed"
        case .supersededByConvergence: "Superseded by convergence"
        }
    }

    static func failureCode(_ raw: String?) -> String? {
        ContentSanitizer.compactSingleLine(raw, maxLength: 120)
    }

    static func date(_ timestamp: UInt64?) -> Date? {
        guard let timestamp else { return nil }
        let seconds = min(TimeInterval(timestamp), Date.distantFuture.timeIntervalSince1970)
        return Date(timeIntervalSince1970: seconds)
    }
}
