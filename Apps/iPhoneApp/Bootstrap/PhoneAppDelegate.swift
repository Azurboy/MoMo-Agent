import Observation
import os
import UIKit
import UserNotifications
import MoMoAgentClient
import MoMoArchive
import MoMoContracts
import MoMoLink

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let bootstrap = PhoneBootstrap()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        bootstrap.background.register()
        PhoneContextDeliveryScheduler.register(bootstrap: bootstrap)
        // WatchConnectivity can launch the process without creating a SwiftUI scene.
        bootstrap.launch()
        bootstrap.runtime?.remoteAgent.notifications.start()
        if application.applicationState != .background {
            bootstrap.runtime?.remoteAgent.prewarmForLaunch()
        }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        bootstrap.initialize(); bootstrap.runtime?.remoteAgent.notifications.registered(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        bootstrap.runtime?.remoteAgent.notifications.registrationFailed()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let value = notification.request.content.userInfo["momo"] as? [AnyHashable:Any],
              let target = AgentNotificationTarget.parse(value) else { return [] }
        return await MainActor.run {
            guard let connection = bootstrap.runtime?.remoteAgent.connection, target.matches(connection) else { return [] }
            return bootstrap.runtime?.remoteAgent.notifications.shouldSuppress(target) == true ? [] : [.banner, .sound, .list]
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = response.notification.request.content.userInfo["momo"] as? [AnyHashable:Any],
              let target = AgentNotificationTarget.parse(value) else { return }
        await MainActor.run {
            bootstrap.initialize(); bootstrap.runtime?.remoteAgent.notifications.open(target)
        }
    }
}

@MainActor @Observable
final class PhoneBootstrap {
    private(set) var runtime: PhoneRuntime?
    private(set) var failure: String?
    @ObservationIgnored private let makeRuntime: @MainActor (PhoneBackgroundTasks) throws -> PhoneRuntime
    @ObservationIgnored lazy var background = PhoneBackgroundTasks { [weak self] in
        guard let self else { throw BackgroundTranscriptionError.runtimeUnavailable }
        initialize()
        guard let runtime else { throw BackgroundTranscriptionError.runtimeUnavailable }
        await runtime.start(backgroundOnly: true)
        return try runtime.backgroundCoordinator()
    }
    init(makeRuntime: @escaping @MainActor (PhoneBackgroundTasks) throws -> PhoneRuntime = {
        try PhoneComposition.make(background: $0)
    }) {
        self.makeRuntime = makeRuntime
    }

    func launch() {
        initialize()
        guard let runtime else { return }
        runtime.activateTransportIfNeeded()
        PhoneConnectivityTask.run { await runtime.start(backgroundOnly: true) }
    }

    func initialize() {
        guard runtime == nil else { return }
        do {
            runtime = try makeRuntime(background)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

/// Thread-safe background task token acquired synchronously on WCSessionDelegate or MainActor callbacks.
final class PhoneConnectivityGrant: Sendable {
    private struct State {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var workTask: Task<Void, Never>?
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(name: String = "Receive Watch recordings") {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.expire()
        }
        let finishImmediately = state.withLock { state -> Bool in
            if state.finished { return true }
            state.identifier = id
            return false
        }
        if finishImmediately, id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    func attach(_ task: Task<Void, Never>) {
        let cancelImmediately = state.withLock { state -> Bool in
            if state.finished { return true }
            state.workTask = task
            return false
        }
        if cancelImmediately { task.cancel() }
    }

    func finish() {
        let id = state.withLock { state -> UIBackgroundTaskIdentifier in
            state.finished = true
            state.workTask = nil
            let current = state.identifier
            state.identifier = .invalid
            return current
        }
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    private func expire() {
        let (task, id) = state.withLock { state -> (Task<Void, Never>?, UIBackgroundTaskIdentifier) in
            state.finished = true
            let work = state.workTask
            state.workTask = nil
            let current = state.identifier
            state.identifier = .invalid
            return (work, current)
        }
        task?.cancel()
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
    }
}

/// Finish durable inbox processing before suspension; the OS still controls transfer scheduling.
enum PhoneConnectivityTask {
    nonisolated static func beginSync() -> PhoneConnectivityGrant {
        PhoneConnectivityGrant()
    }

    @MainActor
    static func run(_ operation: @escaping @MainActor () async -> Void) {
        let grant = PhoneConnectivityGrant()
        let task = Task { @MainActor in
            defer { grant.finish() }
            await operation()
        }
        grant.attach(task)
    }

    nonisolated static func receiveAudioBlock(_ block: AudioBlock, archive: ArchiveStore) async throws -> AudioBlockReply {
        let grant = PhoneConnectivityGrant()
        defer { grant.finish() }
        do {
            return try await archive.receiveAudioBlock(block)
        } catch ArchiveReconciliationError.receiverMismatch, ArchiveError.staleSource {
            throw AudioBlockTransferError.rejected
        } catch ArchiveError.sessionDeleted {
            throw AudioBlockTransferError.rejected
        }
    }
}
