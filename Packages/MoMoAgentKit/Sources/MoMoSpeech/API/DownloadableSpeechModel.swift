import Foundation
import MoMoContracts

/// Immutable, app-pinned catalog. Remote responses cannot change paths or checksums.
public struct DownloadableSpeechModel: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let asset: String
        public let byteCount: Int64
        public let sha256: String
    }

    public let identifier: String
    public let baseURL: URL
    public let files: [File]
    public var downloadBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    static let xASRIdentifier = "sherpa-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03"

    public static func funASRNano() throws -> Self { try bundled("funasr-nano-onnx-v1") }

    public static func xASR() throws -> Self {
        let value = try bundled("x-asr-zh-en-onnx-v1")
        guard value.identifier == xASRIdentifier else { throw SpeechModelInstallationError.invalidCatalog }
        return value
    }

    private static func bundled(_ name: String) throws -> Self {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw SpeechModelInstallationError.invalidCatalog
        }
        let value = try WireJSON.decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    public func validate() throws {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        func component(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".."
                && value.unicodeScalars.allSatisfy(safe.contains)
        }
        guard component(identifier), baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil, baseURL.absoluteString.hasSuffix("/"),
              !files.isEmpty, files.count <= 40,
              Set(files.map(\.path)).count == files.count,
              Set(files.map(\.asset)).count == files.count,
              files.allSatisfy({
                  $0.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component(String($0)) }
                    && $0.asset.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component(String($0)) } && (1...4_294_967_296).contains($0.byteCount)
                    && ContentHash.isValid($0.sha256)
              }) else { throw SpeechModelInstallationError.invalidCatalog }
        for file in files {
            guard file.path != "complete.json", !file.path.hasSuffix(".download"),
                  !file.path.hasPrefix("."),
                  !files.contains(where: { $0.path.hasPrefix(file.path + "/") }) else {
                throw SpeechModelInstallationError.invalidCatalog
            }
        }
    }

    public var revision: String {
        get throws { ContentHash.sha256(try WireJSON.encode(self)) }
    }

    /// Rehash only when an immutable installed artifact changed, including same-size writes.
    func validateFiles(at directory: URL, attempt: SpeechAttempt,
                       recorder: SpeechDiagnosticRecorder? = nil) throws {
        try validate()
        let stamp = try validationStamp(at: directory, attempt: attempt)
        guard ModelValidationReceipt.read(at: directory) != stamp else { return }
        for file in files {
            try attempt.checkCancellation()
            guard try speechFileHash(directory.appendingPathComponent(file.path), attempt: attempt, recorder: recorder, model: true) == file.sha256 else {
                throw SpeechModelInstallationError.fileMismatch(file.path)
            }
        }
        try attempt.checkCancellation()
        // Cache is advisory; failure to write it must not invalidate verified weights.
        try? stamp.save(at: directory)
    }

    func validationStamp(at directory: URL, attempt: SpeechAttempt) throws -> ModelValidationReceipt {
        try ModelValidationReceipt.snapshot(at: directory, manifestHash: revision,
            sizes: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.byteCount) }), attempt: attempt)
    }
}

public enum SpeechModelInstallationError: Error, Equatable, Sendable {
    case invalidCatalog
    case alreadyDownloading
    case insufficientSpace(requiredBytes: Int64)
    case invalidResponse
    case fileMismatch(String)
    case unsafeFile(String)
}
