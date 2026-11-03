import Foundation

public struct AgentCapabilities: Codable, Sendable {
    public let features: Features

    // The upstream features object also contains strings and nested contracts.
    // Decode only the switches this client consumes; never coerce metadata to Bool.
    public struct Features: Codable, Sendable {
        public let runSubmission: Bool?
        public let runStatus: Bool?
        public let runStop: Bool?
        public let sessionResources: Bool?
        public let runsIdempotency: Idempotency?

        public struct Idempotency: Codable, Sendable, Equatable {
            public let supported: Bool?
            public let durable: Bool?
            public let retentionSeconds: Int?
            enum CodingKeys: String, CodingKey {
                case supported, durable
                case retentionSeconds = "retention_seconds"
            }
        }

        enum CodingKeys: String, CodingKey {
            case runSubmission = "run_submission"
            case runStatus = "run_status"
            case runStop = "run_stop"
            case sessionResources = "session_resources"
            case runsIdempotency = "runs_idempotency"
        }
    }
}

public struct AgentRun: Codable, Sendable, Equatable {
    public let runID: String
    public let sessionID: String?
    public let status: String
    public let output: String?
    public let error: String?
    public var admissionID: String? = nil
    public var executionGeneration: Int? = nil
    public var pendingControls: [AgentControl]? = nil

    public var workID: String? = nil
    public var title: String? = nil
    public var originRunID: String? = nil
    public var executionSessionID: String? = nil
    public var waitReason: String? = nil
    public var blockingWorkID: String? = nil
    public var cancellable: Bool? = nil
    public var cancelRequested: Bool? = nil
    public var deliveryState: String? = nil
    public var createdAt: Double? = nil

    // Unknown outcomes need reconciliation; they are never successful completion.
    public var isTerminal: Bool {
        ["completed", "failed", "cancelled", "interrupted", "not_applied"].contains(status)
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case sessionID = "session_id"
        case status, output, error
        case workID = "work_id", title, originRunID = "origin_run_id", executionSessionID = "execution_session_id"
        case waitReason = "wait_reason", cancellable, cancelRequested = "cancel_requested", deliveryState = "delivery_state"
        case createdAt = "created_at"
        case blockingWorkID = "blocking_work_id"
        case admissionID = "admission_id", executionGeneration = "execution_generation", pendingControls = "pending_controls"
    }
}

public enum AgentClientError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidCredential
    case invalidInput
    case invalidResponse
    case responseTooLarge
    case http(status: Int, code: String?, message: String?, retryAfter: TimeInterval? = nil)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "连接地址无效，请重新扫码配对。自建服务器需使用 HTTPS。"
        case .invalidCredential: "An API credential is required."
        case .invalidInput: "A nonempty input and session identity are required."
        case .invalidResponse: "The Agent did not return an HTTP response."
        case .responseTooLarge: "The response exceeds the 8 MiB data channel limit. Use a paginated read."
        case let .http(status, code, message, _):
            "Agent HTTP \(status)\(code.map { " (\($0))" } ?? ""): \(message ?? "Request was refused")"
        }
    }
}
