import Foundation

/// Input acceptance and consumption are separate from transport health and reply delivery.
public enum AgentMessageReceipt: String, Sendable {
    case delivered, read

    public static func resolve(runs: [AgentRun], messageState: String? = nil, serverConfirmed: Bool = false) -> Self? {
        guard messageState != "not_applied", !runs.contains(where: { $0.deliveryState == "not_applied" || $0.status == "not_applied" }),
              serverConfirmed || !runs.isEmpty else { return nil }
        if messageState == "applied" { return .read }
        if runs.contains(where: { run in
            // Steering may own a generation before the agent consumes the input.
            if let state = run.deliveryState {
                if state == "applied" { return true }
                if ["pending", "steering"].contains(state) { return false }
            }
            if let messageState, ["pending", "steering"].contains(messageState) { return false }
            // A normal admission receives its generation only when claimed. This survives
            // a terminal/unknown status and reconnect, unlike a UI-local 'was read' flag.
            return run.executionGeneration != nil ||
                ["running", "waiting_for_approval", "waiting_for_input", "waiting_for_computer", "stopping", "completed"].contains(run.status)
        }) { return .read }
        return .delivered
    }
}
