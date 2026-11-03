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

/// Paces total process CPU consumption (`getrusage(RUSAGE_SELF)`) while the app scene is in the
/// background so background transcription stays safely below XNU's `cpu_resource_fatal` limit
/// (`48s` CPU over `60s` wall time = `80%` single-core equivalent).
final class BackgroundCPUPacer: @unchecked Sendable {
    private let condition = NSCondition()
    private var isForeground: Bool
    private var tokens: Double
    private var lastWallSeconds: Double
    private var lastCPUSeconds: Double

    private let maxCapacity: Double
    private let initialBackgroundBurst: Double
    private let refillRate: Double

    init(initiallyForeground: Bool = true,
         maxCapacity: Double = 6.0,
         initialBackgroundBurst: Double = 6.0,
         refillRate: Double = 0.65) {
        self.isForeground = initiallyForeground
        self.maxCapacity = maxCapacity
        self.initialBackgroundBurst = initialBackgroundBurst
        self.refillRate = refillRate
        let wall = Self.monotonicSeconds()
        let cpu = Self.processCPUSeconds()
        self.tokens = initiallyForeground ? maxCapacity : initialBackgroundBurst
        self.lastWallSeconds = wall
        self.lastCPUSeconds = cpu
    }

    var sceneForeground: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isForeground
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
        tokens = min(maxCapacity, tokens + dt * refillRate - dcpu)
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
