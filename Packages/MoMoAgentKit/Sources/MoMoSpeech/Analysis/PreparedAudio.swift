import Foundation
import MoMoContracts

/// Runtime acceleration only. Lost entries fall back to the original leased audio.
final class PreparedAudioCache: @unchecked Sendable {
    private struct Entry { let owner: UUID; let window: SpeechWindow; let samples: [Float] }
    let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(capacity: Int = 2) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func put(owner: UUID, window: SpeechWindow, samples: [Float], attempt: SpeechAttempt) throws {
        try lock.withLock {
            try attempt.checkCancellation()
            entries.removeAll { $0.window.id == window.id }
            entries.append(Entry(owner: owner, window: window, samples: samples))
            let protectedPerOwner = max(1, min(4, capacity / 2))
            while entries.count > capacity {
                var counts: [UUID: Int] = [:]
                for entry in entries { counts[entry.owner, default: 0] += 1 }
                if let tailOtherIndex = entries.lastIndex(where: { $0.owner != owner && (counts[$0.owner] ?? 0) > protectedPerOwner }) {
                    entries.remove(at: tailOtherIndex)
                } else if let oldestOwnOverflow = entries.firstIndex(where: { (counts[$0.owner] ?? 0) > protectedPerOwner }) {
                    entries.remove(at: oldestOwnOverflow)
                } else {
                    entries.removeFirst()
                }
            }
        }
    }

    func take(_ window: SpeechWindow) -> [Float]? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.window == window }) else { return nil }
            return entries.remove(at: index).samples
        }
    }

    func discard(owner: UUID) { lock.withLock { entries.removeAll { $0.owner == owner } } }
    func discard(sessionID: UUID? = nil) {
        lock.withLock { entries.removeAll { sessionID == nil || $0.window.sessionID == sessionID } }
    }
}

struct AnalysisAudioBuffer {
    let capacity: Int
    private var storage: [Float]
    private var head = 0
    private var count = 0
    private var start: Int64 = 0

    init(capacity: Int, start: Int64 = 0) {
        precondition(capacity > 0)
        self.capacity = capacity; self.start = start
        storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ block: [Float]) {
        if block.count >= capacity {
            start += Int64(count + block.count - capacity)
            storage = Array(block.suffix(capacity)); head = 0; count = capacity
            return
        }
        let removed = max(0, count + block.count - capacity)
        head = (head + removed) % capacity; start += Int64(removed); count -= removed
        let insertion = (head + count) % capacity
        let first = min(block.count, capacity - insertion)
        storage.replaceSubrange(insertion..<(insertion + first), with: block.prefix(first))
        if first < block.count { storage.replaceSubrange(0..<(block.count - first), with: block.dropFirst(first)) }
        count += block.count
    }

    func samples(in range: FrameRange) -> [Float]? {
        guard range.start >= start, range.end <= start + Int64(count) else { return nil }
        let index = (head + Int(range.start - start)) % capacity
        let first = min(Int(range.count), capacity - index)
        var result: [Float] = []
        result.reserveCapacity(Int(range.count))
        result.append(contentsOf: storage[index..<(index + first)])
        if first < range.count { result.append(contentsOf: storage[0..<(Int(range.count) - first)]) }
        return result
    }
}
