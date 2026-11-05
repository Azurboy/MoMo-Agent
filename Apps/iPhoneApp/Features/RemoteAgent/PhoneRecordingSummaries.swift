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
    private struct Item: Codable {
        let window: TimelineWindow
        var receipt: RemoteSummaryReceipt?
    }
    private struct State: Codable {
        let libraryID: UUID
        let connection: AgentConnection
        var items: [String: Item] = [:]
    }
    init(directory: URL, archive: ArchiveStore, connection: AgentConnection, client: AgentClient) throws {
        self.archive = archive; self.client = client
        file = directory.appendingPathComponent("recording-summaries.json")
        if FileManager.default.fileExists(atPath: file.path) {
            saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard saved.libraryID == archive.libraryInstanceID, saved.connection.hasSameIdentity(as: connection) else {
                throw PhoneContextSync.SyncError.identity
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
                updated.items = updated.items.filter { $0.value.window.id != window.id }
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
        guard inFlight == nil, !saved.items.isEmpty else { return }
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
        let candidates = saved.items
        let valid = try await archive.validTimelineSummaryRevisions(candidates.values.map(\.window))
        var updated = saved
        var dirty = false
        for revision in candidates.keys where !valid.contains(revision) {
            updated.items[revision] = nil
            dirty = true
        }
        if dirty { try commit(updated); dirty = false }
        let orderedRevisions = saved.items.keys.sorted { lhs, rhs in
            let lStart = saved.items[lhs]?.window.id.start ?? .distantPast
            let rStart = saved.items[rhs]?.window.id.start ?? .distantPast
            return lStart == rStart ? lhs < rhs : lStart > rStart
        }
        var firstError: Error?
        var anyCompleted = false
        for revision in orderedRevisions {
            try Task.checkCancellation()
            guard let item = saved.items[revision],
                  item.receipt?.state != "done",
                  item.receipt?.state != "needs_review",
                  item.receipt?.state != "superseded" else { continue }
            do {
                let receipt: RemoteSummaryReceipt
                if let id = item.receipt?.id {
                    do {
                        receipt = try await client.recordingSummary(id: id)
                    } catch let AgentClientError.http(status, _, _, _) where status == 404 || status == 409 {
                        receipt = try await client.summarizeRecording(libraryID: saved.libraryID, windowID: item.window.id.key, revision: revision, text: item.window.text)
                    }
                } else {
                    receipt = try await client.summarizeRecording(libraryID: saved.libraryID, windowID: item.window.id.key, revision: revision, text: item.window.text)
                }
                guard receipt.revision == revision, item.receipt == nil || item.receipt?.id == receipt.id,
                      ["pending", "running", "done", "needs_review", "superseded"].contains(receipt.state),
                      receipt.state != "done" || receipt.text?.isEmpty == false else { throw AgentClientError.invalidResponse }
                // The source may have changed while the network was suspended.
                let current = try await archive.validTimelineSummaryRevisions([item.window])
                guard current.contains(revision), saved.items[revision] != nil else { continue }
                if saved.items[revision]?.receipt != receipt {
                    saved.items[revision]?.receipt = receipt
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
