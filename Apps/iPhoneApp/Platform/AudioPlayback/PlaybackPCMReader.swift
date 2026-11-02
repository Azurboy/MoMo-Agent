import AVFoundation
import Accelerate
import MoMoArchive

/// Queue/actor-confined decoder. At most 8,192 decoded frames are resident at once.
final class PlaybackPCMReader {
    private static let maxInMemoryClipSeconds: Double = 120
    private let file: AVAudioFile
    private let start: AVAudioFramePosition
    private let end: AVAudioFramePosition
    let duration: Double
    var coversEntireFile: Bool { start == 0 && end == file.length }
    var canBuildInMemoryWAV: Bool {
        duration <= Self.maxInMemoryClipSeconds && (end - start) > 0 && (end - start) <= 16_000_000
    }

    init(part: AudioPlaybackPart) throws {
        let manifest = part.lease.manifest
        file = try AVAudioFile(forReading: part.lease.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == manifest.sampleRate,
              Int(file.processingFormat.channelCount) == manifest.channels,
              file.length == manifest.decodedFrameCount, manifest.frames.contains(part.frames) else {
            throw PlaybackError.unavailable
        }
        // Round inward: the clipped citation never includes a sample outside its source range.
        let lower = Double(part.frames.start - manifest.frames.start) / manifest.timebaseHz * manifest.sampleRate
        let upper = Double(part.frames.end - manifest.frames.start) / manifest.timebaseHz * manifest.sampleRate
        let remaining = file.length - manifest.primingFrames - manifest.paddingFrames
        guard lower.isFinite, upper.isFinite, lower >= 0, upper <= Double(remaining) + 1e-7 else {
            throw PlaybackError.unavailable
        }
        start = manifest.primingFrames + Int64((lower - 1e-7).rounded(.up))
        end = manifest.primingFrames + Int64((upper + 1e-7).rounded(.down))
        guard start >= 0, end > start, end <= file.length - manifest.paddingFrames else { throw PlaybackError.unavailable }
        duration = Double(end - start) / manifest.sampleRate
    }

    func writeClip(to url: URL, check: () throws -> Void) throws {
        let output = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try read(check: check) { buffer, _ in try output.write(from: buffer) }
    }

    func wavData(check: () throws -> Void) throws -> Data {
        let channelCount = Int(file.processingFormat.channelCount)
        let sampleRate = UInt32(max(1, Int(file.processingFormat.sampleRate.rounded())))
        let totalFrames = Int(end - start)
        let totalSamples = totalFrames * channelCount
        let pcmByteCount = totalSamples * MemoryLayout<Int16>.size
        guard channelCount > 0, totalFrames > 0, pcmByteCount > 0,
              pcmByteCount <= Int(UInt32.max) - 44 else {
            throw PlaybackError.unavailable
        }

        var data = Data(count: 44 + pcmByteCount)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            func putASCII(_ s: StaticString, at offset: Int) {
                memcpy(base.advanced(by: offset), s.utf8Start, 4)
            }
            func putU32(_ v: UInt32, at offset: Int) {
                var le = v.littleEndian
                memcpy(base.advanced(by: offset), &le, 4)
            }
            func putU16(_ v: UInt16, at offset: Int) {
                var le = v.littleEndian
                memcpy(base.advanced(by: offset), &le, 2)
            }
            putASCII("RIFF", at: 0)
            putU32(UInt32(36 + pcmByteCount), at: 4)
            putASCII("WAVE", at: 8)
            putASCII("fmt ", at: 12)
            putU32(16, at: 16)
            putU16(1, at: 20)
            putU16(UInt16(channelCount), at: 22)
            putU32(sampleRate, at: 24)
            putU32(sampleRate * UInt32(channelCount * 2), at: 28)
            putU16(UInt16(channelCount * 2), at: 32)
            putU16(16, at: 34)
            putASCII("data", at: 36)
            putU32(UInt32(pcmByteCount), at: 40)
        }

        var scaledScratch = [Float](repeating: 0, count: 8_192)
        var clippedScratch = [Float](repeating: 0, count: 8_192)
        var scale: Float = 32767.0
        var low: Float = -32767.0
        var high: Float = 32767.0
        var writtenFrames = 0

        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw PlaybackError.unavailable }
            let pcmBase = base.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            try read(check: check) { buffer, offset in
                guard let channels = buffer.floatChannelData else { throw PlaybackError.unavailable }
                let n = Int(buffer.frameLength)
                let frameOffset = Int(offset)
                guard frameOffset + n <= totalFrames else { throw PlaybackError.unavailable }
                if channelCount == 1 {
                    let count = vDSP_Length(n)
                    vDSP_vsmul(channels[0], 1, &scale, &scaledScratch, 1, count)
                    vDSP_vclip(scaledScratch, 1, &low, &high, &clippedScratch, 1, count)
                    vDSP_vfixr16(clippedScratch, 1, pcmBase.advanced(by: frameOffset), 1, count)
                } else {
                    for f in 0..<n {
                        let dstIdx = (frameOffset + f) * channelCount
                        for ch in 0..<channelCount {
                            let s = channels[ch][f]
                            let clamped = s.isFinite ? max(-1.0, min(1.0, s)) : 0
                            pcmBase[dstIdx + ch] = Int16((clamped * 32767.0).rounded()).littleEndian
                        }
                    }
                }
                writtenFrames += n
            }
        }
        guard writtenFrames == totalFrames else { throw PlaybackError.unavailable }
        return data
    }

    func envelope(binCount: Int) throws -> [Float] {
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        let total = end - start
        try read(check: { try Task.checkCancellation() }) { buffer, offset in
            guard let channels = buffer.floatChannelData else { throw PlaybackError.unavailable }
            let channelCount = Int(buffer.format.channelCount)
            var frame = 0
            while frame < Int(buffer.frameLength) {
                let bin = min(binCount - 1, Int((offset + Int64(frame)) * Int64(binCount) / total))
                let boundary = (Int64(bin + 1) * total + Int64(binCount) - 1) / Int64(binCount)
                let length = min(Int(buffer.frameLength) - frame, Int(boundary - offset) - frame)
                for channel in 0..<channelCount {
                    var squares: Float = 0
                    vDSP_svesq(channels[channel].advanced(by: frame), 1, &squares, vDSP_Length(length))
                    guard squares.isFinite else { throw PlaybackError.unavailable }
                    sums[bin] += Double(squares)
                    counts[bin] += length
                }
                frame += length
            }
        }
        return sums.indices.map { counts[$0] > 0 ? Float(sqrt(sums[$0] / Double(counts[$0]))) : 0 }
    }

    private func read(check: () throws -> Void, consume: (AVAudioPCMBuffer, Int64) throws -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw PlaybackError.unavailable
        }
        file.framePosition = start
        while file.framePosition < end {
            try check()
            let offset = file.framePosition - start
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, end - file.framePosition)))
            guard buffer.frameLength > 0 else { throw PlaybackError.unavailable }
            try consume(buffer, offset)
        }
    }
}
