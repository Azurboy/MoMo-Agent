import Foundation
import Observation

public struct RemoteTask: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let sessionID: String
    public let input: String
    public let createdAt: Date
    public fileprivate(set) var firstAttemptAt: Date?
    public fileprivate(set) var deliveryStartedAt: Date?
    public fileprivate(set) var sourcesPreparedAt: Date?
    public fileprivate(set) var admittedAt: Date?
    public fileprivate(set) var firstTextReceivedAt: Date?
    public fileprivate(set) var firstCommittedTextAt: Date?
    public fileprivate(set) var replayBefore: Date?
    public fileprivate(set) var run: AgentRun?
    public fileprivate(set) var needsReview: Bool = false
    public fileprivate(set) var stopRequested: Bool = false
    public fileprivate(set) var lastError: String?
    public fileprivate(set) var retryableDeliveryError: Bool?
    public fileprivate(set) var lastConfirmedAt: Date?
    public fileprivate(set) var reply: RemoteReply?
    public fileprivate(set) var backgroundMessageIDs: [Int]?
    public fileprivate(set) var replyReceivedAt: [Date]?
    public fileprivate(set) var targetWorkID: String?
    public fileprivate(set) var steeringRecovered: Bool?
    public fileprivate(set) var targetRunID: String?
    public fileprivate(set) var targetGeneration: Int?
    public fileprivate(set) var finishedAt: Date?
    public fileprivate(set) var attachments: [AgentAttachment]? = nil

    public var isFinished: Bool { run?.isTerminal == true }
    public var isPending: Bool { !isFinished && steeringRecovered != true }
    public var deliveryFailed: Bool { steeringRecovered != true && (run == nil || run?.status == "not_applied") && (needsReview || (lastError != nil && retryableDeliveryError != true)) }
    public var isAwaitingReply: Bool {
        guard isPending, !needsReview, !stopRequested, lastError == nil,
              run.map({ ["started", "queued", "running"].contains($0.status) }) ?? true,
              run?.pendingControls?.isEmpty != false, run?.output?.isEmpty != false,
              reply?.messages.isEmpty != false else { return false }
        return true
    }
}

/// Owns durable delivery and snapshots. Window/process lifetime never owns the Mac run.
@MainActor @Observable
public final class RemoteTaskStore {
    public private(set) var tasks: [RemoteTask]
    public private(set) var draft: String
    public private(set) var draftAttachments: [AgentAttachment] = []
    private enum FailureSource { case storage, control, delivery, adoption, discovery, synchronization }
    private var failures: [FailureSource: String] = [:]
    public var failure: String? {
        let sources: [FailureSource] = connectionState == .ready ? [.storage, .control, .delivery, .adoption, .discovery, .synchronization] : [.storage, .control, .delivery]
        return sources.compactMap { failures[$0] }.first
    }
    /// Background reconciliation remains diagnostic state, not a chat banner.
    public var interactionFailure: String? { [FailureSource.storage, .control].compactMap { failures[$0] }.first }
    public enum ConnectionState: Equatable, Sendable { case ready, retrying, authenticationRequired, unavailable }
    public private(set) var connectionState: ConnectionState = .ready
    public private(set) var nextConnectionAttempt: Date?
    @ObservationIgnored public var onAuthenticationRequired: (() -> Void)?
    @ObservationIgnored public var onConnectionRestored: (() -> Void)?
    @ObservationIgnored private var connectionFailures = 0
    @ObservationIgnored private var connectionConfirmation: UInt64 = 0
    @ObservationIgnored private var serverRetryNotBefore: Date?
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private var visibleReadSeq = 0
    public var acknowledgedReadSequence: Int { visibleReadSeq }
    @ObservationIgnored private var pendingReadSeq = 0
    @ObservationIgnored private var sendingReadReceipt = false
    public var canContactServer: Bool { connectionState != .authenticationRequired }
    public var connectionMessage: String? {
        switch connectionState {
        case .ready: nil
        case .retrying: "正在连接 Mac"
        case .authenticationRequired: "配对已失效"
        case .unavailable: "暂时无法同步"
        }
    }

    public private(set) var isRefreshing = false
    public private(set) var conversation: SharedConversation?
    public private(set) var messages: [ConversationMessage] = []
    public private(set) var sharedRuns: [AgentRun] = []
    public private(set) var sharedRunReplies: [String: RemoteReply] = [:]
    public private(set) var backgroundWork: [ConversationWork] = []
    public private(set) var messageCursor = 0
    public private(set) var steeringTarget: AgentRun?
    private var controlsInFlight: Set<String> = []
    private struct Cancellation: Codable { let operationID: UUID; let generation: Int; var targetRunID: String? = nil }
    private var pendingCancellations: [String: Cancellation] = [:]
    private var pendingReports: [String: UUID] = [:]
    private var recoveredSupplements: Set<String> = []
    @ObservationIgnored private var adoptedLegacy = false
    @ObservationIgnored private var refreshConversationOnRecovery = false
    @ObservationIgnored private var adoptingLegacy = false
    public func isControlInFlight(_ key: String) -> Bool { controlsInFlight.contains(key) }
    public func title(for run: AgentRun) -> String {
        run.title ?? messages.first(where: { $0.runID == run.runID && $0.role == "user" })?.content ?? "任务"
    }
    public func canSteer(_ run: AgentRun) -> Bool {
        run.status == "running" && run.pendingControls?.isEmpty != false && run.waitReason == nil &&
        run.cancelRequested != true && run.executionGeneration != nil && run.workID != nil
    }
    @discardableResult public func restoreAsNewMessage(_ task: RemoteTask) -> Bool {
        guard draft.isEmpty, let current = tasks.first(where: { $0.id == task.id }), current.deliveryFailed else { return false }
        let oldTarget = steeringTarget
        steeringTarget = nil
        var updated = tasks
        if let index = updated.firstIndex(where: { $0.id == task.id }) { updated[index].steeringRecovered = true; updated[index].needsReview = false }
        do { try persist(tasks: updated, draft: current.input); tasks = updated; draft = current.input; return true }
        catch { steeringTarget = oldTarget; failures[.storage] = error.localizedDescription; return false }
    }
    public var rejectedSharedSupplements: [ConversationMessage] {
        messages.filter { message in message.deliveryState == "not_applied" && !recoveredSupplements.contains(message.id) &&
            !tasks.contains(where: { $0.id == message.operationID && $0.steeringRecovered == true }) }
    }
    @discardableResult public func restoreAsNewMessage(_ message: ConversationMessage) -> Bool {
        guard draft.isEmpty, let current = rejectedSharedSupplements.first(where: { $0.id == message.id }) else { return false }
        let oldTarget = steeringTarget
        steeringTarget = nil; recoveredSupplements.insert(current.id)
        var updated = tasks
        if let index = updated.firstIndex(where: { $0.id == current.operationID }) { updated[index].steeringRecovered = true; updated[index].needsReview = false }
        do { try persist(tasks: updated, draft: current.content); tasks = updated; draft = current.content; return true }
        catch { recoveredSupplements.remove(current.id); steeringTarget = oldTarget; return false }
    }
    public var isEmpty: Bool { tasks.isEmpty && messages.isEmpty }
    /// Server facts rendered as system notices, never persisted as model messages or cursors.
    public var displayMessages: [ConversationMessage] {
        let ordered = messages.sorted {
            if ($0.sourceSession == nil) != ($1.sourceSession == nil) { return $0.sourceSession != nil }
            return $0.seq < $1.seq
        }
        let failures = sharedRuns.filter { ["failed", "cancelled", "interrupted"].contains($0.status) }
        let byRun = Dictionary(failures.map { ($0.runID, $0) }, uniquingKeysWith: { _, last in last })
        var lastMessage: [String: String] = [:]
        for row in ordered { if let run = row.runID { lastMessage[run] = row.id } }
        func notice(_ run: AgentRun, after row: ConversationMessage?) -> ConversationMessage {
            let text = run.status == "failed" ? "这次请求未完成。" + (run.error.map { "\n" + $0 } ?? "") : "已停止。"
            return ConversationMessage(id: "run-status-" + run.runID, seq: row?.seq ?? 0, role: "system", content: text,
                createdAt: row?.createdAt ?? 0, operationID: nil, runID: run.runID, sourceSession: row?.sourceSession)
        }
        var result: [ConversationMessage] = []
        for row in ordered {
            result.append(row)
            if row.deliveryState == "not_applied" {
                result.append(ConversationMessage(id: "delivery-" + row.id, seq: row.seq, role: "system", content: "这条补充未应用。", createdAt: row.createdAt, operationID: nil, runID: nil))
            }
            if let id = row.runID, lastMessage[id] == row.id, let run = byRun[id] { result.append(notice(run, after: row)) }
        }
        return result
    }
    private var sharedSessionID: String { "momo-main-" + connection.assistantID.uuidString.lowercased() }
    public let connection: AgentConnection
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let sessionID: String
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var eventTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var subscription: ConversationSubscription?
    @ObservationIgnored private var loadingOlderMessages: Task<Void, Never>?
    public private(set) var eventCursor: Int?
    private var olderMessagesBefore: Int?
    @ObservationIgnored private var warming: Task<Void, Never>?
    @ObservationIgnored private var eventTaskIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var isSubmitting = false
    @ObservationIgnored private var cachedCapabilities: (value: AgentCapabilities, until: Date)?
    @ObservationIgnored private var loadingCapabilities: Task<AgentCapabilities, Error>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var draftDirty = false
    @ObservationIgnored private var checkpointSaveTask: Task<Void, Never>?
    @ObservationIgnored private var journalDirty = false
    @ObservationIgnored public var prepareSubmission: ((RemoteTask) async throws -> Void)?
    @ObservationIgnored private let now: () -> Date

    private struct Document: Codable {
        var schemaVersion = 2
        let connection: AgentConnection
        let sessionID: String
        let draft: String
        var draftAttachments: [AgentAttachment]? = nil
        let tasks: [RemoteTask]
        var conversation: SharedConversation? = nil
        var messages: [ConversationMessage]? = nil
        var messageCursor: Int? = nil
        var eventCursor: Int? = nil
        var olderMessagesBefore: Int? = nil
        var sharedRuns: [AgentRun]? = nil
        var backgroundWork: [ConversationWork]? = nil
        var steeringTarget: AgentRun? = nil
        var pendingCancellations: [String: Cancellation]? = nil
        var pendingReports: [String: UUID]? = nil
        var recoveredSupplements: Set<String>? = nil
    }

    public init(file: URL, connection: AgentConnection, client: AgentClient, now: @escaping () -> Date = Date.init) throws {
        self.file = file; self.connection = connection; self.client = client; self.now = now
        if FileManager.default.fileExists(atPath: file.path) {
            var raw = try Data(contentsOf: file)
            let migratedLegacyPrefix: Bool
            if let text = String(data: raw, encoding: .utf8),
               text.contains("\"wml-") || text.contains("\"run_wml_") || text.contains("\"wml_completion_") || text.contains("\"mcp__wml_computer__") || text.contains("watchmylife://source/") {
                let migrated = text
                    .replacingOccurrences(of: "\"wml-", with: "\"momo-")
                    .replacingOccurrences(of: "\"run_wml_", with: "\"run_momo_")
                    .replacingOccurrences(of: "\"wml_completion_", with: "\"momo_completion_")
                    .replacingOccurrences(of: "\"mcp__wml_computer__", with: "\"mcp__momo_computer__")
                    .replacingOccurrences(of: "watchmylife://source/", with: "momoagent://source/")
                raw = Data(migrated.utf8)
                migratedLegacyPrefix = true
            } else {
                migratedLegacyPrefix = false
            }
            let saved = try JSONDecoder().decode(Document.self, from: raw)
            guard [1, 2].contains(saved.schemaVersion), saved.connection.hasSameIdentity(as: connection),
                  !saved.sessionID.isEmpty, Set(saved.tasks.map(\.id)).count == saved.tasks.count,
                  saved.tasks.allSatisfy({ $0.sessionID == saved.sessionID || $0.sessionID == "momo-main-" + connection.assistantID.uuidString.lowercased() }) else {
                throw StoreError.invalidJournal
            }
            sessionID = saved.sessionID; tasks = saved.tasks; draft = saved.draft
            draftAttachments = saved.draftAttachments ?? []
            pendingCancellations = saved.pendingCancellations ?? [:]
            pendingReports = saved.pendingReports ?? [:]; recoveredSupplements = saved.recoveredSupplements ?? []
            conversation = saved.conversation; messages = saved.messages ?? []; messageCursor = saved.messageCursor ?? 0
            eventCursor = saved.eventCursor; olderMessagesBefore = saved.olderMessagesBefore
            sharedRuns = saved.sharedRuns ?? []; backgroundWork = saved.backgroundWork ?? []
            guard eventCursor.map({ $0 >= 0 }) ?? true else { throw StoreError.invalidJournal }
            if migratedLegacyPrefix { try persist(tasks: tasks, draft: draft) }
            // The composer no longer has a task-selection mode. Preserve the draft,
            // but never restore an invisible destination from an older app version.
        } else {
            sessionID = "momo-" + UUID().uuidString.lowercased(); tasks = []; draft = ""
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try persist(tasks: [], draft: "")
        }
    }

    public var hasPendingTask: Bool { tasks.contains(where: \.isPending) }
    public var waitingForReply: Bool {
        if tasks.contains(where: { task in
            guard !task.needsReview, !task.stopRequested, task.lastError == nil,
                  task.steeringRecovered != true else { return false }
            let runID = task.run?.runID ?? messages.first(where: { $0.operationID == task.id })?.runID
            guard let runID else { return false }
            if messages.contains(where: { $0.role == "assistant" && $0.runID == runID }) { return false }
            let run = task.run?.isTerminal == true ? task.run : sharedRuns.first(where: { $0.runID == runID }) ?? task.run
            guard run?.pendingControls?.isEmpty != false else { return false }
            let usesSharedMessages = messages.contains { $0.operationID == task.id || $0.runID == runID }
            if usesSharedMessages {
                // A user echo hides this task's local reply in ChatRenderSnapshot.
                // Completion can arrive before the shared answer; keep waiting until it is visible.
                if run?.status == "completed" {
                    return task.run?.status != "completed" || task.run?.output?.isEmpty == false || task.reply?.messages.isEmpty == false
                }
                return run.map { ["started", "queued", "running"].contains($0.status) } ?? true
            }
            return task.isAwaitingReply && (run.map { ["started", "queued", "running"].contains($0.status) } ?? true)
        }) { return true }
        return sharedRuns.contains { run in
            ["queued", "running"].contains(run.status) && run.pendingControls?.isEmpty != false &&
            !tasks.contains { $0.run?.runID == run.runID } &&
            !messages.contains { $0.role == "assistant" && $0.runID == run.runID }
        }
    }
    public var hasActiveTask: Bool { tasks.contains { $0.isPending && !$0.needsReview && $0.lastError == nil && $0.run?.pendingControls?.isEmpty != false } || sharedRuns.contains { ["queued", "running"].contains($0.status) && $0.pendingControls?.isEmpty != false } }
    public var interruptedTask: RemoteTask? {
        tasks.first { $0.run != nil && !$0.isFinished && $0.lastError != nil }
    }

    public func setSteeringTarget(_ run: AgentRun?) {
        steeringTarget = run
        do { try persist(tasks: tasks, draft: draft) } catch { failures[.storage] = error.localizedDescription }
    }

    public func setDraft(_ text: String) {
        guard draft != text || draftDirty else { return }
        draft = text
        draftDirty = true
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flushDraft()
        }
    }

    public func flushDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard draftDirty else { return }
        do { try persist(tasks: tasks, draft: draft) }
        catch { failures[.storage] = error.localizedDescription }
    }

    private func scheduleCheckpointSave() {
        journalDirty = true
        guard checkpointSaveTask == nil else { return }
        checkpointSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self else { return }
            self.checkpointSaveTask = nil
            guard self.journalDirty || self.draftDirty else { return }
            do { try self.persist(tasks: self.tasks, draft: self.draft) }
            catch { self.failures[.storage] = error.localizedDescription }
        }
    }

    private func flushPendingPersistence() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        checkpointSaveTask?.cancel()
        checkpointSaveTask = nil
        guard draftDirty || journalDirty else { return }
        do { try persist(tasks: tasks, draft: draft) }
        catch { failures[.storage] = error.localizedDescription }
    }

    public func addAttachments(_ additions: [AgentAttachment]) throws {
        let combined = draftAttachments + additions
        try AgentAttachment.validate(combined)
        try persist(tasks: tasks, draft: draft, draftAttachments: combined)
        draftAttachments = combined
        failures[.storage] = nil
    }

    public func removeAttachment(_ id: UUID) {
        let updated = draftAttachments.filter { $0.id != id }
        do {
            try persist(tasks: tasks, draft: draft, draftAttachments: updated)
            draftAttachments = updated
        } catch { failures[.storage] = error.localizedDescription }
    }

    public func attachment(id: UUID) -> AgentAttachment? {
        if let item = draftAttachments.first(where: { $0.id == id }) { return item }
        for task in tasks {
            if let item = task.attachments?.first(where: { $0.id == id }) { return item }
        }
        for message in messages {
            if let item = message.attachments?.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    @discardableResult public func enqueue() throws -> UUID {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard (hasText || !draftAttachments.isEmpty),
              draft.utf8.count <= 16_384 else { throw StoreError.invalidSubmission }
        if !draftAttachments.isEmpty {
            try AgentAttachment.validate(draftAttachments)
        }
        var task = RemoteTask(id: UUID(), sessionID: sharedSessionID, input: draft, createdAt: now(),
                              attachments: draftAttachments.isEmpty ? nil : draftAttachments)
        if draftAttachments.isEmpty {
            task.targetWorkID = steeringTarget?.workID
            task.targetRunID = steeringTarget?.runID; task.targetGeneration = steeringTarget?.executionGeneration
        }
        let updated = tasks + [task]
        // Commit intent and immutable payload before the first network request or clearing input.
        try persist(tasks: updated, draft: "", draftAttachments: [])
        tasks = updated; draft = ""; draftAttachments = []; steeringTarget = nil
        return task.id
    }

    public func foreground() {
        guard observing == nil, canContactServer else { return }
        if connectionState == .unavailable { connectionState = .retrying }
        // Opportunistic only: sending never awaits this probe or its failure.
        warming = Task { [client] in try? await client.warmSubmission() }
        nextConnectionAttempt = nil
        let id = UUID(); observationID = id
        observing = Task { [weak self] in
            // Upgrade older journals on entry. The durable shared inbox contract is
            // bound to the verified server identity, not a 60-second send preflight.
            await self?.discoverConversation(refreshContract: self?.conversation?.capabilities.messageIdempotency == nil || self?.conversation?.capabilities.conversationEvents == nil)
            if self?.conversation?.capabilities.messageIdempotency == nil {
                _ = try? await self?.submissionCapabilities()
            }
            while !Task.isCancelled {
                guard let self else { return }
                self.startConversationSubscription()
                await self.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
            if self?.observationID == id { self?.observing = nil }
        }
    }

    public func background() {
        flushPendingPersistence()
        subscription?.stop(); subscription = nil
        loadingOlderMessages?.cancel(); loadingOlderMessages = nil
        warming?.cancel(); warming = nil
        lifetime = UUID()
        observationID = nil
        observing?.cancel(); observing = nil
        loadingCapabilities?.cancel()
        eventTaskIDs.removeAll()
        for task in eventTasks.values { task.cancel() }
        eventTasks.removeAll()
        // No remote stop: an interrupted HTTP response is reconciled with the same identity.
    }

    public func retryConnection() async {
        guard canContactServer else { return }
        subscription?.stop(); subscription = nil
        if connectionState == .unavailable { connectionState = .retrying }
        startConversationSubscription()
        nextConnectionAttempt = nil
        await refresh()
    }

    public func refresh(userInitiated: Bool = false) async {
        if let deadline = serverRetryNotBefore, now() < deadline { return }
        if userInitiated, canContactServer {
            if connectionState == .unavailable {
                connectionState = .retrying
                nextConnectionAttempt = nil
                startConversationSubscription()
            } else if connectionState == .retrying {
                // A deliberate send can retry a recovered link, but cannot bypass server throttling.
                nextConnectionAttempt = nil
            }
        }
        guard canContactServer, connectionState != .unavailable,
              nextConnectionAttempt.map({ now() >= $0 }) ?? true else { return }
        nextConnectionAttempt = nil
        // Keep recovery visible until a response actually confirms connectivity.
        // Delivery has its own lane: a slow status/SSE read never holds the next message.
        await discoverConversation(refreshContract: !userInitiated && refreshConversationOnRecovery)
        guard connectionState != .authenticationRequired, connectionState != .unavailable, nextConnectionAttempt == nil else { return }
        // Only a legacy outbox needs adoption before its original submission.
        // Importing old history must never hold a newly composed shared message.
        let hasLegacySubmission = tasks.contains(where: { $0.sessionID == sessionID && $0.run == nil })
        if hasLegacySubmission {
            await adoptLegacyConversationIfNeeded()
        }
        guard canContactServer else { return }
        await deliverPending()
        await deliverCancellations()
        await deliverReports()
        guard canContactServer else { return }
        if conversation?.capabilities.conversationEvents == true, subscription?.isRunning == true { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if !hasLegacySubmission { await adoptLegacyConversationIfNeeded() }
        for id in tasks.filter({ $0.run != nil && !$0.isFinished && !$0.needsReview && !$0.deliveryFailed }).map(\.id) {
            guard !Task.isCancelled else { return }
            await reconcile(id)
        }
        await receiveSharedMessages()
    }

    private func adoptLegacyConversationIfNeeded() async {
        guard !adoptingLegacy else { return }
        adoptingLegacy = true
        defer { adoptingLegacy = false }
        if conversation != nil && !tasks.contains(where: { $0.sessionID == sessionID }) { adoptedLegacy = true }
        if conversation != nil && !adoptedLegacy && !tasks.contains(where: { $0.sessionID == sessionID && $0.firstAttemptAt != nil && $0.run == nil }) {
            do {
                let consumptions = tasks.compactMap { task -> LegacyConsumption? in
                    guard task.sessionID == sessionID, let ids = task.backgroundMessageIDs, let run = task.run else { return nil }
                    return LegacyConsumption(runID: run.runID, messageIDs: ids)
                }
                adoptedLegacy = try await request { try await client.adoptLegacyConversation(sessionID: sessionID, consumptions: consumptions) }
                failures[.adoption] = nil
            }
            catch { failures[.adoption] = error.localizedDescription }
        }
    }

    public func checkAgain(id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }), !task.isFinished else { return }
        // A review state without a run ID must not silently turn into another admission.
        guard !task.needsReview || task.run != nil else { return }
        if task.run == nil {
            do { try update(id) { $0.lastError = nil } }
            catch { failures[.storage] = error.localizedDescription; return }
            await deliverPending()
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await reconcile(id)
    }

    public func requestStop(id: UUID) async {
        guard !isRefreshing, let task = tasks.first(where: { $0.id == id }),
              let run = task.run, !run.isTerminal else { return }
        if run.workID != nil { await stopSharedRun(run); return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try update(id) { $0.stopRequested = true }
            try await request { try await client.requestStop(runID: run.runID) }
            // An acknowledgement is not evidence of termination.
            await reconcile(id)
        } catch { record(error, id: id) }
    }

    private func discoverConversation(refreshContract: Bool = false) async {
        guard conversation == nil || refreshContract else { return }
        do {
            let found = try await request { try await client.conversation() }
            guard found.assistantID == connection.assistantID, found.instanceID == connection.instanceID,
                  found.sessionID == sharedSessionID else { throw StoreError.invalidResponse }
            guard found.capabilities.sharedConversation, found.capabilities.serverOwnedCompletion else { throw StoreError.unsupportedServer }
            failures[.discovery] = nil
            refreshConversationOnRecovery = false
            markConnectionReady()
            conversation = found
            do { try persist(tasks: tasks, draft: draft) } catch { conversation = nil }
        } catch {
            // Legacy journals remain readable and reconcile their original run identities.
            // They never create a hidden completion turn on the client's behalf.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            refreshConversationOnRecovery = conversation != nil
            if case AgentClientError.http(let status, _, _, _) = error, [404, 405, 501].contains(status) {
                connectionState = .unavailable
                failures[.discovery] = StoreError.unsupportedServer.localizedDescription
            } else {
                if case StoreError.unsupportedServer = error { connectionState = .unavailable }
                failures[.discovery] = connectionErrorDescription(error)
            }
        }
    }

    private func receiveSharedMessages() async {
        guard conversation != nil else { return }
        do {
            while !Task.isCancelled {
                let page = try await request { try await client.conversationMessages(after: messageCursor) }
                guard page.data.allSatisfy({ $0.seq > messageCursor }),
                      zip(page.data, page.data.dropFirst()).allSatisfy({ $0.seq < $1.seq }),
                      page.nextCursor == (page.data.last?.seq ?? messageCursor),
                      !page.hasMore || !page.data.isEmpty else { throw StoreError.invalidResponse }
                let oldMessages = messages, oldCursor = messageCursor
                let known = Set(messages.map(\.id))
                messages += page.data.filter { !known.contains($0.id) }
                messages.sort { $0.seq < $1.seq }; messageCursor = page.nextCursor
                do { try persist(tasks: tasks, draft: draft) }
                catch { messages = oldMessages; messageCursor = oldCursor; return }
                if !page.hasMore { break }
            }
            var runs: [AgentRun] = []; var cursor = 0; var states: [String: String] = [:]
            while !Task.isCancelled {
                let snapshot = try await request { try await client.conversationRunSnapshot(after: cursor) }
                runs += snapshot.data; backgroundWork = snapshot.backgroundWork ?? []
                states.merge(snapshot.messageStates ?? [:]) { _, latest in latest }
                if snapshot.hasMore != true { break }
                guard let next = snapshot.nextCursor, next > cursor else { throw StoreError.invalidResponse }
                cursor = next
            }
            try Task.checkCancellation()
            let previous = messages, previousRuns = sharedRuns, previousReplies = sharedRunReplies
            for index in messages.indices { if let state = states[messages[index].id] { messages[index].deliveryState = state } }
            sharedRuns = runs
            pruneSharedRunReplies()
            do { try persist(tasks: tasks, draft: draft) } catch { messages = previous; sharedRuns = previousRuns; sharedRunReplies = previousReplies; return }
            failures[.synchronization] = nil
            if refreshConversationOnRecovery { failures[.discovery] = nil }
            markConnectionReady()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            failures[.synchronization] = connectionErrorDescription(error)
        }
    }

    public func respond(run: AgentRun, control: AgentControl, answer: String) async {
        guard controlsInFlight.insert(run.runID).inserted else { return }
        defer { controlsInFlight.remove(run.runID) }
        do {
            let current = try await request { try await client.run(id: run.runID) }
            guard let generation = run.executionGeneration, generation == current.executionGeneration,
                  current.pendingControls?.contains(control) == true else { throw StoreError.invalidResponse }
            try await request { try await client.respond(runID: run.runID, control: control, generation: generation, answer: answer) }
            failures[.control] = nil
            await refresh()
        } catch { recordControlFailure(error); if canContactServer { await receiveSharedMessages() } }
    }

    public func stopSharedRun(_ run: AgentRun) async {
        guard controlsInFlight.insert(run.runID).inserted else { return }
        defer { controlsInFlight.remove(run.runID) }
        if let work = run.workID {
            await cancel(id: work, generation: run.executionGeneration ?? 0, targetRunID: run.runID)
        } else {
            do { try await request { try await client.requestStop(runID: run.runID) }; failures[.control] = nil; await refresh() }
            catch { recordControlFailure(error) }
        }
    }
    public func cancelBackgroundWork(_ work: ConversationWork) async {
        guard let generation = work.executionGeneration, controlsInFlight.insert(work.id).inserted else { return }
        defer { controlsInFlight.remove(work.id) }
        await cancel(id: work.id, generation: generation)
    }
    private func cancel(id: String, generation: Int, targetRunID: String? = nil) async {
        if pendingCancellations[id] == nil { pendingCancellations[id] = Cancellation(operationID: UUID(), generation: generation, targetRunID: targetRunID) }
        do { try persist(tasks: tasks, draft: draft); try await sendCancellation(id); await receiveSharedMessages() }
        catch { recordControlFailure(error) }
    }
    private func sendCancellation(_ id: String) async throws {
        guard let value = pendingCancellations[id] else { return }
        do { try await request { try await client.cancelWork(id: id, operationID: value.operationID, generation: value.generation, targetRunID: value.targetRunID) } }
        catch {
            if case AgentClientError.http(let status, _, _, _) = error, [400, 404, 409].contains(status) {
                pendingCancellations.removeValue(forKey: id)
                try persist(tasks: tasks, draft: draft)
            }
            throw error
        }
        pendingCancellations.removeValue(forKey: id)
        try persist(tasks: tasks, draft: draft)
        failures[.control] = nil
    }
    private func deliverCancellations() async {
        for id in Array(pendingCancellations.keys) {
            guard canContactServer, nextConnectionAttempt == nil else { return }
            do { try await sendCancellation(id) }
            catch { recordControlFailure(error) }
        }
    }

    public func retryReport(_ work: ConversationWork) async {
        guard work.reportRetryAvailable == true, controlsInFlight.insert(work.id).inserted else { return }
        defer { controlsInFlight.remove(work.id) }
        if pendingReports[work.id] == nil { pendingReports[work.id] = UUID() }
        do { try persist(tasks: tasks, draft: draft); try await sendReport(work.id); await receiveSharedMessages() }
        catch { recordControlFailure(error) }
    }
    private func sendReport(_ id: String) async throws {
        guard let operation = pendingReports[id] else { return }
        do { try await request { try await client.retryReport(id: id, operationID: operation) } }
        catch {
            if case AgentClientError.http(let status, _, _, _) = error, [400, 404, 409].contains(status) {
                pendingReports.removeValue(forKey: id); try persist(tasks: tasks, draft: draft)
            }
            throw error
        }
        pendingReports.removeValue(forKey: id); try persist(tasks: tasks, draft: draft); failures[.control] = nil
    }
    private func deliverReports() async {
        for id in Array(pendingReports.keys) {
            guard canContactServer, nextConnectionAttempt == nil else { return }
            do { try await sendReport(id) } catch { recordControlFailure(error) }
        }
    }

    public func resolveUnknown(_ run: AgentRun) async {
        guard controlsInFlight.insert(run.runID).inserted else { return }
        defer { controlsInFlight.remove(run.runID) }
        do { try await request { try await client.resolveUnknown(run: run) }; failures[.control] = nil; await refresh() }
        catch { recordControlFailure(error) }
    }

    public func markVisibleMessagesRead(through sequence: Int) async -> Bool {
        guard canContactServer, conversation != nil, sequence > visibleReadSeq,
              messages.contains(where: { $0.seq == sequence && $0.sourceSession == nil }) else { return false }
        pendingReadSeq = max(pendingReadSeq, sequence)
        guard !sendingReadReceipt else { return false }
        sendingReadReceipt = true
        defer { sendingReadReceipt = false }
        do {
            while pendingReadSeq > visibleReadSeq {
                let through = pendingReadSeq
                try await request { try await client.markConversationRead(through: through) }
                visibleReadSeq = max(visibleReadSeq, through)
            }
            return true
        } catch { return false }
    }

    private func reconcile(_ id: UUID) async {
        guard let original = tasks.first(where: { $0.id == id }) else { return }
        guard let run = original.run else { return }
        do {
            let snapshot = try await request { try await client.run(id: run.runID) }
            guard snapshot.runID == run.runID else { throw StoreError.invalidResponse }
            guard !snapshot.runID.isEmpty, snapshot.sessionID == original.sessionID else { throw StoreError.invalidResponse }
            try update(id) {
                $0.run = snapshot; $0.lastConfirmedAt = now(); $0.lastError = nil
                $0.needsReview = !["started", "queued", "running", "steering", "stopping", "waiting_for_approval", "waiting_for_input", "waiting_for_computer", "not_applied", "completed", "failed", "cancelled", "interrupted"].contains(snapshot.status)
                if snapshot.status == "not_applied" { $0.needsReview = true; $0.lastError = "补充未送达，可改为新消息。" }
                else if $0.needsReview { $0.lastError = StoreError.unknownOutcome.localizedDescription }
            }
            failures[.delivery] = nil
            observeReplyIfNeeded(id)
        } catch { record(error, id: id) }
    }

    private func deliverPending() async {
        guard !isSubmitting, canContactServer, nextConnectionAttempt == nil else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        var attempted: Set<UUID> = []
        while let next = tasks.first(where: { $0.run == nil && $0.steeringRecovered != true && !$0.needsReview && !attempted.contains($0.id) &&
            (!$0.deliveryFailed || (!$0.needsReview && connectionState != .unavailable) || $0.backgroundMessageIDs != nil) && ($0.backgroundMessageIDs == nil || $0.firstAttemptAt != nil) }) {
            guard !Task.isCancelled, canContactServer, nextConnectionAttempt == nil else { return }
            attempted.insert(next.id)
            await submit(next.id)
        }
    }

    private func submit(_ id: UUID, repairConnection: Bool = true) async {
        guard let original = tasks.first(where: { $0.id == id }), original.run == nil, !original.needsReview else { return }
        // New messages require the server-owned identity. A failed discovery must
        // never silently bypass its durable inbox through the legacy /v1/runs door.
        guard original.sessionID != sharedSessionID || conversation != nil else { return }
        do {
            if original.firstAttemptAt == nil {
                try update(id) { $0.deliveryStartedAt = now() }
                if original.backgroundMessageIDs == nil { try await prepareSubmission?(original) }
                try Task.checkCancellation()
                try update(id) { $0.sourcesPreparedAt = now() }
                let guarantee: AgentCapabilities.Features.Idempotency?
                if original.sessionID == sharedSessionID, let shared = conversation?.capabilities.messageIdempotency {
                    guarantee = shared
                } else {
                    // Older servers and legacy runs retain their original API contract.
                    let capabilities = try await submissionCapabilities()
                    guard capabilities.features.runSubmission == true else { throw StoreError.unsupportedServer }
                    guarantee = capabilities.features.runsIdempotency
                }
                guard let guarantee, guarantee.supported == true, guarantee.durable == true,
                      let retention = guarantee.retentionSeconds, retention > 120 else {
                    throw StoreError.unsupportedServer
                }
                let start = now()
                try update(id) {
                    $0.firstAttemptAt = start
                    // A conservative bound: never replay after the server may have forgotten the key.
                    $0.replayBefore = start.addingTimeInterval(TimeInterval(retention - 60))
                }
            }
            guard let current = tasks.first(where: { $0.id == id }),
                  let deadline = current.replayBefore, now() < deadline else {
                try update(id) { $0.needsReview = true; $0.lastError = StoreError.expiredReceipt.localizedDescription }
                if original.backgroundMessageIDs != nil { failures[.delivery] = StoreError.expiredReceipt.localizedDescription }
                return
            }
            let receipt: AgentRun
            var events: AsyncThrowingStream<AgentRunEvent, Error>?
            if conversation?.capabilities.conversationEvents != true && conversation?.capabilities.messageStreaming == true && original.sessionID == sharedSessionID {
                let feed = try await request { try await client.submitMessageFeed(input: original.input, operationID: id, targetRunID: original.targetRunID, generation: original.targetGeneration, workID: original.targetWorkID, attachments: original.attachments) }
                receipt = feed.receipt; events = feed.events
            } else if conversation != nil && original.sessionID == sharedSessionID {
                receipt = try await request { try await client.submitMessage(input: original.input, operationID: id, targetRunID: original.targetRunID, generation: original.targetGeneration, workID: original.targetWorkID, attachments: original.attachments) }
            } else {
                receipt = try await request { try await client.submit(input: original.input, sessionID: original.sessionID, operationID: id) }
            }
            guard !receipt.runID.isEmpty, receipt.sessionID == nil || receipt.sessionID == original.sessionID else {
                throw StoreError.invalidResponse
            }
            markConnectionReady()
            // Upstream POST returns a small admission receipt (started, no session_id).
            // Persist its run ID before GET, so a lost status response never causes a second POST.
            try update(id) {
                // A pushed state may beat the POST response. Never overwrite it with an older receipt.
                if $0.lastConfirmedAt == nil { $0.run = receipt }
                $0.lastError = nil; $0.admittedAt = $0.admittedAt ?? now()
                if receipt.status == "not_applied" { $0.needsReview = true; $0.lastError = "补充未送达，可改为新消息。" }
            }
            observeReplyIfNeeded(id, events: events)
            // A schema 1 outbox may create its original session only on this POST.
            if original.sessionID == sessionID { await adoptLegacyConversationIfNeeded() }
        } catch {
            // The persistent stream may confirm admission before the POST response is lost.
            if Self.isTransientConnectionFailure(error), tasks.first(where: { $0.id == id })?.run != nil { return }
            // Repair a stale transport without waiting for the periodic outbox sweep.
            // Only the durable owner replays this identical operation, at most once.
            if repairConnection, Self.isRepairableSocketFailure(error),
               tasks.first(where: { $0.id == id })?.firstAttemptAt != nil {
                nextConnectionAttempt = nil
                await submit(id, repairConnection: false)
                return
            }
            record(error, id: id)
        }
    }

    private func submissionCapabilities() async throws -> AgentCapabilities {
        if let cachedCapabilities, now() < cachedCapabilities.until { return cachedCapabilities.value }
        if let loadingCapabilities { return try await loadingCapabilities.value }
        let task = Task { try await request { try await client.capabilities() } }
        loadingCapabilities = task
        defer { loadingCapabilities = nil }
        let value = try await task.value
        try Task.checkCancellation()
        cachedCapabilities = (value, now().addingTimeInterval(60))
        return value
    }

    nonisolated private static func shouldPersistImmediately(_ event: AgentRunEvent, existingFirstText: Date?) -> Bool {
        if ["message.committed", "message.interim", "run.completed", "run.failed", "run.cancelled", "run.interrupted", "replay.truncated"].contains(event.event) {
            return true
        }
        if existingFirstText == nil, event.event == "message.delta", event.delta?.isEmpty == false {
            return true
        }
        return false
    }

    private func pruneSharedRunReplies() {
        guard !sharedRunReplies.isEmpty else { return }
        let localRunIDs = Set(tasks.compactMap { $0.run?.runID })
        let activeSharedRunIDs = Set(sharedRuns.lazy.filter { !$0.isTerminal }.map(\.runID))
        for runID in Array(sharedRunReplies.keys) {
            if localRunIDs.contains(runID) || !activeSharedRunIDs.contains(runID) {
                sharedRunReplies.removeValue(forKey: runID)
            }
        }
    }

    private func stripConfirmedAttachmentPayloads(_ source: [RemoteTask]) -> [RemoteTask] {
        guard source.contains(where: { $0.attachments?.contains(where: { $0.data != nil }) == true }) else { return source }
        let confirmedOperations = Set(messages.compactMap(\.operationID))
        let confirmedUserRuns = Set(messages.lazy.filter { $0.role == "user" }.compactMap(\.runID))
        var updated = source
        for index in updated.indices {
            guard let run = updated[index].run, run.status != "not_applied",
                  let attachments = updated[index].attachments,
                  attachments.contains(where: { $0.data != nil }) else { continue }
            let serverConfirmed = confirmedOperations.contains(updated[index].id)
                || confirmedUserRuns.contains(run.runID)
                || run.isTerminal
                || conversation == nil
            if serverConfirmed {
                updated[index].attachments = attachments.map { $0.strippingRawPayload() }
            }
        }
        return updated
    }

    private func observeReplyIfNeeded(_ id: UUID, events: AsyncThrowingStream<AgentRunEvent, Error>? = nil) {
        guard conversation?.capabilities.conversationEvents != true,
              observing != nil, eventTasks[id] == nil, let task = tasks.first(where: { $0.id == id }),
              !task.isFinished, !task.needsReview, task.reply?.streamUnavailable != true, let runID = task.run?.runID else { return }
        let observation = UUID(); eventTaskIDs[id] = observation
        eventTasks[id] = Task { [weak self, client] in
            defer { if self?.eventTaskIDs[id] == observation { self?.eventTasks[id] = nil; self?.eventTaskIDs[id] = nil } }
            do {
                if let events {
                    for try await event in events {
                        try Task.checkCancellation()
                        let immediate = Self.shouldPersistImmediately(event, existingFirstText: self?.tasks.first(where: { $0.id == id })?.firstTextReceivedAt)
                        try self?.receive(event, for: id, persistImmediately: immediate)
                        if !immediate { self?.scheduleCheckpointSave() }
                    }
                } else {
                    try await client.observe(runID: runID, after: task.reply?.sequence) { [weak self] event in
                        let immediate = Self.shouldPersistImmediately(event, existingFirstText: await self?.tasks.first(where: { $0.id == id })?.firstTextReceivedAt)
                        try await self?.receive(event, for: id, persistImmediately: immediate)
                        if !immediate { await self?.scheduleCheckpointSave() }
                    }
                }
                self?.flushPendingPersistence()
            } catch {
                guard !Task.isCancelled else { return }
                self?.flushPendingPersistence()
                if case AgentClientError.http(401, _, _, _) = error { self?.recordConnectionFailure(error); return }
                // Events are ephemeral on Hermes restart; status remains authoritative.
                if case AgentClientError.http(let status, _, _, _) = error, status == 404 {
                    do { try self?.update(id) { if $0.reply == nil { $0.reply = RemoteReply() }; $0.reply?.streamUnavailable = true } }
                    catch { self?.failures[.storage] = error.localizedDescription }
                }
            }
        }
    }

    private func receive(_ event: AgentRunEvent, for id: UUID, persistImmediately: Bool = true) throws {
        try Task.checkCancellation()
        guard let task = tasks.first(where: { $0.id == id }), task.run?.runID == event.runID else { throw StoreError.invalidResponse }
        if event.event == "message.committed" {
            guard conversation != nil, let message = event.message, message.role == "assistant",
                  message.runID == event.runID, message.seq > 0, !message.id.isEmpty,
                  !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidResponse }
            let previous = messages
            var incoming = [message]
            if let input = event.input {
                guard input.role == "user", input.runID == event.runID, input.operationID == task.id,
                      input.content == task.input, input.seq > 0, input.seq < message.seq, !input.id.isEmpty else { throw StoreError.invalidResponse }
                incoming.insert(input, at: 0)
            } else if !messages.contains(where: { $0.role == "user" && $0.runID == event.runID }) {
                // Older servers do not include the canonical input. Let cursor sync
                // deliver both rows instead of briefly hiding the local user bubble.
                return
            }
            for row in incoming {
                if let existing = messages.first(where: { $0.id == row.id }) {
                    guard existing.seq == row.seq, existing.role == row.role, existing.content == row.content else { throw StoreError.invalidResponse }
                } else {
                    guard !messages.contains(where: { $0.seq == row.seq }) else { throw StoreError.invalidResponse }
                }
            }
            let known = Set(messages.map(\.id))
            messages += incoming.filter { !known.contains($0.id) }; messages.sort { $0.seq < $1.seq }
            // This event can overtake another device's messages. Only contiguous
            // cursor reads advance messageCursor; stable IDs dedupe the later replay.
            do { try update(id, persistImmediately: persistImmediately) { if $0.firstCommittedTextAt == nil { $0.firstCommittedTextAt = now() } } }
            catch { messages = previous; throw error }
        }
        var reply = task.reply ?? RemoteReply()
        reply.apply(event)
        if reply != task.reply {
            try update(id, persistImmediately: persistImmediately) {
                $0.reply = reply
                if $0.firstTextReceivedAt == nil, event.event == "message.delta", event.delta?.isEmpty == false {
                    $0.firstTextReceivedAt = now()
                }
            }
        }
    }

    private func record(_ error: Error, id: UUID) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        do {
            try update(id) {
                $0.lastError = error.localizedDescription
                $0.retryableDeliveryError = Self.isTransientConnectionFailure(error)
                if case AgentClientError.http(let status, _, _, _) = error,
                   [400, 403, 404, 409, 410, 422].contains(status) { $0.needsReview = true }
                if error is StoreError { $0.needsReview = true }
            }
            if tasks.first(where: { $0.id == id }).map({ $0.backgroundMessageIDs != nil && $0.needsReview }) == true {
                failures[.delivery] = error.localizedDescription
            }
        } catch { failures[.storage] = error.localizedDescription }
    }

    private func startConversationSubscription() {
        if subscription?.isRunning == false { subscription = nil }
        guard subscription == nil, conversation?.capabilities.conversationEvents == true,
              canContactServer, connectionState != .unavailable, let owner = observationID else { return }
        subscription = ConversationSubscription(client: client, cursor: { [weak self] in self?.eventCursor },
            snapshot: { [weak self] value in
                guard let self, self.observationID == owner, self.canContactServer else { throw CancellationError() }
                try self.applyConversationSnapshot(value)
            }, event: { [weak self] value in
                guard let self, self.observationID == owner, self.canContactServer else { throw CancellationError() }
                try self.applyConversationEvent(value)
            }, failed: { [weak self] error in
                guard let self, self.observationID == owner else { return }
                self.flushPendingPersistence()
                self.recordConnectionFailure(error)
                self.failures[.synchronization] = self.connectionErrorDescription(error)
                if error is StoreError || error is DecodingError { self.connectionState = .unavailable }
            })
        loadOlderMessages()
    }

    private func mergeConversationMessages(_ incoming: [ConversationMessage]) throws {
        for message in incoming {
            guard message.seq > 0, !message.id.isEmpty, ["user", "assistant"].contains(message.role) else { throw StoreError.invalidResponse }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                let saved = messages[index]
                guard saved.seq == message.seq, saved.role == message.role, saved.content == message.content else { throw StoreError.invalidResponse }
                if saved.runID != message.runID || saved.operationID != message.operationID || saved.deliveryState != message.deliveryState || (saved.attachments == nil && message.attachments != nil) {
                    messages[index] = message
                }
            } else {
                guard !messages.contains(where: { $0.seq == message.seq }) else { throw StoreError.invalidResponse }
            }
        }
        let known = Set(messages.map(\.id))
        let additions = incoming.filter { !known.contains($0.id) }
        if !additions.isEmpty { messages = (messages + additions).sorted { $0.seq < $1.seq } }
        messageCursor = max(messageCursor, incoming.map(\.seq).max() ?? 0)
    }

    private func applyLiveRun(_ run: AgentRun) throws {
        guard !run.runID.isEmpty else { throw StoreError.invalidResponse }
        if let index = sharedRuns.firstIndex(where: { $0.runID == run.runID }) {
            if sharedRuns[index] != run { sharedRuns[index] = run }
        } else { sharedRuns.append(run) }
        let operation = messages.first(where: { $0.runID == run.runID && $0.role == "user" })?.operationID
        if let index = tasks.firstIndex(where: { $0.run?.runID == run.runID || $0.id == operation }) {
            tasks[index].run = run; tasks[index].admittedAt = tasks[index].admittedAt ?? now()
            tasks[index].lastConfirmedAt = now(); tasks[index].lastError = nil
            if run.isTerminal { tasks[index].finishedAt = tasks[index].finishedAt ?? now() }
            if run.status == "not_applied" { tasks[index].needsReview = true }
            sharedRunReplies.removeValue(forKey: run.runID)
        } else if run.isTerminal {
            sharedRunReplies.removeValue(forKey: run.runID)
        }
    }

    private func applyLiveWork(_ work: [ConversationWork], states: [String: String]) {
        if backgroundWork != work { backgroundWork = work }
        for index in messages.indices {
            if let state = states[messages[index].id], messages[index].deliveryState != state { messages[index].deliveryState = state }
        }
    }

    private func markConnectionReady() {
        connectionState = .ready; connectionFailures = 0; nextConnectionAttempt = nil
        onConnectionRestored?()
    }

    private func liveConnectionConfirmed() {
        connectionConfirmation &+= 1
        markConnectionReady()
        failures[.synchronization] = nil
    }

    private func applyConversationSnapshot(_ value: ConversationSnapshot) throws {
        guard value.conversationID == conversation?.conversationID, value.cursor >= 0 else { throw StoreError.invalidResponse }
        let oldMessages = messages, oldRuns = sharedRuns, oldTasks = tasks, oldWork = backgroundWork
        let oldReplies = sharedRunReplies
        let oldCursor = eventCursor, oldMessageCursor = messageCursor, oldBefore = olderMessagesBefore
        do {
            try mergeConversationMessages(value.messages.data)
            sharedRuns.removeAll { !$0.isTerminal }
            for run in value.runs { try applyLiveRun(run) }
            applyLiveWork(value.backgroundWork, states: value.messageStates)
            // A new event namespace must not compare against old per-run sequence numbers.
            if eventCursor == nil {
                for index in tasks.indices where tasks[index].isPending { tasks[index].reply = nil }
                sharedRunReplies.removeAll()
            } else {
                pruneSharedRunReplies()
            }
            tasks = stripConfirmedAttachmentPayloads(tasks)
            olderMessagesBefore = value.messages.hasMore ? value.messages.data.map(\.seq).min() : nil
            eventCursor = value.cursor
            try persist(tasks: tasks, draft: draft)
        } catch {
            messages = oldMessages; sharedRuns = oldRuns; tasks = oldTasks; backgroundWork = oldWork
            sharedRunReplies = oldReplies
            eventCursor = oldCursor; messageCursor = oldMessageCursor; olderMessagesBefore = oldBefore
            throw error
        }
        liveConnectionConfirmed(); loadOlderMessages()
    }

    private func applyConversationEvent(_ value: ConversationEvent) throws {
        guard value.conversationID == conversation?.conversationID else { throw StoreError.invalidResponse }
        if ["ready", "heartbeat"].contains(value.kind) { liveConnectionConfirmed(); return }
        guard let cursor = value.cursor, cursor > 0 else { throw StoreError.invalidResponse }
        if cursor <= (eventCursor ?? 0) { return }
        let oldMessages = messages, oldRuns = sharedRuns, oldTasks = tasks, oldWork = backgroundWork
        let oldReplies = sharedRunReplies
        let oldCursor = eventCursor, oldMessageCursor = messageCursor
        var shouldPersist = true
        do {
            switch value.kind {
            case "message.created":
                guard let message = value.message else { throw StoreError.invalidResponse }
                try mergeConversationMessages([message])
                if message.role == "assistant", let index = tasks.firstIndex(where: { $0.run?.runID == message.runID }), tasks[index].firstCommittedTextAt == nil {
                    tasks[index].firstCommittedTextAt = now()
                }
                tasks = stripConfirmedAttachmentPayloads(tasks)
            case "run.updated":
                guard let run = value.run else { throw StoreError.invalidResponse }
                try applyLiveRun(run)
                tasks = stripConfirmedAttachmentPayloads(tasks)
            case "work.updated":
                guard let work = value.backgroundWork, let states = value.messageStates else { throw StoreError.invalidResponse }
                applyLiveWork(work, states: states)
            case "run.event":
                guard let event = value.runEvent, event.seq == cursor else { throw StoreError.invalidResponse }
                if let task = tasks.first(where: { $0.run?.runID == event.runID }) {
                    sharedRunReplies.removeValue(forKey: event.runID)
                    shouldPersist = Self.shouldPersistImmediately(event, existingFirstText: task.firstTextReceivedAt)
                    try receive(event, for: task.id, persistImmediately: false)
                } else {
                    if sharedRuns.first(where: { $0.runID == event.runID })?.isTerminal != true {
                        var reply = sharedRunReplies[event.runID] ?? RemoteReply()
                        reply.apply(event)
                        if ["run.completed", "run.failed", "run.cancelled", "run.interrupted"].contains(event.event) {
                            sharedRunReplies.removeValue(forKey: event.runID)
                        } else if reply != sharedRunReplies[event.runID] {
                            sharedRunReplies[event.runID] = reply
                        }
                    }
                    shouldPersist = false
                }
            default: throw StoreError.invalidResponse
            }
            eventCursor = cursor
            if shouldPersist {
                try persist(tasks: tasks, draft: draft)
            } else {
                scheduleCheckpointSave()
            }
        } catch {
            messages = oldMessages; sharedRuns = oldRuns; tasks = oldTasks; backgroundWork = oldWork
            sharedRunReplies = oldReplies
            eventCursor = oldCursor; messageCursor = oldMessageCursor
            throw error
        }
        liveConnectionConfirmed()
    }

    private func loadOlderMessages() {
        guard loadingOlderMessages == nil, olderMessagesBefore != nil, let owner = observationID else { return }
        loadingOlderMessages = Task { [weak self, client] in
            defer { if self?.observationID == owner { self?.loadingOlderMessages = nil } }
            do {
                while let before = self?.olderMessagesBefore {
                    guard let self, self.observationID == owner else { return }
                    let page = try await self.request { try await client.conversationMessages(before: before) }
                    guard self.observationID == owner else { return }
                    try Task.checkCancellation()
                    guard page.data.allSatisfy({ $0.seq < before }),
                          !page.hasMore || page.nextCursor < before && !page.data.isEmpty else { throw StoreError.invalidResponse }
                    try self.mergeConversationMessages(page.data)
                    self.olderMessagesBefore = page.hasMore ? page.nextCursor : nil
                    try self.persist(tasks: self.tasks, draft: self.draft)
                }
            } catch {
                guard let self, self.observationID == owner, !AgentTransportFailure.isCancelled(error) else { return }
                self.recordConnectionFailure(error)
                self.failures[.synchronization] = self.connectionErrorDescription(error)
            }
        }
    }

    private func update(_ id: UUID, persistImmediately: Bool = true, change: (inout RemoteTask) -> Void) throws {
        var updated = tasks
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw StoreError.invalidJournal }
        change(&updated[index])
        var timestamps = updated[index].replyReceivedAt ?? []
        while timestamps.count < (updated[index].reply?.messages.count ?? 0) { timestamps.append(now()) }
        updated[index].replyReceivedAt = timestamps
        if updated[index].run?.isTerminal == true, updated[index].finishedAt == nil { updated[index].finishedAt = now() }
        updated = stripConfirmedAttachmentPayloads(updated)
        if persistImmediately { try persist(tasks: updated, draft: draft) }
        tasks = updated
    }

    private func persist(tasks: [RemoteTask], draft: String, draftAttachments: [AgentAttachment]? = nil) throws {
        do {
            let currentAttachments = draftAttachments ?? self.draftAttachments
            let sanitizedTasks = stripConfirmedAttachmentPayloads(tasks)
            let data = try JSONEncoder().encode(Document(connection: connection, sessionID: sessionID, draft: draft,
                draftAttachments: currentAttachments.isEmpty ? nil : currentAttachments, tasks: sanitizedTasks,
                conversation: conversation, messages: messages, messageCursor: messageCursor,
                eventCursor: eventCursor, olderMessagesBefore: olderMessagesBefore, sharedRuns: sharedRuns, backgroundWork: backgroundWork, steeringTarget: (draft.isEmpty && currentAttachments.isEmpty) ? nil : steeringTarget, pendingCancellations: pendingCancellations,
                pendingReports: pendingReports, recoveredSupplements: recoveredSupplements))
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if sanitizedTasks != self.tasks, tasks == self.tasks {
                self.tasks = sanitizedTasks
            }
            draftSaveTask?.cancel(); draftSaveTask = nil; draftDirty = false
            checkpointSaveTask?.cancel(); checkpointSaveTask = nil; journalDirty = false
            failures[.storage] = nil
        } catch { failures[.storage] = error.localizedDescription; throw error }
    }

    private func request<T>(_ operation: () async throws -> T) async throws -> T {
        guard canContactServer else { throw CancellationError() }
        let generation = lifetime
        let confirmation = connectionConfirmation
        do {
            let value = try await operation()
            guard generation == lifetime else { throw CancellationError() }
            try Task.checkCancellation()
            connectionConfirmation &+= 1
            return value
        } catch {
            guard generation == lifetime else { throw CancellationError() }
            if !AgentTransportFailure.isSocketOrLinkFailure(error) || confirmation == connectionConfirmation {
                recordConnectionFailure(error)
            }
            throw error
        }
    }

    private func recordControlFailure(_ error: Error) {
        guard !AgentTransportFailure.isCancelled(error) else { return }
        if AgentTransportFailure.isTransient(error) {
            recordConnectionFailure(error)
            return
        }
        guard connectionState == .ready else { return }
        failures[.control] = error.localizedDescription
    }

    private static func isRepairableSocketFailure(_ error: Error) -> Bool {
        if let transportError = error as? URLError {
            return [URLError.badURL, .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(transportError.code)
        }
        return AgentTransportFailure.isSocketOrLinkFailure(error)
    }

    private static func isTransientConnectionFailure(_ error: Error) -> Bool {
        AgentTransportFailure.isTransient(error)
    }

    public func recordConnectionFailure(_ error: Error) {
        if AgentTransportFailure.isCancelled(error) { return }
        var delay: TimeInterval?; var transient = AgentTransportFailure.isSocketOrLinkFailure(error); var serverLimited = false
        if case AgentClientError.invalidResponse = error { transient = true }
        if case AgentClientError.http(let status, _, _, let retryAfter) = error {
            if status == 401 {
                lifetime = UUID()
                connectionState = .authenticationRequired; nextConnectionAttempt = nil
                onAuthenticationRequired?()
                return
            }
            transient = status == 408 || status == 429 || (500...599).contains(status) && status != 501
            delay = retryAfter
            serverLimited = status == 429 || (retryAfter ?? 0) > 0
            if [403, 405, 426, 501].contains(status) { connectionState = .unavailable; return }
        }
        if transient {
            // Concurrent failures from the stream and polling share one retry window.
            // Only a server throttle can extend a retry that is already scheduled.
            if !serverLimited, let deadline = nextConnectionAttempt, now() < deadline { return }
            connectionFailures += 1; connectionState = .retrying
            nextConnectionAttempt = now().addingTimeInterval(max(delay ?? 0, min(30, pow(2, Double(min(connectionFailures, 5))))))
            if serverLimited, let deadline = nextConnectionAttempt {
                serverRetryNotBefore = max(serverRetryNotBefore ?? deadline, deadline)
            }
        }
    }

    private func connectionErrorDescription(_ error: Error) -> String {
        if AgentTransportFailure.isTransient(error) { return "暂时无法连接 Mac，正在重试。" }
        return error.localizedDescription
    }

    public enum StoreError: Error, LocalizedError {
        case invalidJournal, invalidSubmission, unsupportedServer, invalidResponse, expiredReceipt, unknownOutcome
        public var errorDescription: String? {
            switch self {
            case .invalidJournal: "任务记录无法读取或属于另一台 Mac，原文件已保留。"
            case .invalidSubmission: "请输入不超过 16 KB 的文字。"
            case .unsupportedServer: "Mac 尚不支持持久任务投递，请检查运行版本。"
            case .invalidResponse: "Mac 返回的任务身份不一致，需要核对原任务。"
            case .expiredReceipt: "接收回执已超过安全重试时间，请在 Mac 核对原任务；不会自动重新执行。"
            case .unknownOutcome: "Mac 尚不能确认任务结果；请核对原任务，不会自动重新执行。"
            }
        }
    }
}
