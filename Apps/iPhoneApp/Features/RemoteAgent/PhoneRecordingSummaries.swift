import Foundation
import Observation
import MoMoAgentClient
import MoMoArchive

/// A phone outbox/cache only. Accepted jobs run to completion on Mac without a phone connection.
@MainActor @Observable
final class PhoneRecordingSummaries {
    private(set) var failure: String?
    @ObservationIgnored var onChanged: (() -> Void)?
    @ObservationIgnored var onAuthenticationRequired: ((Error) -> Void)?
    @ObservationIgnored private let archive: ArchiveStore
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saved: State
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var active = false
    nonisolated private static let terminalStates: Set<String> = ["done", "needs_review", "superseded"]

    nonisolated private static func isTerminal(_ state: String?) -> Bool {
        guard let state else { return false }
        return terminalStates.contains(state)
    }

    private struct Item: Codable {
        let windowID: TimelineWindowID
        var window: TimelineWindow?
        var receipt: RemoteSummaryReceipt?

        init(window: TimelineWindow, receipt: RemoteSummaryReceipt? = nil) {
            self.windowID = window.id
            self.window = PhoneRecordingSummaries.isTerminal(receipt?.state) ? nil : window
            self.receipt = receipt
        }

        private enum CodingKeys: String, CodingKey {
            case windowID, window, receipt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedReceipt = try container.decodeIfPresent(RemoteSummaryReceipt.self, forKey: .receipt)
            let decodedWindow = try container.decodeIfPresent(TimelineWindow.self, forKey: .window)
            if let explicitID = try container.decodeIfPresent(TimelineWindowID.self, forKey: .windowID) {
                self.windowID = explicitID
            } else if let decodedWindow {
                self.windowID = decodedWindow.id
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.windowID,
                    DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing windowID and window")
                )
            }
            self.receipt = decodedReceipt
            self.window = PhoneRecordingSummaries.isTerminal(decodedReceipt?.state) ? nil : decodedWindow
        }
    }
    private struct State: Codable {
        let libraryID: UUID
        let connection: AgentConnection
        var items: [String: Item] = [:]
    }
    private var hasActiveItems: Bool {
        saved.items.values.contains { $0.window != nil && !Self.isTerminal($0.receipt?.state) }
    }
    init(directory: URL, archive: ArchiveStore, connection: AgentConnection, client: AgentClient) throws {
        self.archive = archive; self.client = client
        file = directory.appendingPathComponent("recording-summaries.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let rawData = try Data(contentsOf: file)
            saved = try JSONDecoder().decode(State.self, from: rawData)
            guard saved.libraryID == archive.libraryInstanceID, saved.connection.hasSameIdentity(as: connection) else {
                throw PhoneContextSync.SyncError.identity
            }
            // Compact legacy multi-MB files that retained full TimelineWindow payloads on terminal items.
            if rawData.count > 256 * 1024 {
                try? commit(saved)
            }
        } else { saved = State(libraryID: archive.libraryInstanceID, connection: connection) }
    }

    func cachedSummaries(for revisions: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for revision in revisions {
            if let receipt = saved.items[revision]?.receipt,
               receipt.state == "done",
               let text = receipt.text, !text.isEmpty {
                result[revision] = text
            }
        }
        return result
    }

    func summaries(for windows: [TimelineWindow]) async throws -> [String: String] {
        let eligible = windows.filter(\.canSummarize)
        let valid = try await archive.validTimelineSummaryRevisions(eligible)
        var updated = saved
        for window in eligible where valid.contains(window.summaryRevision) {
            let revision = window.summaryRevision
            if updated.items[revision] == nil {
                // Coalesce superseded windows before admission; already accepted jobs stay on Mac.
                updated.items = updated.items.filter { $0.value.windowID != window.id }
                updated.items[revision] = Item(window: window)
            }
        }
        if updated.items.keys != saved.items.keys { try commit(updated) }
        if active { refresh() }
        return saved.items.reduce(into: [:]) { result, entry in
            if valid.contains(entry.key), let receipt = entry.value.receipt,
               receipt.state == "done", let text = receipt.text, !text.isEmpty { result[entry.key] = text }
        }
    }

    func foreground() {
        active = true
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func background() {
        active = false; polling?.cancel(); polling = nil
        inFlight?.cancel() // Detaches only. Never cancels a Mac run.
    }
    private func refresh() {
        guard inFlight == nil, hasActiveItems else { return }
        inFlight = Task { [weak self] in
            guard let self else { return }
            defer { inFlight = nil }
            do { try await synchronize(); failure = nil }
            catch is CancellationError { }
            catch {
                if case AgentClientError.http(401, _, _, _) = error {
                    background(); onAuthenticationRequired?(error)
                }
                failure = String(localized: "录音总结尚未完成，连接 Mac 后会继续。")
            }
        }
    }
    private func synchronize() async throws {
        var pendingWindows: [String: TimelineWindow] = [:]
        for (revision, item) in saved.items where !Self.isTerminal(item.receipt?.state) {
            if let window = item.window {
                pendingWindows[revision] = window
            }
        }
        guard !pendingWindows.isEmpty else { return }
        let valid = try await archive.validTimelineSummaryRevisions(Array(pendingWindows.values))
        var updated = saved
        var dirty = false
        for revision in pendingWindows.keys where !valid.contains(revision) {
            updated.items[revision] = nil
            dirty = true
        }
        if dirty { try commit(updated); dirty = false }
        let orderedRevisions = pendingWindows.keys.filter { valid.contains($0) && saved.items[$0] != nil }.sorted { lhs, rhs in
            let lStart = saved.items[lhs]?.windowID.start ?? .distantPast
            let rStart = saved.items[rhs]?.windowID.start ?? .distantPast
            return lStart == rStart ? lhs < rhs : lStart > rStart
        }
        var firstError: Error?
        var anyCompleted = false
        for revision in orderedRevisions {
            try Task.checkCancellation()
            guard let item = saved.items[revision],
                  let window = item.window,
                  !Self.isTerminal(item.receipt?.state) else { continue }
            do {
                let receipt: RemoteSummaryReceipt
                if let id = item.receipt?.id {
                    do {
                        receipt = try await client.recordingSummary(id: id)
                    } catch let AgentClientError.http(status, _, _, _) where status == 404 || status == 409 {
                        receipt = try await client.summarizeRecording(libraryID: saved.libraryID, windowID: window.id.key, revision: revision, text: window.text)
                    }
                } else {
                    receipt = try await client.summarizeRecording(libraryID: saved.libraryID, windowID: window.id.key, revision: revision, text: window.text)
                }
                guard receipt.revision == revision, item.receipt == nil || item.receipt?.id == receipt.id,
                      ["pending", "running", "done", "needs_review", "superseded"].contains(receipt.state),
                      receipt.state != "done" || receipt.text?.isEmpty == false else { throw AgentClientError.invalidResponse }
                // The source may have changed while the network was suspended.
                let current = try await archive.validTimelineSummaryRevisions([window])
                guard current.contains(revision), saved.items[revision] != nil else { continue }
                if saved.items[revision]?.receipt != receipt {
                    saved.items[revision]?.receipt = receipt
                    if Self.isTerminal(receipt.state) {
                        saved.items[revision]?.window = nil
                    }
                    dirty = true
                    if receipt.state == "done" { anyCompleted = true }
                }
            } catch is CancellationError {
                if dirty { try? commit(saved) }
                throw CancellationError()
            } catch {
                if case AgentClientError.http(401, _, _, _) = error {
                    if dirty { try? commit(saved) }
                    throw error
                }
                if firstError == nil { firstError = error }
            }
        }
        if dirty { try commit(saved) }
        if anyCompleted { onChanged?() }
        if let firstError { throw firstError }
    }
    private func commit(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        saved = state
    }
}
