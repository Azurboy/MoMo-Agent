import Foundation
import os
import WatchKit
import MoMoLink

/// Keeps the OS grant alive until WCSession activates and its incoming delivery queue drains.
@MainActor
final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    private var runtime: WatchRuntime?
    private(set) var failure: String?
    private let connectivityTasks = LinkRefreshTasks<ObjectIdentifier>()
    private var drain: Task<Void, Never>?
    private var drainID: UUID?
    private var recoveryDate: Date?
    private var recoveryRequestID: UUID?
    private var recoveryRequested = false
    private let logger = Logger(subsystem: "com.momoagent.ios.watchkitapp", category: "AutomaticSync")

    func resolveRuntime() throws -> WatchRuntime {
        if let runtime { return runtime }
        let created = try WatchComposition.make()
        created.onBackgroundRetryNeeded = { [weak self] in self?.scheduleRecovery() }
        runtime = created
        failure = nil
        beginDrain()
        return created
    }

    func applicationDidFinishLaunching() {
        do { _ = try resolveRuntime() }
        catch { failure = String(localized: "后台录音资料未能打开：\(error.localizedDescription)") }
    }

    func applicationDidEnterBackground() {
        if let runtime, runtime.pendingChunkCount > 0 { scheduleRecovery() }
    }

    private func scheduleRecovery() {
        let now = Date()
        guard recoveryDate.map({ $0 <= now }) ?? true else { return }
        let id = UUID()
        let date = now.addingTimeInterval(300)
        recoveryDate = date
        recoveryRequestID = id
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { @Sendable [weak self] error in
            guard let error else { return }
            let failure = TransportFailure(error)
            Task { @MainActor in
                guard let self, self.recoveryRequestID == id else { return }
                // A budget rejection must not cause another request on every inbox drain.
                self.recoveryRequestID = nil
                self.logger.warning("Background sync refresh deferred: \(failure.domain, privacy: .public) / \(failure.code)")
            }
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask {
                do {
                    let link = try resolveRuntime().macLink
                    if urlTask.sessionIdentifier == link.sessionID { link.handleRefresh(urlTask) }
                    else { urlTask.setTaskCompletedWithSnapshot(false) }
                } catch {
                    failure = String(localized: "后台录音资料未能打开：\(error.localizedDescription)")
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
            } else if task is WKWatchConnectivityRefreshBackgroundTask || task is WKApplicationRefreshBackgroundTask {
                if task is WKApplicationRefreshBackgroundTask {
                    recoveryDate = nil; recoveryRequestID = nil
                    recoveryRequested = true
                }
                let id = ObjectIdentifier(task)
                connectivityTasks.insert(id) {
                    task.expirationHandler = nil
                    task.setTaskCompletedWithSnapshot(false)
                }
                // WatchKit does not promise an actor for this callback. State stays on MainActor.
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.expireConnectivityTask(id) }
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        if runtime == nil {
            do { _ = try resolveRuntime() }
            catch {
                failure = String(localized: "后台录音资料未能打开：\(error.localizedDescription)")
                completeConnectivityTasks()
                return
            }
        }
        beginDrain()
    }

    private func beginDrain() {
        guard drain == nil, let runtime, !connectivityTasks.isEmpty else { return }
        if runtime.requiresConstrainedConnectivityGrant {
            runtime.beginConnectivityGrant()
        } else {
            runtime.beginBackgroundConnectivity()
        }
        let id = UUID()
        drainID = id
        drain = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // An expired drain must not complete tasks belonging to a newer OS grant.
                if self.drainID == id {
                    self.completeConnectivityTasks()
                    self.drain = nil
                    self.drainID = nil
                }
            }
            while !Task.isCancelled {
                guard let runtime = self.runtime else { return }
                if self.recoveryRequested {
                    self.recoveryRequested = false
                    await runtime.resumeSynchronization(flushAudio: false)
                }
                let outcome = runtime.isInConnectivityGrant
                    ? await runtime.drainBackgroundConnectivity()
                    : await runtime.drainActiveConnectivity(for: id)
                switch outcome {
                case .completed, .failed:
                    return
                case .pending: break
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch is CancellationError { return }
                catch { runtime.reportBackgroundFailure(error.localizedDescription); return }
            }
        }
    }

    private func completeConnectivityTasks() {
        runtime?.endConnectivityGrant()
        connectivityTasks.completeAll()
    }

    private func expireConnectivityTask(_ id: ObjectIdentifier) {
        guard connectivityTasks.contains(id) else { return }
        connectivityTasks.complete(id)
        guard connectivityTasks.isEmpty else { return }
        drain?.cancel()
        drain = nil
        drainID = nil
        runtime?.endConnectivityGrant()
    }
}
