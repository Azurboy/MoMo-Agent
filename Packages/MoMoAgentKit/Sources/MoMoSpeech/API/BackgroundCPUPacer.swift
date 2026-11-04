import Darwin
import Foundation
import MoMoSherpaBridge

/// Thread-safe ARC wrapper around `MoMoCancelToken` so concurrent `SpeechAttempt.cancel()`
/// callbacks can never touch the C++ token after the native call returns.
final class NativeCancelTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: OpaquePointer?

    init() {
        self.token = MoMoCreateCancelToken()
    }

    deinit {
        if let token { MoMoDestroyCancelToken(token) }
    }

    func trigger() {
        lock.withLock {
            if let token { MoMoTriggerCancelToken(token) }
        }
    }

    func withPointer<R>(_ body: (OpaquePointer?) -> R) -> R {
        let raw = lock.withLock { token }
        defer {
            let retired = lock.withLock { () -> OpaquePointer? in
                let current = token
                token = nil
                return current
            }
            if let retired { MoMoDestroyCancelToken(retired) }
        }
        return body(raw)
    }
}

func withNativeCancelToken(_ attempt: SpeechAttempt, _ body: (OpaquePointer?) -> Int32) -> Int32 {
    let box = NativeCancelTokenBox()
    let observer = attempt.observeCancellation { box.trigger() }
    defer { attempt.removeCancellationObserver(observer) }
    return box.withPointer(body)
}

public enum SpeechBackgroundBudget: String, Sendable, Equatable {
    /// Conservative pace (`0.65` CPU-s/s) for finite UIKit background tasks subject to XNU's 48s/60s `cpu_resource_fatal` limit.
    case standard
    /// Elevated pace (`1.35` CPU-s/s) for system `BGProcessingTask` / `BGContinuedProcessingTask` grants on battery under nominal/fair thermal state.
    case elevatedSystemTask
    /// High-throughput pace (`2.20` CPU-s/s) for system processing grants while connected to external power under nominal/fair thermal state.
    case externalPowerSystemTask

    var parameters: (maxCapacity: Double, initialBurst: Double, refillRate: Double) {
        switch self {
        case .standard: return (9.5, 9.5, 0.65)
        case .elevatedSystemTask: return (10.0, 8.0, 1.35)
        case .externalPowerSystemTask: return (14.0, 12.0, 2.20)
        }
    }
}

/// Paces total process CPU consumption (`getrusage(RUSAGE_SELF)`) while the app scene is in the
/// background so background transcription stays safely below XNU's `cpu_resource_fatal` limit
/// (`48s` CPU over `60s` wall time = `80%` single-core equivalent) on finite UIKit tasks while
/// scaling up under admitted `BGProcessingTask` / `BGContinuedProcessingTask` coalitions.
final class BackgroundCPUPacer: @unchecked Sendable {
    private let condition = NSCondition()
    private var isForeground: Bool
    private var currentBudget: SpeechBackgroundBudget
    private var tokens: Double
    private var lastWallSeconds: Double
    private var lastCPUSeconds: Double
    private var activeOperations = 0

    private var maxCapacity: Double
    private var initialBackgroundBurst: Double
    private var refillRate: Double

    init(initiallyForeground: Bool = true,
         budget: SpeechBackgroundBudget = .standard,
         maxCapacity: Double? = nil,
         initialBackgroundBurst: Double? = nil,
         refillRate: Double? = nil) {
        let defaults = budget.parameters
        let resolvedMax = maxCapacity ?? defaults.maxCapacity
        let resolvedBurst = initialBackgroundBurst ?? defaults.initialBurst
        let resolvedRate = refillRate ?? defaults.refillRate
        self.isForeground = initiallyForeground
        self.currentBudget = budget
        self.maxCapacity = resolvedMax
        self.initialBackgroundBurst = resolvedBurst
        self.refillRate = resolvedRate
        let wall = Self.monotonicSeconds()
        let cpu = Self.processCPUSeconds()
        self.tokens = initiallyForeground ? resolvedMax : resolvedBurst
        self.lastWallSeconds = wall
        self.lastCPUSeconds = cpu
    }

    var sceneForeground: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isForeground
    }

    var backgroundBudget: SpeechBackgroundBudget {
        condition.lock()
        defer { condition.unlock() }
        return currentBudget
    }

    var currentRefillRate: Double {
        condition.lock()
        defer { condition.unlock() }
        return refillRate
    }

    func setBackgroundBudget(_ budget: SpeechBackgroundBudget) {
        condition.lock()
        defer { condition.unlock() }
        guard currentBudget != budget else { return }
        updateBucketLocked()
        let previousMax = maxCapacity
        let next = budget.parameters
        currentBudget = budget
        maxCapacity = next.maxCapacity
        initialBackgroundBurst = next.initialBurst
        refillRate = next.refillRate
        if isForeground {
            tokens = next.maxCapacity
        } else if next.maxCapacity > previousMax {
            tokens = min(next.maxCapacity, max(tokens, min(next.initialBurst, tokens + (next.maxCapacity - previousMax) * 0.5)))
        } else {
            tokens = min(tokens, next.maxCapacity)
        }
        condition.broadcast()
    }

    func setSceneForeground(_ foreground: Bool) {
        condition.lock()
        defer { condition.unlock() }
        guard isForeground != foreground else { return }
        isForeground = foreground
        if !foreground {
            lastWallSeconds = Self.monotonicSeconds()
            lastCPUSeconds = Self.processCPUSeconds()
            tokens = initialBackgroundBurst
        }
        condition.broadcast()
    }

    func wake() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Marks the start of an active SpeechEngine operation so CPU spent by non-speech threads
    /// while SpeechEngine was idle does not pre-drain the background token bucket.
    func beginOperation() {
        condition.lock()
        defer { condition.unlock() }
        if activeOperations == 0, !isForeground {
            let nowWall = Self.monotonicSeconds()
            let dt = max(0, nowWall - lastWallSeconds)
            lastWallSeconds = nowWall
            lastCPUSeconds = Self.processCPUSeconds()
            tokens = min(maxCapacity, tokens + dt * refillRate)
        }
        activeOperations += 1
    }

    func endOperation() {
        condition.lock()
        defer { condition.unlock() }
        guard activeOperations > 0 else { return }
        if !isForeground {
            updateBucketLocked()
        }
        activeOperations -= 1
    }

    /// Returns `true` if `attempt` was cancelled; sleeps in bounded slices when background CPU debt exists.
    func paceIfNeeded(attempt: SpeechAttempt) -> Bool {
        if attempt.cancellationUptimeNanoseconds != nil { return true }
        condition.lock()
        if isForeground {
            condition.unlock()
            return attempt.cancellationUptimeNanoseconds != nil
        }
        updateBucketLocked()
        if tokens >= 0 {
            condition.unlock()
            return attempt.cancellationUptimeNanoseconds != nil
        }
        condition.unlock()

        let observer = attempt.observeCancellation { [weak self] in self?.wake() }
        defer { attempt.removeCancellationObserver(observer) }

        condition.lock()
        defer { condition.unlock() }
        while !isForeground {
            if attempt.cancellationUptimeNanoseconds != nil { return true }
            updateBucketLocked()
            if tokens >= 0 { return false }
            let waitSeconds = min(0.05, max(0.005, (-tokens) / refillRate))
            condition.wait(until: Date(timeIntervalSinceNow: waitSeconds))
        }
        return attempt.cancellationUptimeNanoseconds != nil
    }

    private func updateBucketLocked() {
        let nowWall = Self.monotonicSeconds()
        let nowCPU = Self.processCPUSeconds()
        let dt = max(0, nowWall - lastWallSeconds)
        let dcpu = max(0, nowCPU - lastCPUSeconds)
        lastWallSeconds = nowWall
        lastCPUSeconds = nowCPU
        let debtFloor = min(initialBackgroundBurst, -1.5 * refillRate)
        tokens = max(debtFloor, min(maxCapacity, tokens + dt * refillRate - dcpu))
    }

    static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) * 1e-6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) * 1e-6
        return user + system
    }
}
