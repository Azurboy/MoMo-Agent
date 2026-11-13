import Foundation
import os
import MoMoLink
import MoMoRecording

@MainActor
enum WatchComposition {
    static func make() throws -> WatchRuntime {
        #if DEBUG && targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["MOMO_WATCH_TEST_RUN_ID"] {
            guard let runID = UUID(uuidString: value) else { throw WatchCompositionError.invalidTestIdentity }
            return try makeSimulatorTest(runID: runID).runtime
        }
        #endif
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let support = appSupport.appendingPathComponent("MoMoAgent", isDirectory: true)
        let runtime = try make(support: support)
        do {
            let publisher = WatchWidgetPublisher(store: try .shared())
            runtime.widgetPublisher = { snapshot in await publisher.publish(snapshot) }
        } catch {
            Logger(subsystem: "com.momoagent.ios.watchkitapp", category: "Widget")
                .error("Widget shared container unavailable: \(error.localizedDescription, privacy: .public)")
        }
        return runtime
    }

    private static func make(support: URL,
        archiveRecovery: @escaping @Sendable (RecordingStore) async throws -> RecordingRecoveryReport = { try await $0.recover() },
        recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws -> WatchRuntime {
        let directoryProtection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: directoryProtection)
        Self.applyProtection(to: support)
        let encoderDirectory = support.appendingPathComponent("Encoding", isDirectory: true)
        try FileManager.default.createDirectory(at: encoderDirectory, withIntermediateDirectories: true, attributes: directoryProtection)
        Self.applyProtection(to: encoderDirectory)

        let identityURL = support.appendingPathComponent("device-id")
        let deviceID: UUID
        if FileManager.default.fileExists(atPath: identityURL.path) {
            guard let saved = UUID(uuidString: try String(contentsOf: identityURL, encoding: .utf8)) else {
                throw WatchCompositionError.invalidIdentity
            }
            Self.applyProtection(to: identityURL)
            deviceID = saved
        } else {
            deviceID = UUID()
            try Data(deviceID.uuidString.utf8).write(
                to: identityURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            Self.applyProtection(to: identityURL)
        }
        let store = try RecordingStore(rootURL: support)
        let controls = try ControlInbox(directory: support.appendingPathComponent("ControlInbox", isDirectory: true))
        let events = WatchLinkEvents()
        let sourceBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let diagnosticsURL = support.appendingPathComponent("file-queue-diagnostic.json")
        if FileManager.default.fileExists(atPath: diagnosticsURL.path) {
            Self.applyProtection(to: diagnosticsURL)
        }
        let transport = try WatchConnectivityTransport(
            preserveFile: { _, _ in throw WatchCompositionError.unexpectedAudioFile },
            preserveControl: { try controls.preserve($0) },
            event: { event in Task { @MainActor in await events.runtime?.handleLinkEvent(event) } },
            diagnosticsURL: diagnosticsURL,
            statusReplyProvider: { viewing in
                guard let runtime = await events.runtime else { throw WatchCompositionError.runtimeUnavailable }
                return try await runtime.requestedStatusSnapshot(viewing: viewing)
            }
        )
        let runtime = WatchRuntime(store: store,
                                   encoderDirectory: encoderDirectory,
                                   sourceDeviceID: deviceID,
                                   sourceBuild: sourceBuild,
                                   controls: controls, transport: transport, macGrant: try WatchMacLink.saved(in: support),
                                   archiveRecovery: archiveRecovery, recoverySleep: recoverySleep)
        events.runtime = runtime
        Task.detached(priority: .utility) {
            Self.repairProtectionTree(at: support)
        }
        return runtime
    }

    nonisolated private static func applyProtection(to url: URL) {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    nonisolated static func repairProtectionTree(at directory: URL) {
        guard !Task.isCancelled else { return }
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isDirectory == true else { return }
        applyProtection(to: directory)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        for child in children {
            guard !Task.isCancelled else { return }
            guard let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  childValues.isSymbolicLink != true else { continue }
            if childValues.isDirectory == true {
                repairProtectionTree(at: child)
            } else {
                applyProtection(to: child)
            }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The simulator uses its real input device; only storage, provenance and WC delivery are isolated.
    static func makeSimulatorTest(runID: UUID,
        archiveRecovery: @escaping @Sendable (RecordingStore) async throws -> RecordingRecoveryReport = { try await $0.recover() },
        recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws -> (runtime: WatchRuntime, rootURL: URL) {
        var support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        for component in ["MoMoAgentSimulatorTests", runID.uuidString] {
            support.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: support.path) {
                let values = try support.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw WatchCompositionError.invalidTestDirectory
                }
                Self.applyProtection(to: support)
            } else {
                try FileManager.default.createDirectory(
                    at: support,
                    withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
                Self.applyProtection(to: support)
            }
        }
        let runtime = try make(support: support, archiveRecovery: archiveRecovery, recoverySleep: recoverySleep)
        runtime.configureSimulatorTestCapture()
        return (runtime, support)
    }
    #endif
}

@MainActor private final class WatchLinkEvents {
    weak var runtime: WatchRuntime?
}

enum WatchCompositionError: Error {
    case invalidIdentity, unexpectedAudioFile, runtimeUnavailable
    #if DEBUG && targetEnvironment(simulator)
    case invalidTestIdentity, invalidTestDirectory
    #endif
}
