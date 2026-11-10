#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
import Foundation
import os
@preconcurrency import WatchConnectivity
import MoMoContracts

extension WatchConnectivityTransport {
    public var canTransferAudioBlocks: Bool {
        activation == .activated && session.isReachable && peerState == .available
            && audioBlockTask == nil && ProcessInfo.processInfo.systemUptime >= audioBlockRetryAt
    }
    public var hasActiveAudioBlockTransfer: Bool { audioBlockTask != nil }
    public var activeAudioBlockChunk: UUID? { audioBlockChunkID }

    /// Streams sealed originals directly over reachable interactive messaging and deduplicates against background transfers via durable Receipt.
    @discardableResult public func transferAudioBlocks(at file: URL, envelope: ManifestEnvelope,
        receiverDeviceID: UUID, libraryInstanceID: UUID, binaryFraming: Bool = false) throws -> Bool {
        guard canTransferAudioBlocks, envelope.manifest.byteCount <= AudioBlock.maximumFileBytes,
              try allowsInteractiveAudioBlockTransfer(envelope) else { return false }
        let generation = UUID()
        let shouldProbe = resumableAudioBlockChunkID == envelope.manifest.chunkID
        let sliceBytes = binaryFraming ? AudioBlock.maximumPayloadBytes : AudioBlock.maximumLegacyPayloadBytes
        audioBlockGeneration = generation; audioBlockChunkID = envelope.manifest.chunkID
        resumableAudioBlockChunkID = envelope.manifest.chunkID
        audioBlockOffset = 0; audioBlockPhase = shouldProbe ? "probe" : "payload"
        logger.notice("Audio block copy starting; chunk=\(envelope.manifest.chunkID.uuidString, privacy: .public), bytes=\(envelope.manifest.byteCount)")
        audioBlockTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await AudioBlockTransfer.send(file: file, envelope: envelope,
                    receiverDeviceID: receiverDeviceID, libraryInstanceID: libraryInstanceID,
                    initialProbe: shouldProbe, maximumSliceBytes: sliceBytes) { [weak self] block in
                        guard let self else { throw CancellationError() }
                        let reply = try await self.exchangeAudioBlock(block, binaryFraming: binaryFraming)
                        await self.noteAudioBlockReply(generation: generation, block: block, reply: reply)
                        return reply
                    }
                await self.finishAudioBlocks(generation: generation, result: .success(receipt))
            } catch { await self.finishAudioBlocks(generation: generation, result: .failure(error)) }
        }
        return true
    }

    public func cancelAudioBlockTransfer() {
        audioBlockPhase = "cancelled"
        audioBlockGeneration = nil; audioBlockChunkID = nil; resumableAudioBlockChunkID = nil
        activeAudioBlockGate?.finish(.failure(CancellationError())); activeAudioBlockGate = nil
        audioBlockTask?.cancel(); audioBlockTask = nil
    }

    private func finishAudioBlocks(generation: UUID, result: Result<Receipt, any Error>) {
        guard generation == audioBlockGeneration, let chunkID = audioBlockChunkID else { return }
        audioBlockTask = nil; audioBlockChunkID = nil; audioBlockGeneration = nil
        do {
            let receipt = try result.get()
            resumableAudioBlockChunkID = nil
            // This is the same durable Receipt consumed by the normal Watch inbox, not an offset acknowledgement.
            try preserveControl(.receipt(receipt))
            audioBlockPhase = "committed"
            audioBlockRetryAt = 0; audioBlockBackoff.reset()
            logger.notice("Audio block copy committed; chunk=\(chunkID.uuidString, privacy: .public)")
            event(.fileTransportFinished(chunkID: chunkID, failure: nil))
            event(.controlPreserved)
        } catch is CancellationError { audioBlockPhase = "cancelled"; return }
        catch {
            audioBlockPhase = "paused"
            if error as? AudioBlockTransferError == .budgetExhausted {
                audioBlockRetryAt = ProcessInfo.processInfo.systemUptime + 1
                logger.notice("Audio block slice yielded for continuation; chunk=\(chunkID.uuidString, privacy: .public), offset=\(self.audioBlockOffset)")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1_050))
                    self?.event(.controlSubmissionChanged)
                }
                return
            }
            if error as? AudioBlockTransferError == .invalidSource {
                resumableAudioBlockChunkID = nil
                audioBlockRetryAt = 0
                let failure = TransportFailure(error)
                logger.error("Audio block source invalid: \(failure.domain, privacy: .public) / \(failure.code)")
                event(.audioBlockSourceInvalid(chunkID: chunkID))
                event(.fileTransportFinished(chunkID: chunkID, failure: failure))
                return
            }
            if error as? AudioBlockTransferError == .rejected {
                resumableAudioBlockChunkID = nil
            }
            audioBlockRetryAt = ProcessInfo.processInfo.systemUptime + audioBlockBackoff.nextDelay()
            let failure = TransportFailure(error)
            logger.error("Audio block copy paused: \(failure.domain, privacy: .public) / \(failure.code)")
            event(.fileTransportFinished(chunkID: chunkID, failure: failure))
        }
    }

    private func noteAudioBlockReply(generation: UUID, block: AudioBlock, reply: AudioBlockReply) {
        guard generation == audioBlockGeneration else { return }
        let previous = audioBlockOffset
        audioBlockOffset = reply.nextOffset
        audioBlockPhase = reply.receipt == nil ? "payload" : "committed"
        if !block.payload.isEmpty, reply.nextOffset > previous {
            audioBlockLastProgressAt = Date()
            audioBlockBackoff.reset()
        }
        if block.payload.isEmpty || previous == 0 {
            logger.notice("Audio block checkpoint; chunk=\(block.envelope.manifest.chunkID.uuidString, privacy: .public), probe=\(block.payload.isEmpty), offset=\(reply.nextOffset)")
        }
    }

    private func exchangeAudioBlock(_ block: AudioBlock, binaryFraming: Bool) async throws -> AudioBlockReply {
        try Task.checkCancellation()
        guard session.activationState == .activated, session.isReachable else { throw LinkError.notReachable }
        let message: [String: Any]
        if binaryFraming {
            message = try block.binaryWireMetadata()
        } else {
            let data = try WireJSON.encode(block)
            guard data.count <= AudioBlock.maximumWireBytes else { throw LinkError.invalidMetadata }
            message = ["audio_block": data]
        }
        let gate = AudioBlockReplyGate()
        activeAudioBlockGate = gate
        defer { if activeAudioBlockGate === gate { activeAudioBlockGate = nil } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                gate.startDeadline(after: .seconds(12))
                if Task.isCancelled { gate.finish(.failure(CancellationError())); return }
                session.sendMessage(message, replyHandler: { @Sendable reply in
                    do {
                        guard let data = reply["audio_block_reply"] as? Data, data.count <= AudioBlock.maximumWireBytes else {
                            throw AudioBlockTransferError.rejected
                        }
                        let value = try WireJSON.decode(AudioBlockReply.self, from: data)
                        try value.validate(for: block)
                        gate.finish(.success(value))
                    } catch { gate.finish(.failure(error)) }
                }, errorHandler: { @Sendable error in gate.finish(.failure(error)) })
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }

    nonisolated func receiveBinaryAudioBlock(header: Data, payload: Data, replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = LinkReplyHandler(replyHandler)
        guard header.count + payload.count <= AudioBlock.maximumWireBytes, let receiveAudioBlock else {
            reply.send(["audio_block_rejected": true]); return
        }
        Task {
            do {
                let block = try AudioBlock(binaryHeaderData: header, payload: payload)
                let value = try await receiveAudioBlock(block)
                reply.send(["audio_block_reply": try WireJSON.encode(value)])
                if block.payload.isEmpty || value.receipt != nil {
                    logger.notice("Audio block reply; chunk=\(block.envelope.manifest.chunkID.uuidString, privacy: .public), offset=\(value.nextOffset), committed=\(value.receipt != nil)")
                }
                if value.receipt != nil { event(.audioBlockCommitted(chunkID: block.envelope.manifest.chunkID)) }
            } catch AudioBlockTransferError.rejected {
                reply.send(["audio_block_rejected": true])
                event(.controlSubmissionChanged)
            } catch {
                reply.send(["audio_block_rejected": true])
                event(.failed(TransportFailure(error)))
            }
        }
    }

    nonisolated func receiveAudioBlockData(_ data: Data, replyHandler: @escaping ([String: Any]) -> Void) {
        // Only encoded Data crosses the delegate's actor boundary.
        let reply = LinkReplyHandler(replyHandler)
        guard data.count <= AudioBlock.maximumWireBytes, let receiveAudioBlock else {
            reply.send(["audio_block_rejected": true]); return
        }
        Task {
            do {
                let block = try WireJSON.decode(AudioBlock.self, from: data)
                try block.validate()
                let value = try await receiveAudioBlock(block)
                reply.send(["audio_block_reply": try WireJSON.encode(value)])
                if block.payload.isEmpty || value.receipt != nil {
                    logger.notice("Audio block reply; chunk=\(block.envelope.manifest.chunkID.uuidString, privacy: .public), offset=\(value.nextOffset), committed=\(value.receipt != nil)")
                }
                if value.receipt != nil { event(.audioBlockCommitted(chunkID: block.envelope.manifest.chunkID)) }
            } catch AudioBlockTransferError.rejected {
                reply.send(["audio_block_rejected": true])
                event(.controlSubmissionChanged)
            } catch {
                reply.send(["audio_block_rejected": true])
                event(.failed(TransportFailure(error)))
            }
        }
    }
}

final class LinkReplyHandler: @unchecked Sendable {
    private let reply: ([String: Any]) -> Void
    init(_ reply: @escaping ([String: Any]) -> Void) { self.reply = reply }
    func send(_ value: [String: Any]) { reply(value) }
}

#endif
