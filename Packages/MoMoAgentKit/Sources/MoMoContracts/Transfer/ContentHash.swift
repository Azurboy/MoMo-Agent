import CryptoKit
import Darwin
import Foundation

public enum ContentHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while true {
                let count = stream.read(base, maxLength: rawBuffer.count)
                guard count >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
                if count == 0 { break }
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: rawBuffer[..<count]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum WireJSON {
    private static let dates = WireDates()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
            guard milliseconds.isFinite else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Invalid timestamp"))
            }
            // Keep old whole-second projections byte-stable while preserving new millisecond anchors.
            var value = encoder.singleValueContainer()
            try value.encode(dates.string(fromMilliseconds: milliseconds))
        }
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            // Existing manifests keep their original bytes and whole-second timestamps.
            guard let date = dates.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO 8601 timestamp")
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}

/// Foundation formatters are mutable and not Sendable. Only this lock accesses them;
/// encoders/decoders remain local to each operation, with the original wire format.
private final class WireDates: @unchecked Sendable {
    private let lock = NSLock()
    private let whole = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private let parser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init() {
        whole.formatOptions = [.withInternetDateTime]
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func string(fromMilliseconds milliseconds: Double) -> String {
        let includeFraction = milliseconds.truncatingRemainder(dividingBy: 1_000) != 0
        if milliseconds >= 0, milliseconds < 253_402_300_800_000,
           let totalMillis = Int64(exactly: milliseconds) {
            var unixSeconds = Darwin.time_t(totalMillis / 1_000)
            let millisPart = Int(totalMillis % 1_000)
            var components = Darwin.tm()
            if Darwin.gmtime_r(&unixSeconds, &components) != nil {
                let year = Int(components.tm_year) + 1900
                if (1970...9999).contains(year) {
                    let month = Int(components.tm_mon) + 1
                    let day = Int(components.tm_mday)
                    let hour = Int(components.tm_hour)
                    let minute = Int(components.tm_min)
                    let second = Int(components.tm_sec)
                    return Self.formatUTC(year: year, month: month, day: day,
                                          hour: hour, minute: minute, second: second,
                                          milliseconds: includeFraction ? millisPart : nil)
                }
            }
        }
        let date = Date(timeIntervalSince1970: milliseconds / 1_000)
        return lock.withLock { (includeFraction ? fractional : whole).string(from: date) }
    }

    private static func formatUTC(year: Int, month: Int, day: Int,
                                  hour: Int, minute: Int, second: Int,
                                  milliseconds: Int?) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(milliseconds == nil ? 20 : 24)
        bytes.append(UInt8(48 + (year / 1_000) % 10))
        bytes.append(UInt8(48 + (year / 100) % 10))
        bytes.append(UInt8(48 + (year / 10) % 10))
        bytes.append(UInt8(48 + year % 10))
        bytes.append(45) // '-'
        bytes.append(UInt8(48 + (month / 10) % 10))
        bytes.append(UInt8(48 + month % 10))
        bytes.append(45) // '-'
        bytes.append(UInt8(48 + (day / 10) % 10))
        bytes.append(UInt8(48 + day % 10))
        bytes.append(84) // 'T'
        bytes.append(UInt8(48 + (hour / 10) % 10))
        bytes.append(UInt8(48 + hour % 10))
        bytes.append(58) // ':'
        bytes.append(UInt8(48 + (minute / 10) % 10))
        bytes.append(UInt8(48 + minute % 10))
        bytes.append(58) // ':'
        bytes.append(UInt8(48 + (second / 10) % 10))
        bytes.append(UInt8(48 + second % 10))
        if let milliseconds {
            bytes.append(46) // '.'
            bytes.append(UInt8(48 + (milliseconds / 100) % 10))
            bytes.append(UInt8(48 + (milliseconds / 10) % 10))
            bytes.append(UInt8(48 + milliseconds % 10))
        }
        bytes.append(90) // 'Z'
        return String(decoding: bytes, as: UTF8.self)
    }

    func date(from text: String) -> Date? {
        // App-written anchors dominate archive reads; avoid ICU parsing and its shared lock.
        if (text.utf8.count == 20 || text.utf8.count == 24), text.hasSuffix("Z"),
           let date = try? parser.parse(text) {
            // Match legacy NSDate's Unix-epoch arithmetic exactly; cached source IDs compare Dates.
            return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        }
        return lock.withLock { fractional.date(from: text) ?? whole.date(from: text) }
    }
}
