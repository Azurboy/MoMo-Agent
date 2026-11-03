import Foundation
import Observation
import UIKit
import UserNotifications
import MoMoAgentClient

@MainActor @Observable
final class PhoneNotifications {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var status: AgentPushStatus?
    private(set) var busy = false
    private(set) var navigationRevision = 0
    private(set) var route = AgentNotificationRoute()
    private(set) var focusedTarget: AgentNotificationTarget?
    var chatVisible = false {
        didSet {
            if chatVisible { rendered(messageIDs: visibleMessageIDs, failedRunIDs: visibleFailedRuns) }
        }
    }
    var desktopVisible = false
    private(set) var visibleMessageIDs: Set<String> = []
    private(set) var visibleControlKeys: Set<String> = []
    private(set) var visibleFailedRuns: Set<String> = []
    @ObservationIgnored weak var agent: PhoneRemoteAgent?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var registrationID = UUID()
    @ObservationIgnored private var lastRegistrationAttempt: Date?
    @ObservationIgnored private var registeredID: UUID?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var revokePending = UserDefaults.standard.bool(forKey: "notifications.revokePending")
    @ObservationIgnored private var enabled = UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? true
    @ObservationIgnored private var polling: Task<Void,Never>?
    @ObservationIgnored private var failureReceiptIdentity: UUID?
    @ObservationIgnored private var reportedFailures: Set<String> = []
    @ObservationIgnored private var reportingFailures: Set<String> = []
    private var center: UNUserNotificationCenter { .current() }
    var title: String {
        if status?.configured != true { return String(localized: "暂未启用") }
        if !enabled || authorization == .denied { return String(localized: "已关闭") }
        return status?.registered == true ? String(localized: "已开启") : String(localized: "未开启")
    }
    var allowed: Bool { authorization == .authorized || authorization == .provisional || authorization == .ephemeral }

    func start() {
        Task {
            authorization = await center.notificationSettings().authorizationStatus
            registerIfNeeded()
        }
    }
    func foreground() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    func background() { polling?.cancel(); polling = nil; chatVisible = false }
    func registered(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        registrationID = UUID(); registeredID = nil
        Task { await refresh() }
    }
    func registrationFailed() { registeredID = nil; token = nil }
    private func registerIfNeeded() {
        guard allowed, enabled, token == nil,
              lastRegistrationAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastRegistrationAttempt = Date()
        UIApplication.shared.registerForRemoteNotifications()
    }
    func refresh() async {
        guard !refreshing, let agent, agent.store?.canContactServer != false, let client = agent.desktopClient else { return }
        refreshing = true
        let identity = agent.desktopClientID
        defer { refreshing = false }
        authorization = await center.notificationSettings().authorizationStatus
        registerIfNeeded()
        do {
            if revokePending || !enabled || authorization == .denied {
                try await client.revokePush()
                guard identity == agent.desktopClientID else { return }
                revokePending = false; UserDefaults.standard.set(false, forKey: "notifications.revokePending")
                registeredID = nil
            }
            let found = try await client.pushStatus()
            guard !Task.isCancelled, identity == agent.desktopClientID else { return }
            status = found
            if allowed && enabled, let token, registeredID != registrationID || found.enabled == false {
                guard let topic = Bundle.main.bundleIdentifier,
                      ["com.momoagent.ios", "com.momoagent.ios.beta"].contains(topic),
                      let environment = Bundle.main.object(forInfoDictionaryKey: "MoMoPushEnvironment") as? String,
                      ["development","production"].contains(environment) else { return }
                let registration = registrationID
                let result = try await client.registerPush(token: token, registrationID: registration,
                    topic: topic, environment: environment)
                guard !Task.isCancelled, identity == agent.desktopClientID else { return }
                registeredID = registration; status = result
            }
            await restoreTarget()
        } catch {
            // Push availability never replaces chat errors; only a proven revoked pairing stops its requests.
            guard identity == agent.desktopClientID else { return }
            if case AgentClientError.http(401, _, _, _) = error { agent.store?.recordConnectionFailure(error); route.clear() }
        }
    }
    func enable() async {
        guard !busy, status?.configured == true else { return }
        busy = true; defer { busy = false }
        if authorization == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert,.sound])
            authorization = await center.notificationSettings().authorizationStatus
            if granted {
                enabled = true; UserDefaults.standard.set(true, forKey: "notifications.enabled")
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch { /* Notification consent does not gate pairing, chat or recordings. */ }
    }
    func disable() async {
        enabled = false; revokePending = true
        UserDefaults.standard.set(false, forKey: "notifications.enabled")
        UserDefaults.standard.set(true, forKey: "notifications.revokePending")
        UIApplication.shared.unregisterForRemoteNotifications()
        await refresh()
    }
    func open(_ target: AgentNotificationTarget) {
        guard agent?.store?.canContactServer != false, route.open(target, connection: agent?.connection) else { return }
        focusedTarget = target
        navigationRevision += 1
        Task { await agent?.store?.retryConnection(ifNeeded: true); await restoreTarget() }
    }
    func shouldSuppress(_ target: AgentNotificationTarget) -> Bool {
        guard let connection = agent?.connection, target.matches(connection), chatVisible, !desktopVisible,
              UIApplication.shared.applicationState == .active else { return false }
        return target.isVisible(messageIDs: visibleMessageIDs, controlKeys: visibleControlKeys, failedRunIDs: visibleFailedRuns)
    }
    func rendered(messageIDs: Set<String>, failedRunIDs: Set<String>) {
        visibleMessageIDs = messageIDs; visibleFailedRuns = failedRunIDs
        guard chatVisible, !desktopVisible, UIApplication.shared.applicationState == .active, let store = agent?.store else { return }
        if let target = focusedTarget, target.messageID.map({ messageIDs.contains($0) }) == true { focusedTarget = nil }
        if let client = agent?.desktopClient, let identity = agent?.desktopClientID {
            if failureReceiptIdentity != identity {
                failureReceiptIdentity = identity; reportedFailures = []; reportingFailures = []
            }
            let fresh = failedRunIDs.subtracting(reportedFailures).subtracting(reportingFailures)
            if !fresh.isEmpty {
                reportingFailures.formUnion(fresh)
                Task {
                    defer { if failureReceiptIdentity == identity { reportingFailures.subtract(fresh) } }
                    do {
                        try await client.markFailedRunsVisible(fresh)
                        guard failureReceiptIdentity == identity else { return }
                        reportedFailures.formUnion(fresh)
                        await removeVisibleNotifications()
                    } catch { /* A later render retries the unacknowledged receipt. */ }
                }
            }
        }
        let rendered = store.messages.filter { $0.sourceSession == nil && messageIDs.contains($0.id) }
        guard let seq = rendered.map(\.seq).max() else { return }
        Task {
            if await store.markVisibleMessagesRead(through: seq) { await removeReadNotifications(through: store.acknowledgedReadSequence) }
            await restoreTarget()
        }
    }
    func controlVisible(_ run: AgentRun, _ control: AgentControl, visible: Bool) {
        guard let generation = run.executionGeneration else { return }
        let key = "\(run.runID):\(generation):\(control.promptID)"
        if visible { visibleControlKeys.insert(key) } else { visibleControlKeys.remove(key) }
        guard visible, chatVisible, !desktopVisible, UIApplication.shared.applicationState == .active else { return }
        Task { try? await agent?.desktopClient?.markControlsVisible([(run,control)]); await removeVisibleNotifications(); await restoreTarget() }
    }
    private func restoreTarget() async {
        guard let target = route.pending, let store = agent?.store else { return }
        if !target.matches(store.connection) || !store.canContactServer { route.clear(); return }
        // Keep an offline target until the real content/control has reached this client's cache.
        let received: Bool
        switch target.kind {
        case "final": received = target.messageID.map { id in store.messages.contains { $0.id == id } } ?? false
        case "failed": received = store.sharedRuns.contains { $0.runID == target.runID && $0.status == "failed" }
        case "needs_input":
            received = store.sharedRuns.contains { run in
                guard run.runID == target.runID else { return false }
                return run.isTerminal || (run.executionGeneration ?? 0) > (target.executionGeneration ?? 0) ||
                    (run.executionGeneration == target.executionGeneration && run.pendingControls?.contains { $0.promptID == target.controlID } == true)
            }
        default: received = false
        }
        if received { route.clear() }
    }
    private func removeVisibleNotifications() async {
        guard chatVisible, !desktopVisible, let connection = agent?.connection else { return }
        let delivered = await center.deliveredNotifications()
        let ids = delivered.compactMap { notification -> String? in
            guard let value = notification.request.content.userInfo["momo"] as? [AnyHashable:Any],
                  let target = AgentNotificationTarget.parse(value), target.matches(connection),
                  target.isVisible(messageIDs: visibleMessageIDs, controlKeys: visibleControlKeys, failedRunIDs: visibleFailedRuns) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    private func removeReadNotifications(through sequence: Int) async {
        guard let store = agent?.store else { return }
        let delivered = await center.deliveredNotifications()
        let ids = delivered.compactMap { notification -> String? in
            guard let value = notification.request.content.userInfo["momo"] as? [AnyHashable:Any],
                  let target = AgentNotificationTarget.parse(value), target.matches(store.connection),
                  let id = target.messageID, let message = store.messages.first(where: { $0.id == id }), message.seq <= sequence else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
