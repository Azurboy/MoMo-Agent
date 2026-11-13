import Foundation

struct ConversationSnapshot: Decodable, Sendable {
    let conversationID: String
    let cursor: Int
    let messages: ConversationPage
    let runs: [AgentRun]
    let backgroundWork: [ConversationWork]
    let messageStates: [String: String]
    let providerNotice: ProviderServiceNotice?
    enum CodingKeys: String, CodingKey {
        case cursor, messages, runs
        case conversationID = "conversation_id", backgroundWork = "background_work", messageStates = "message_states"
        case providerNotice = "provider_notice"
    }
}

struct ConversationEvent: Decodable, Sendable {
    let conversationID: String
    let cursor: Int?
    let kind: String
    let message: ConversationMessage?
    let run: AgentRun?
    let runEvent: AgentRunEvent?
    let backgroundWork: [ConversationWork]?
    let messageStates: [String: String]?
    let providerNotice: ProviderServiceNotice?
    enum CodingKeys: String, CodingKey {
        case cursor, kind, message, run
        case conversationID = "conversation_id", runEvent = "run_event"
        case backgroundWork = "background_work", messageStates = "message_states"
        case providerNotice = "provider_notice"
    }
}

extension AgentClient {
    func conversationSnapshot() async throws -> ConversationSnapshot {
        try JSONDecoder().decode(ConversationSnapshot.self, from: await request(path: ["momo", "v1", "conversation", "snapshot"]))
    }
}

/// One foreground subscription for the conversation, regardless of its number of runs.
@MainActor final class ConversationSubscription {
    private var worker: Task<Void, Never>?
    private(set) var isRunning = true
    private(set) var isBackingOff = false
    init(client: AgentClient, cursor: @escaping @MainActor () -> Int?,
         snapshot: @escaping @MainActor (ConversationSnapshot) throws -> Void,
         event: @escaping @MainActor (ConversationEvent) throws -> Void,
         failed: @escaping @MainActor (Error) -> Void) {
        worker = Task { [weak self] in
            defer { self?.isRunning = false }
            var backoff: TimeInterval = 0.25
            var needsSnapshot = cursor() == nil
            while !Task.isCancelled {
                self?.isBackingOff = false
                var failure: Error?
                var attemptedStream = false
                do {
                    if needsSnapshot {
                        let value = try await client.conversationSnapshot()
                        try Task.checkCancellation(); try snapshot(value); needsSnapshot = false
                    }
                    guard let after = cursor() else { throw RemoteTaskStore.StoreError.invalidResponse }
                    attemptedStream = true
                    for try await value in try client.conversationEvents(after: after) {
                        try Task.checkCancellation(); try event(value)
                        if value.kind != "ready" { backoff = 0.25 }
                    }
                    failure = URLError(.networkConnectionLost)
                } catch { failure = error }
                guard !Task.isCancelled, var failure else { return }
                var snapshotRecovered = false
                if attemptedStream && Self.canUseSnapshot(after: failure) {
                    // Losing the stream alone does not establish whether the Mac is reachable.
                    do {
                        let value = try await client.conversationSnapshot()
                        try Task.checkCancellation()
                        try snapshot(value)
                        snapshotRecovered = true
                    } catch {
                        guard !Task.isCancelled else { return }
                        failure = error
                    }
                }
                if !snapshotRecovered { failed(failure) }
                var delay = backoff
                if case AgentClientError.http(let status, _, _, let retryAfter) = failure {
                    if status == 409 { needsSnapshot = true }
                    else if (400..<500).contains(status) && ![408, 429].contains(status) { return }
                    delay = max(delay, retryAfter ?? 0)
                } else if case AgentClientError.responseTooLarge = failure {
                    // A slow consumer resumes from its applied cursor after bounded overflow.
                } else if case AgentClientError.invalidResponse = failure {
                    // Transient proxy/tunnel HTML responses retry with backoff instead of locking out SSE.
                } else if !AgentTransportFailure.isTransient(failure) { return }
                self?.isBackingOff = true
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                backoff = min(5, backoff * 2)
            }
        }
    }
    private static func canUseSnapshot(after error: Error) -> Bool {
        if case AgentClientError.http(let status, _, _, let retryAfter) = error {
            return retryAfter == nil && [408, 500, 502, 503, 504].contains(status)
        }
        if case AgentClientError.invalidResponse = error { return true }
        return AgentTransportFailure.isSocketOrLinkFailure(error)
    }

    func stop() { worker?.cancel(); worker = nil; isRunning = false }
    deinit { worker?.cancel() }
}
