import Foundation
import MoMoContracts

public enum AudioBlockTransferError: Error, Sendable, Equatable, LocalizedError {
    case timedOut, rejected, noProgress, invalidSource, budgetExhausted
    public var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "原音补传等待手机回复超时，原音已保留。", bundle: AppLanguage.resourceBundle)
        case .rejected: String(localized: "手机暂未接受原音补传，将保留原音并重试。", bundle: AppLanguage.resourceBundle)
        case .noProgress: String(localized: "原音补传的接收偏移未推进，将稍后重新核对。", bundle: AppLanguage.resourceBundle)
        case .invalidSource: String(localized: "待同步原音的文件长度与录音记录不一致。", bundle: AppLanguage.resourceBundle)
        case .budgetExhausted: String(localized: "本轮原音补传已暂停，下次从已保存位置继续。", bundle: AppLanguage.resourceBundle)
        }
    }
}

public enum AudioBlockTransfer {
    /// One block in memory and no open source handle while waiting for the peer.
    public static func send(file: URL, envelope: ManifestEnvelope, receiverDeviceID: UUID, libraryInstanceID: UUID,
        initialProbe: Bool = true, maximumSliceBytes: Int = AudioBlock.maximumPayloadBytes,
        exchange: @Sendable (AudioBlock) async throws -> AudioBlockReply) async throws -> Receipt {
        let size = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard size.isRegularFile == true, size.fileSize.map(Int64.init) == envelope.manifest.byteCount else {
            throw AudioBlockTransferError.invalidSource
        }
        let sliceLimit = max(1, min(AudioBlock.maximumPayloadBytes, maximumSliceBytes))
        let cachedData: Data?
        if envelope.manifest.byteCount <= 1_048_576 {
            let loaded = try Data(contentsOf: file)
            guard Int64(loaded.count) == envelope.manifest.byteCount else {
                throw AudioBlockTransferError.invalidSource
            }
            cachedData = loaded
        } else {
            cachedData = nil
        }
        var offset: Int64 = 0
        var probe = initialProbe
        var unchanged = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let payload: Data
            if probe { payload = Data(); probe = false }
            else if let cachedData {
                let start = Int(offset)
                let count = min(sliceLimit, cachedData.count - start)
                guard count > 0 else { throw AudioBlockTransferError.invalidSource }
                payload = cachedData.subdata(in: start..<(start + count))
            } else {
                let handle = try FileHandle(forReadingFrom: file)
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    payload = try handle.read(upToCount: min(sliceLimit, Int(envelope.manifest.byteCount - offset))) ?? Data()
                    try handle.close()
                } catch { try handle.close(); throw error }
                guard !payload.isEmpty else { throw AudioBlockTransferError.invalidSource }
            }
            let block = try AudioBlock(receiverDeviceID: receiverDeviceID, libraryInstanceID: libraryInstanceID,
                                       envelope: envelope, offset: offset, payload: payload)
            let reply = try await exchange(block)
            try reply.validate(for: block)
            if let receipt = reply.receipt { return receipt }
            unchanged = !payload.isEmpty && reply.nextOffset == offset ? unchanged + 1 : 0
            guard unchanged < 2 else { throw AudioBlockTransferError.noProgress }
            offset = reply.nextOffset
        }
        throw AudioBlockTransferError.budgetExhausted
    }
}
