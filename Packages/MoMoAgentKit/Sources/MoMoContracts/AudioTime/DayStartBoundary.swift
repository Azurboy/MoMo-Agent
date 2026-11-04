import Foundation

/// Shared daily start-hour boundary (`08:00` by default, configurable in `0...23`).
/// Recordings between `00:00` and `startHour` belong to the preceding waking day.
public enum DayStartBoundary {
    public static let defaultsKey = "timeline.dayStartHour"
    public static let defaultHour = 8
    public static let hourRange = 0...23

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedHour: Int?

    public static func clamp(_ hour: Int) -> Int {
        min(max(hour, hourRange.lowerBound), hourRange.upperBound)
    }

    public static func resolvedHour(from defaults: UserDefaults = .standard) -> Int {
        guard let saved = defaults.object(forKey: defaultsKey) as? NSNumber else {
            return defaultHour
        }
        let value = saved.intValue
        return hourRange.contains(value) ? value : defaultHour
    }

    public static var currentHour: Int {
        lock.lock()
        defer { lock.unlock() }
        if let cachedHour { return cachedHour }
        let resolved = resolvedHour(from: .standard)
        cachedHour = resolved
        return resolved
    }

    @discardableResult
    public static func syncFromDefaults(_ defaults: UserDefaults = .standard) -> Int {
        let resolved = resolvedHour(from: defaults)
        lock.lock()
        cachedHour = resolved
        lock.unlock()
        return resolved
    }

    public static func setCurrentHour(_ hour: Int, defaults: UserDefaults? = .standard) {
        let clamped = clamp(hour)
        lock.lock()
        cachedHour = clamped
        lock.unlock()
        defaults?.set(clamped, forKey: defaultsKey)
    }

    public static func label(for hour: Int) -> String {
        String(format: "%02d:00", clamp(hour))
    }

    /// Returns midnight (`00:00`) of the logical calendar day that `date` belongs to.
    public static func logicalDayStart(
        for date: Date,
        calendar: Calendar = .current,
        startHour: Int = currentHour
    ) -> Date {
        let clamped = clamp(startHour)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let midnight = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
        if clamped > 0, let hour = parts.hour, hour < clamped {
            return calendar.date(byAdding: .day, value: -1, to: midnight)!
        }
        return midnight
    }

    /// Returns the actual start instant (`startHour:00`) of a literal calendar day.
    public static func boundaryStart(
        forCalendarDay dayDate: Date,
        calendar: Calendar = .current,
        startHour: Int = currentHour
    ) -> Date {
        let clamped = clamp(startHour)
        let midnight = calendar.startOfDay(for: dayDate)
        guard clamped > 0 else { return midnight }
        return calendar.date(bySettingHour: clamped, minute: 0, second: 0, of: midnight)
            ?? midnight.addingTimeInterval(Double(clamped) * 3_600)
    }
}
