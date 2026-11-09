import Foundation
import os
import MoMoArchive
import MoMoContracts
import MoMoLink
import WatchConnectivity

@MainActor
final class PhoneReceiveCoordinator {
    private let archive: ArchiveStore
    private let controls: ControlInbox
    private let identity: ReceiverIdentity
    private var transport: WatchConnectivityTransport?
    private var active = false
    private(set) var peerState: LinkPeerState = .notPaired
    private(set) var currentWatchStatus: WatchStatusObservation?
    private var selectedWatchContext: SelectedWatchContext?
    private var pendingWatchStatusSequence: UInt64 = 0
    private var selectedWatchWatermark: StatusSnapshot?
    private var statusDeletionGeneration: UInt64 = 0
    private var draining = false
    private var requested = false
    private var submittingResponseID: UUID?
    private var submissionFailed = false
    private var controlFailures = LinkControlFailureState()
    private let recoverySleep: @Sendable (Duration) async throws -> Void
    private var recoveryTask: Task<Void, Never>?
    private var recoveryID: UUID?
    private var recoveryBackoff = LinkRetryBackoff()
    private var previousPendingCount: Int?
    private var replayPendingControls = false
    private var receiptCursor: Int64 = 0
    private var replayReceiptSweep = false
    private var pendingInboxRecovery = false
    private let logger = Logger(subsystem: "com.momoagent.ios", category: "WatchStatus")
    var onChanged: @MainActor () async -> Void = {}
    var onAudioReceived: @MainActor (UUID) -> Void = { _ in }
    var onStatusChanged: @MainActor () async -> Void = {}
    var onCurrentWatchStatusChanged: @MainActor (WatchStatusObservation?) -> Void = { _ in }
    var onStatusFailure: @MainActor (String?) -> Void = { _ in }
    var onFailure: @MainActor (String) -> Void = { _ in }
    var onSyncFailure: @MainActor (String?) -> Void = { _ in }

    init(archive: ArchiveStore, controls: ControlInbox, identity: ReceiverIdentity,
         recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.archive = archive
        self.controls = controls
        self.identity = identity
        self.recoverySleep = recoverySleep
    }

    deinit { recoveryTask?.cancel() }

    func attach(_ transport: WatchConnectivityTransport) { self.transport = transport }

    /// Answers interactive Watch control requests over `replyHandler` even while a staged companion update reports `companionNotInstalled`.
    func inlineControlReply(for message: ControlMessage) async -> ControlMessage? {
        guard case .reconcileRequest(let request) = message else { return nil }
        if let transport { peerState = transport.peerState }
        do {
            let response = try await archive.receiveReconcileRequest(request)
            // Interactive replyHandler directly delivers the ReconcileResponse to Watch; marking it
            // submitted prevents reconcile() from flooding WatchConnectivity transferUserInfo with
            // hundreds of duplicate responses ahead of outbound receipts. If the reply is lost in
            // transit, Watch retains its reconciliation_round.request_id and retries the request.
            try await archive.markReconcileResponseSubmitted(messageID: response.messageID)
            try? controls.remove(message)
            return .reconcileResponse(response)
        } catch ArchiveReconciliationError.receiverMismatch {
            try? transport?.allowControlReplay(.receiverIdentity(identity))
            try? controls.remove(message)
            onStatusFailure(String(localized: "已忽略发给其他手机的对账请求，将发送本机接收身份。"))
            return .receiverIdentity(identity)
        } catch ArchiveReconciliationError.libraryMismatch {
            try? transport?.allowControlReplay(.receiverIdentity(identity))
            try? controls.remove(message)
            onStatusFailure(String(localized: "手表的对账请求属于旧资料库，将发送当前资料库身份。"))
            return .receiverIdentity(identity)
        } catch {
            logger.error("Inline reconcile reply deferred: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func receive(_ event: LinkEvent) async {
        if let transport { peerState = transport.peerState }
        switch event {
        case .audioBlockCommitted(let chunkID):
            onAudioReceived(chunkID)
            await onChanged()
        case .statusRefreshRequested:
            await publishStatus(refreshObservation: true)
            return
        case .selectedWatchChanged(let context):
            await selectWatch(context)
            return
        case .selectedWatchStatusReceived(let snapshot, let origin, let context):
            let previousSource = selectedWatchWatermark?.sourceDeviceID
            await selectWatch(context)
            let mayPresent = context.isAvailable && selectedWatchContext?.epoch == context.epoch
                && context.sequence > pendingWatchStatusSequence
            if mayPresent { pendingWatchStatusSequence = context.sequence }
            await receiveStatus(snapshot, origin: origin, context: context)
            if selectedWatchWatermark?.sourceDeviceID != previousSource {
                await publishStatus(refreshObservation: true)
                await reconcile()
            }
            return
        case .selectedWatchStatusFailed(let failure, let context):
            await selectWatch(context)
            logger.error("Watch status decoding failed: \(failure.domain, privacy: .public) / \(failure.code)")
            guard context.isAvailable, selectedWatchContext?.epoch == context.epoch,
                  context.sequence > pendingWatchStatusSequence else { return }
            pendingWatchStatusSequence = context.sequence
            onStatusFailure(String(localized: "手表状态暂时无法更新，请稍后重试。"))
            return
        case .statusReceived(let snapshot, let origin):
            // Unscoped reports are history only. A remote payload cannot select the active Watch.
            await receiveStatus(snapshot, origin: origin, context: nil)
            return
        case .activationChanged(let state):
            active = state == .activated
            if active { transport?.requestPeerStatus() }
        case .failed(let failure): reportTransportFailure(failure, context: String(localized: "设备传输失败"))
        case .controlTransportFinished(let message, let failure):
            do {
                if message == .receiverIdentity(identity), receiverConfigurationIsApplied {
                    try confirmControlDelivery(message)
                    await reconcile()
                    return
                }
                if try await retireForeignControlFailure(message) {
                    await reconcile()
                    return
                }
                let applied = try await archive.controlWasApplied(message)
                // Recheck the transport proof after the actor hop. An inbox reply may
                // have confirmed this exact command while the older failure was suspended.
                let preserved = try transport?.controlDeliveryIsConfirmed(message) ?? false
                if applied || preserved {
                    if case .reconcileResponse(let response) = message {
                        try await archive.markReconcileResponseSubmitted(messageID: response.messageID)
                    }
                    try confirmControlDelivery(message)
                    await reconcile()
                    return
                }
            } catch { onFailure(String(localized: "无法核对同步指令回执：\(error.localizedDescription)")); return }
            if let failure {
                if case .reconcileResponse(let response) = message {
                    if submittingResponseID == response.messageID { submissionFailed = true }
                    do {
                        if try await requeueResponse(response) == .superseded {
                            await reconcile()
                            return
                        }
                    }
                    catch {
                        onFailure(String(localized: "无法保存设备对账重试：\(error.localizedDescription)"))
                        return
                    }
                }
                logger.error("Control transfer failed: \(failure.domain, privacy: .public) / \(failure.code)")
            }
            do {
                try controlFailures.didFinish(message, failure: failure)
                publishControlFailure()
            } catch { onFailure(String(localized: "无法核对同步指令状态：\(error.localizedDescription)")) }
        default: break
        }
        await reconcile()
    }

    private func receiveStatus(_ snapshot: StatusSnapshot, origin: StatusReceptionOrigin,
                               context: SelectedWatchContext?) async {
        let deletionGeneration = statusDeletionGeneration
        do {
            let result = try await archive.receiveWatchStatusReport(snapshot, restored: origin == .restoredApplicationContext)
            guard deletionGeneration == statusDeletionGeneration else { return }
            if let context, isCurrent(context), let directory = context.directoryURL {
                guard let observation = result.observation else {
                    setCurrentStatus(nil)
                    return
                }
                if let previous = selectedWatchWatermark,
                   previous.sourceDeviceID == observation.snapshot.sourceDeviceID,
                   previous.sourceStoreInstanceID == observation.snapshot.sourceStoreInstanceID {
                    guard observation.snapshot.revision >= previous.revision else { return }
                    if observation.snapshot.revision == previous.revision {
                        guard observation.snapshot == previous else { throw ArchiveStatusError.conflictingRevision }
                        onStatusFailure(nil)
                        return // A duplicate never renews a cached report's freshness.
                    }
                }
                try SelectedWatchStatusFile.write(observation.snapshot, directory: directory, libraryID: archive.libraryInstanceID)
                setSelectedWatchWatermark(observation.snapshot)
                setCurrentStatus(origin == .restoredApplicationContext
                    ? WatchStatusObservation(snapshot: observation.snapshot, observedAt: nil, restored: true) : observation)
                if receiverConfigurationIsApplied { try confirmControlDelivery(.receiverIdentity(identity)) }
            }
            if let context, isCurrent(context) { onStatusFailure(nil) }
            if result.changed { await onStatusChanged() }
        } catch ArchiveStatusError.receiverMismatch {
            guard deletionGeneration == statusDeletionGeneration, let context, isCurrent(context) else { return }
            if case .watch(let status) = snapshot.payload, status.receiverLibraryInstanceID == nil {
                // A first recording can precede the identity handshake. Offer our identity without trusting the status.
                do {
                    if active, let transport, transport.peerState == .available {
                        try transport.allowControlReplay(.receiverIdentity(identity))
                        try transport.transferControl(.receiverIdentity(identity))
                    }
                } catch { onStatusFailure(String(localized: "手表连接身份尚未发送，请稍后重试。")) }
            } else {
                onStatusFailure(String(localized: "手表尚未确认当前资料库，请在手表的“录音信息”中确认连接。"))
            }
        } catch {
            logger.error("Watch status rejected: \(String(describing: error), privacy: .public)")
            guard deletionGeneration == statusDeletionGeneration, let context, isCurrent(context) else { return }
            onStatusFailure(String(localized: "手表状态暂时无法更新，请稍后重试。"))
        }
    }

    @discardableResult private func advanceSelection(_ context: SelectedWatchContext) -> Bool {
        guard context.sequence > (selectedWatchContext?.sequence ?? 0) else { return false }
        let changed = selectedWatchContext?.epoch != context.epoch
        selectedWatchContext = context
        if changed {
            pendingWatchStatusSequence = 0
            setSelectedWatchWatermark(nil)
            setCurrentStatus(nil)
            onStatusFailure(nil)
        }
        return changed
    }

    private func selectWatch(_ context: SelectedWatchContext) async {
        guard advanceSelection(context), context.isAvailable, let directory = context.directoryURL else { return }
        let deletionGeneration = statusDeletionGeneration
        do {
            guard let cached = try SelectedWatchStatusFile.read(directory: directory, libraryID: archive.libraryInstanceID) else { return }
            let result = try await archive.receiveWatchStatusReport(cached, restored: true)
            guard deletionGeneration == statusDeletionGeneration,
                  selectedWatchContext?.epoch == context.epoch, pendingWatchStatusSequence == 0,
                  let observation = result.observation else { return }
            setSelectedWatchWatermark(observation.snapshot)
            setCurrentStatus(WatchStatusObservation(snapshot: observation.snapshot, observedAt: nil, restored: true))
        } catch {
            guard deletionGeneration == statusDeletionGeneration,
                  selectedWatchContext?.epoch == context.epoch, pendingWatchStatusSequence == 0 else { return }
            onStatusFailure(String(localized: "当前手表的上次状态暂时无法读取，请在手表上打开 App 更新。"))
        }
    }

    private func isCurrent(_ context: SelectedWatchContext) -> Bool {
        selectedWatchContext?.epoch == context.epoch && selectedWatchContext?.isAvailable == true
            && pendingWatchStatusSequence == context.sequence
    }

    private func setSelectedWatchWatermark(_ snapshot: StatusSnapshot?) {
        if selectedWatchWatermark?.sourceDeviceID != snapshot?.sourceDeviceID {
            receiptCursor = 0
            replayReceiptSweep = true
        }
        selectedWatchWatermark = snapshot
    }

    private func setCurrentStatus(_ observation: WatchStatusObservation?) {
        var previousActivity: WatchCaptureActivity?
        if let previous = currentWatchStatus, case .watch(let report) = previous.snapshot.payload { previousActivity = report.activity }
        if let observation, case .watch(let report) = observation.snapshot.payload, previousActivity != report.activity {
            logger.notice("Watch capture observation: \(report.activity.rawValue, privacy: .public), build=\(observation.snapshot.sourceBuild, privacy: .public), restored=\(observation.restored)")
        }
        currentWatchStatus = observation
        onCurrentWatchStatusChanged(observation)
    }

    func clearDeletedStatus(sessionID: UUID) {
        // Archive validation can finish before its MainActor continuation; invalidate those outstanding reads too.
        statusDeletionGeneration &+= 1
        guard let observation = currentWatchStatus, case .watch(let status) = observation.snapshot.payload,
              status.sessionID == sessionID else { return }
        setCurrentStatus(nil)
    }

    func reconcile() async {
        // Receiving a background file is not a user viewing live Watch status.
        requested = true
        pendingInboxRecovery = true
        guard !draining else { return }
        draining = true
        var checkedRecovery = false
        // Until both local inboxes have been checked, cancellation cannot mean that no work remains.
        defer {
            draining = false
            if !checkedRecovery {
                Task { @MainActor [weak self] in await self?.scheduleAutomaticRecovery() }
            }
        }
        while requested {
            checkedRecovery = false
            guard !Task.isCancelled else { return }
            requested = false
            pendingInboxRecovery = true
            var contentsChanged = false
            do {
                // Release the shared Inbox lock between bounded pages so a live WC reply can persist promptly.
                let batch = try controls.loadBackgroundPage(limit: 32)
                if batch.hasMore { requested = true }
                if let failure = batch.failures.first { onFailure(failure) }
                for message in batch.messages {
                    guard !Task.isCancelled else { return }
                    do {
                        switch message {
                        case .receiptApplied(let value):
                            try await archive.applyReceipt(value)
                            try confirmControlDelivery(.receipt(value.receipt))
                        case .deleteApplied(let value): try await archive.applyDeletionAcknowledgement(value)
                        case .epochEnded(let value): try await archive.receiveEpochEnd(value); contentsChanged = true
                        case .epochInterrupted(let value): try await archive.receiveEpochInterruption(value); contentsChanged = true
                        case .captureMark(let value): try await archive.receiveMark(value); contentsChanged = true
                        case .reconcileRequest(let value):
                            do {
                                let response = try await archive.receiveReconcileRequest(value)
                                try transport?.allowControlReplay(.reconcileResponse(response))
                            }
                            catch ArchiveReconciliationError.receiverMismatch {
                                try? transport?.allowControlReplay(.receiverIdentity(identity))
                                onStatusFailure(String(localized: "已忽略发给其他手机的对账请求，将发送本机接收身份。"))
                            } catch ArchiveReconciliationError.libraryMismatch {
                                try? transport?.allowControlReplay(.receiverIdentity(identity))
                                onStatusFailure(String(localized: "手表的对账请求属于旧资料库，将发送当前资料库身份。"))
                            }
                        default: throw PhoneReceiveError.unexpectedControl
                        }
                        try controls.remove(message)
                    } catch {
                        onFailure(String(localized: "一条设备同步消息尚未处理：\(error.localizedDescription)"))
                    }
                }
            } catch { onFailure(String(localized: "无法读取设备同步消息：\(error.localizedDescription)")) }
            do {
                let inboxPageLimit = 64
                let listed = try await archive.listPendingInboxItems(limit: inboxPageLimit + 1)
                if listed.count > inboxPageLimit {
                    requested = true
                }
                var notifiedFirstAccepted = false
                var lastChangedNotificationUptime = Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
                // Process bounded pages so outbound receipts/reconcile responses and live transcription
                // are never starved behind a large inbox. Keep Receipt/ReceiveResult strictly synchronous
                // and out of async suspension frames.
                for item in listed.prefix(inboxPageLimit) {
                    guard !Task.isCancelled else { return }
                    var shouldNotifyChangedNow = false
                    do {
                        switch try await archive.commitInboxItemForCoordinator(item) {
                        case .missing:
                            contentsChanged = true
                            onFailure(String(localized: "已接收的原音文件缺失，请在资料库检查。"))
                        case .accepted(let acceptedID):
                            contentsChanged = true
                            onAudioReceived(acceptedID.uuidValue)
                            let nowUptime = Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
                            if !notifiedFirstAccepted || nowUptime - lastChangedNotificationUptime >= 4.0 {
                                notifiedFirstAccepted = true
                                lastChangedNotificationUptime = nowUptime
                                shouldNotifyChangedNow = true
                            }
                        case .ignored:
                            break
                        }
                    } catch {
                        // A failed repair can already have marked the original unavailable.
                        contentsChanged = true
                        onFailure(String(localized: "音频尚未接收完成：\(error.localizedDescription)"))
                    }
                    if shouldNotifyChangedNow {
                        contentsChanged = false
                        await onChanged()
                    }
                }
            } catch { onFailure(String(localized: "音频收件处理未完成：\(error.localizedDescription)")) }
            do {
                let hasPendingControls = try controls.hasPending()
                let hasPendingAudio = !(try await archive.listPendingInboxItems(limit: 1)).isEmpty
                pendingInboxRecovery = hasPendingControls || hasPendingAudio
            } catch {
                pendingInboxRecovery = true
                onFailure(String(localized: "本机同步收件尚未核对：\(error.localizedDescription)"))
            }
            do {
                if active, let transport, transport.peerState == .available {
                    let replay = replayPendingControls
                    replayPendingControls = false
                    if replay { replayReceiptSweep = true }
                    let receiver = ControlMessage.receiverIdentity(identity)
                    if receiverConfigurationIsApplied {
                        try confirmControlDelivery(receiver)
                    } else {
                        if replay { try transport.allowControlReplay(receiver) }
                        try transport.transferControl(receiver)
                    }
                    if selectedWatchWatermark == nil, (try? await archive.pendingReceiptCount(sourceDeviceID: nil)) ?? 0 > 0 {
                        transport.requestPeerStatus()
                    }
                    for deletion in try await archive.pendingDeletions() {
                        let message = ControlMessage.deleteSession(deletion)
                        if replay { try transport.allowControlReplay(message) }
                        let routes = try transport.transferControlRoutes(message)
                        if routes.background == .deferred && routes.interactive != .submitted && routes.interactive != .alreadySubmitted { break }
                    }
                    await submitPendingControls(submit: { try transport.transferControlRoutes($0) },
                        replay: { try transport.allowControlReplay($0) }, retrying: transport.hasDueControlRetries)
                }
            } catch { reportTransportFailure(TransportFailure(error), context: String(localized: "设备同步尚未完成")) }
            do {
                for message in controlFailures.failedMessages {
                    if try await retireForeignControlFailure(message) { continue }
                    if try await archive.controlWasApplied(message) { try confirmControlDelivery(message) }
                }
            } catch { onFailure(String(localized: "无法核对同步指令回执：\(error.localizedDescription)")) }
            if contentsChanged { await onChanged() }
            await publishStatus()
            await scheduleAutomaticRecovery()
            checkedRecovery = true
        }
    }

    private func confirmControlDelivery(_ message: ControlMessage) throws {
        try transport?.confirmControlDelivery(message)
        try controlFailures.didFinish(message, failure: nil)
        publishControlFailure()
    }

    // A fresh selected-Watch report confirms this configuration value, never any file or unrelated command.
    private var receiverConfigurationIsApplied: Bool {
        guard selectedWatchContext?.isAvailable == true, let observation = currentWatchStatus,
              !observation.restored, observation.observedAt != nil,
              case .watch(let value) = observation.snapshot.payload else { return false }
        return value.receiverLibraryInstanceID == identity.libraryInstanceID
    }

    private func retireForeignControlFailure(_ message: ControlMessage) async throws -> Bool {
        guard let source = selectedWatchWatermark?.sourceDeviceID else { return false }
        let messageSource: UUID?
        switch message {
        case .receipt(let receipt): messageSource = try await archive.sourceDeviceID(for: receipt)
        case .reconcileResponse(let response): messageSource = response.sourceDeviceID
        default: return false
        }
        guard let messageSource, messageSource != source,
              selectedWatchWatermark?.sourceDeviceID == source else { return false }
        try transport?.stopRetryingControl(message)
        try controlFailures.didFinish(message, failure: nil)
        publishControlFailure()
        return true
    }

    func dismissFailures() {
        controlFailures.dismissCurrentFailures()
        onSyncFailure(nil)
    }

    private func publishControlFailure() {
        onSyncFailure(controlFailures.failure(where: { !isTransientTransportFailure($0) }).map {
            String(localized: "设备同步暂未完成，正在自动重试：\($0.diagnosticDescription)")
        })
    }

    private func isTransientTransportFailure(_ failure: TransportFailure) -> Bool {
        WatchConnectivityTransport.isTransientChannelFailure(failure)
    }

    private func reportTransportFailure(_ failure: TransportFailure, context: String) {
        if isTransientTransportFailure(failure) {
            logger.notice("Watch connectivity transient failure; sync retained for retry: \(failure.domain, privacy: .public) / \(failure.code)")
            return
        }
        onFailure("\(context)：\(failure.diagnosticDescription)")
    }

    // One response per pass leaves capacity for receipts, including while its interactive route is retrying.
    func submitPendingControls(
        submit: (ControlMessage) throws -> (background: ControlSubmissionResult, interactive: ControlSubmissionResult),
        replay: (ControlMessage) throws -> Void,
        retrying: Bool
    ) async {
        guard let source = selectedWatchWatermark?.sourceDeviceID else { return }
        do {
            if let response = try await archive.pendingReconcileResponses(limit: 1, sourceDeviceID: source).first,
               selectedWatchWatermark?.sourceDeviceID == source {
                let admission = try await submitResponse(response, submit: submit)
                if admission == .submitted || admission == .alreadySubmitted { requested = true }
            }
        } catch { reportTransportFailure(TransportFailure(error), context: String(localized: "设备对账尚未完成")) }
        do { try await submitReceiptPage(submit: submit, replay: replay, retrying: retrying) }
        catch { reportTransportFailure(TransportFailure(error), context: String(localized: "录音接收回执尚未发送")) }
    }

    private func submitReceiptPage(
        submit: (ControlMessage) throws -> (background: ControlSubmissionResult, interactive: ControlSubmissionResult),
        replay: (ControlMessage) throws -> Void,
        retrying: Bool
    ) async throws {
        guard let source = selectedWatchWatermark?.sourceDeviceID else { return }
        if retrying { receiptCursor = 0 }
        for failedMessage in controlFailures.failedMessages {
            guard selectedWatchWatermark?.sourceDeviceID == source else { return }
            guard case .receipt(let receipt) = failedMessage,
                  try await archive.sourceDeviceID(for: receipt) == source,
                  !(try await archive.controlWasApplied(failedMessage)) else { continue }
            if replayReceiptSweep { try replay(failedMessage) }
            let routes = try submit(failedMessage)
            guard routes.background != .deferred || routes.interactive == .submitted || routes.interactive == .alreadySubmitted else { return }
        }
        let page = try await archive.pendingReceiptPage(after: receiptCursor, sourceDeviceID: source)
        for entry in page.entries {
            guard selectedWatchWatermark?.sourceDeviceID == source else { return }
            let message = ControlMessage.receipt(entry.receipt)
            if replayReceiptSweep { try replay(message) }
            let routes = try submit(message)
            guard routes.background != .deferred || routes.interactive == .submitted || routes.interactive == .alreadySubmitted else { return }
            receiptCursor = entry.sequence
        }
        if page.hasMore {
            receiptCursor = page.scannedThrough
            requested = true
        } else {
            receiptCursor = 0
            replayReceiptSweep = false
        }
    }

    private func submitResponse(_ response: ReconcileResponse,
        submit: (ControlMessage) throws -> (background: ControlSubmissionResult, interactive: ControlSubmissionResult)
    ) async throws -> ControlSubmissionResult {
        submittingResponseID = response.messageID
        submissionFailed = false
        defer { submittingResponseID = nil; submissionFailed = false }
        let admission = try submit(.reconcileResponse(response)).background
        guard admission != .deferred, admission != .retryLater else { return admission }
        try await archive.markReconcileResponseSubmitted(messageID: response.messageID)
        // A failure callback may re-enter while the submitted-state write is awaiting the archive actor.
        if submissionFailed { try await requeueResponse(response) }
        return admission
    }

    @discardableResult private func requeueResponse(_ response: ReconcileResponse) async throws -> ReconcileResponseRequeueResult {
        let result = try await archive.requeueReconcileResponse(response)
        if result == .superseded {
            let message = ControlMessage.reconcileResponse(response)
            try transport?.stopRetryingControl(message)
            try controlFailures.didFinish(message, failure: nil)
            publishControlFailure()
            logger.notice("Retired failed response superseded by a persisted replacement; response=\(response.messageID.uuidString, privacy: .public)")
        }
        return result
    }

    private func scheduleAutomaticRecovery() async {
        var pending: Int?
        do {
            let receipts = try await archive.pendingReceiptCount(sourceDeviceID: selectedWatchWatermark?.sourceDeviceID)
            let deletions = try await archive.pendingDeletions().count
            let responses = try await archive.pendingReconcileResponses(limit: 1,
                sourceDeviceID: selectedWatchWatermark?.sourceDeviceID).count
            pending = receipts + deletions + responses + (pendingInboxRecovery ? 1 : 0)
        } catch { onFailure(String(localized: "同步待办尚未读取：\(error.localizedDescription)")) }
        // A failed read leaves the work state unknown, not empty. Keep one bounded recovery task.
        if pending == 0 && transport?.hasRetryableControls != true {
            recoveryTask?.cancel(); recoveryTask = nil; recoveryID = nil
            previousPendingCount = 0; recoveryBackoff.reset()
            return
        }
        if let pending, let previousPendingCount, pending < previousPendingCount {
            recoveryTask?.cancel(); recoveryTask = nil; recoveryID = nil
            recoveryBackoff.reset()
        }
        if let pending { previousPendingCount = pending }
        guard recoveryTask == nil else { return }
        let id = UUID()
        var delay = recoveryBackoff.nextDelay()
        if let hint = transport?.nextRetryDelay(), hint > 0 {
            delay = min(delay, max(1, hint.rounded(.up)))
        }
        recoveryID = id
        recoveryTask = Task { @MainActor [weak self, recoverySleep] in
            do { try await recoverySleep(.seconds(delay)) }
            catch is CancellationError { return }
            catch {
                guard let self, self.recoveryID == id else { return }
                self.recoveryTask = nil; self.recoveryID = nil
                self.onFailure(String(localized: "自动同步重试尚未安排：\(error.localizedDescription)"))
                return
            }
            guard !Task.isCancelled, let self, self.recoveryID == id else { return }
            self.recoveryTask = nil; self.recoveryID = nil
            self.replayPendingControls = true
            await self.reconcile()
        }
    }

    func publishStatus(refreshObservation: Bool = false) async {
        do { try await archive.writeSyncDiagnostic() }
        catch { logger.notice("Receive diagnostic deferred: \(String(describing: error), privacy: .public)") }
        guard active, let transport, transport.peerState == .available else { return }
        do {
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
            let snapshot = try await archive.phoneStatus(sourceBuild: build, sourceDeviceID: selectedWatchWatermark?.sourceDeviceID,
                refreshObservation: refreshObservation)
            guard active, transport.peerState == .available else { return }
            try transport.updateStatus(snapshot)
        } catch { reportTransportFailure(TransportFailure(error), context: String(localized: "手机处理状态尚未同步")) }
    }
}

enum PhoneReceiveError: Error { case unexpectedControl }
