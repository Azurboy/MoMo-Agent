import Darwin
import Foundation
import MoMoContracts

struct FileStatStamp: Equatable {
    let mode: UInt16
    let inode: UInt64
    let size: Int64
    let mtimeSec: Int
    let mtimeNsec: Int
    let ctimeSec: Int
    let ctimeNsec: Int

    static func read(at url: URL) -> FileStatStamp? {
        var st = Darwin.stat()
        guard url.withUnsafeFileSystemRepresentation({ ptr in
            guard let ptr else { return -1 }
            return Darwin.lstat(ptr, &st)
        }) == 0 else { return nil }
        return FileStatStamp(
            mode: UInt16(st.st_mode),
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            ctimeSec: st.st_ctimespec.tv_sec,
            ctimeNsec: st.st_ctimespec.tv_nsec
        )
    }
}

struct VerifiedRecordingFilesEntry: Equatable {
    let relativeDirectory: String
    let transcriptVersion: Int64
    let generation: Int64
    let projectionVersion: Int64
    let manifestProjected: Bool
    let chunkCount: Int64
    let directoryStamp: FileStatStamp
    let audioDirectoryStamp: FileStatStamp
    let manifestFileStamp: FileStatStamp?
    let jsonFileStamp: FileStatStamp?
    let markdownFileStamp: FileStatStamp?
}

struct RecordingFileInspection {
    let issue: RecordingFileIssue?
    let automaticEdit: [TranscriptSpan]?
}

extension ArchiveStore {
    public func recordingFileIssues(sessionID: UUID? = nil) async throws -> [RecordingFileIssue] {
        var query = "SELECT id FROM sessions WHERE deleted=0 AND document_directory IS NOT NULL"
        var parameters: [SQLValue] = []
        if let sessionID {
            query += " AND id=?"
            parameters = [.text(sessionID.uuidString)]
        }
        let ids = try database.rows(query, parameters).map { try $0.requireUUID(0) }
        var result: [RecordingFileIssue] = []
        for id in ids {
            try Task.checkCancellation()
            guard try !sessionIsDeleted(id) else { continue }
            do { if let issue = try inspectRecordingFiles(sessionID: id, allowRelocation: false).issue { result.append(issue) } }
            catch let error as CancellationError { throw error }
            catch { result.append(try unreadableRecordingIssue(sessionID: id, error: error)) }
            await Task.yield()
        }
        return result
    }

    public func recordingRecoveryPreview(_ issue: RecordingFileIssue, choosing action: RecordingFileRecoveryAction) throws -> TranscriptDocument {
        try validateRecoverySnapshot(issue, action: action)
        guard let original = try currentTranscriptOrNil(sessionID: issue.sessionID) else {
            guard action == .restoreDatabase else { throw ArchiveError.missingTranscript(issue.sessionID) }
            return TranscriptDocument(sessionID: issue.sessionID, version: 0, generation: issue.generation, spans: [], updatedAt: Date(timeIntervalSince1970: 0))
        }
        if action == .restoreDatabase { return original }
        guard action == .useJSON || action == .useMarkdown else { throw ArchiveError.invalidQuery }
        let spans = try recoverySpans(sessionID: issue.sessionID, action: action, original: original)
        return TranscriptDocument(sessionID: original.sessionID, version: original.version, generation: original.generation, spans: spans, updatedAt: original.updatedAt)
    }

    public func resolveRecordingFiles(_ issue: RecordingFileIssue, choosing action: RecordingFileRecoveryAction) throws -> RecordingFileResolutionResult {
        try validateRecoverySnapshot(issue, action: action)
        if action == .deleteRecording { return .deleted(try deleteSession(id: issue.sessionID)) }
        let original = try currentTranscriptOrNil(sessionID: issue.sessionID)
        let document: TranscriptDocument?
        if action == .restoreDatabase { document = original }
        else {
            guard let original else { throw ArchiveError.missingTranscript(issue.sessionID) }
            let spans = try recoverySpans(sessionID: issue.sessionID, action: action, original: original)
            document = try reviseTranscript(sessionID: issue.sessionID, expectedVersion: original.version, spans: spans)
        }
        // Only this explicit confirmation may recreate a missing projection or recording directory.
        try blockProjection(sessionID: issue.sessionID)
        let directory = try transcriptDirectory(sessionID: issue.sessionID)
        try ArchiveFilePolicy.prepareDirectory(directory.appendingPathComponent("audio", isDirectory: true))
        let chunks = try database.rows("SELECT id,relative_path,manifest FROM chunks WHERE session_id=? ORDER BY rowid", [.text(issue.sessionID.uuidString)])
        for row in chunks {
            let audio = rootURL.appendingPathComponent(try row.requireString(1))
            try validateRecordingPath(audio)
            if !files.fileExists(atPath: audio.path) {
                try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=? AND retention='present'", [.text(try row.requireString(0))])
            }
        }
        let manifest = RecordingManifest(sessionID: issue.sessionID, chunks: try chunks.map { try WireJSON.decode(ChunkManifest.self, from: $0.requireData(2)) })
        try ArchiveFilePolicy.write(WireJSON.encode(manifest), to: directory.appendingPathComponent("manifest.json"))
        var projectionHash: SQLValue = .null
        if let document {
            let json = try WireJSON.encode(document), markdown = Data(transcriptMarkdown(document).utf8)
            try ArchiveFilePolicy.write(json, to: directory.appendingPathComponent("transcript.json"))
            try ArchiveFilePolicy.write(markdown, to: directory.appendingPathComponent("transcript.md"))
            projectionHash = .text(ContentHash.sha256(json + markdown))
        }
        try database.execute("UPDATE sessions SET projection_version=?,projection_hash=?,projection_blocked=0,manifest_projected=1 WHERE id=?", [
            .integer(document?.version ?? 0), projectionHash, .text(issue.sessionID.uuidString)
        ])
        cacheVerifiedRecordingFiles(sessionID: issue.sessionID)
        return action == .restoreDatabase ? .restored(version: document?.version ?? 0) : .revised(version: document?.version ?? 0)
    }

    private func validateRecoverySnapshot(_ issue: RecordingFileIssue, action: RecordingFileRecoveryAction) throws {
        guard issue.availableActions.contains(action),
              let current = try inspectRecordingFiles(sessionID: issue.sessionID, allowRelocation: false).issue,
              current == issue else { throw ArchiveError.staleSource }
    }

    func cacheVerifiedRecordingFiles(sessionID: UUID) {
        guard !database.isInTransaction else {
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
            return
        }
        guard let row = try? database.rows(
            "SELECT document_directory,transcript_version,generation,projection_version,manifest_projected,(SELECT COUNT(*) FROM chunks WHERE session_id=sessions.id) FROM sessions WHERE id=? AND deleted=0",
            [.text(sessionID.uuidString)]
        ).first,
        let relative = row.string(0),
        let version = try? row.requireInt(1),
        let generation = try? row.requireInt(2),
        let projected = try? row.requireInt(3) else {
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
            return
        }
        let manifestProjected = row.integer(4) == 1
        let chunkCount = row.integer(5) ?? 0
        let directory = rootURL.appendingPathComponent(relative, isDirectory: true)
        let audioDir = directory.appendingPathComponent("audio", isDirectory: true)
        guard let dirStamp = FileStatStamp.read(at: directory),
              (dirStamp.mode & UInt16(S_IFMT)) == UInt16(S_IFDIR),
              let audioStamp = FileStatStamp.read(at: audioDir),
              (audioStamp.mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) else {
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
            return
        }
        let manifestStamp = FileStatStamp.read(at: directory.appendingPathComponent("manifest.json"))
        let jsonStamp = FileStatStamp.read(at: directory.appendingPathComponent("transcript.json"))
        let mdStamp = FileStatStamp.read(at: directory.appendingPathComponent("transcript.md"))
        if let s = manifestStamp, (s.mode & UInt16(S_IFMT)) != UInt16(S_IFREG) { return }
        if let s = jsonStamp, (s.mode & UInt16(S_IFMT)) != UInt16(S_IFREG) { return }
        if let s = mdStamp, (s.mode & UInt16(S_IFMT)) != UInt16(S_IFREG) { return }
        verifiedRecordingFilesDataVersion = (try? database.rows("PRAGMA data_version").first?.requireInt(0)) ?? verifiedRecordingFilesDataVersion
        verifiedRecordingFilesCache[sessionID] = VerifiedRecordingFilesEntry(
            relativeDirectory: relative,
            transcriptVersion: version,
            generation: generation,
            projectionVersion: projected,
            manifestProjected: manifestProjected,
            chunkCount: chunkCount,
            directoryStamp: dirStamp,
            audioDirectoryStamp: audioStamp,
            manifestFileStamp: manifestStamp,
            jsonFileStamp: jsonStamp,
            markdownFileStamp: mdStamp
        )
    }

    func inspectRecordingFiles(sessionID: UUID, allowRelocation: Bool = true) throws -> RecordingFileInspection {
        let externalVersion = try database.rows("PRAGMA data_version").first?.requireInt(0) ?? 0
        if externalVersion != verifiedRecordingFilesDataVersion {
            verifiedRecordingFilesCache.removeAll()
            verifiedRecordingFilesDataVersion = externalVersion
        }
        guard let row = try database.rows(
            "SELECT document_directory,transcript_version,generation,projection_version,manifest_projected,projection_hash,(SELECT COUNT(*) FROM chunks WHERE session_id=sessions.id) FROM sessions WHERE id=? AND deleted=0",
            [.text(sessionID.uuidString)]
        ).first,
        let relative = row.string(0) else {
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
            throw ArchiveError.missingRecording(sessionID)
        }
        let version = try row.requireInt(1), generation = try row.requireInt(2), projected = try row.requireInt(3)
        let manifestProjected = row.integer(4) == 1
        let projectionHash = row.string(5)
        let chunkCount = row.integer(6) ?? 0
        let directory = rootURL.appendingPathComponent(relative, isDirectory: true)
        func problem(_ kind: RecordingFileIssueKind, candidates: [String] = [], missing: [String] = [], hashes: [String: String] = [:], actions: [RecordingFileRecoveryAction] = []) throws -> RecordingFileInspection {
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
            let fingerprint = try issueFingerprint(sessionID: sessionID, version: version, generation: generation, relative: relative, kind: kind, candidates: candidates, missing: missing, hashes: hashes)
            return RecordingFileInspection(issue: RecordingFileIssue(sessionID: sessionID, kind: kind, relativeDirectory: relative,
                candidateDirectories: candidates.sorted(), missingFiles: missing.sorted(), availableActions: actions,
                fingerprint: fingerprint, transcriptVersion: version, generation: generation), automaticEdit: nil)
        }
        do { try validateRecordingPath(directory) }
        catch ArchiveError.invalidQuery { return try problem(.unsafePath) }
        if !database.isInTransaction,
           let cached = verifiedRecordingFilesCache[sessionID],
           cached.relativeDirectory == relative,
           cached.transcriptVersion == version,
           cached.generation == generation,
           cached.projectionVersion == projected,
           cached.manifestProjected == manifestProjected,
           cached.chunkCount == chunkCount {
            let audioDir = directory.appendingPathComponent("audio", isDirectory: true)
            let audioPathSafe = (try? validateRecordingPath(audioDir)) != nil
            if audioPathSafe,
               let dirStamp = FileStatStamp.read(at: directory), dirStamp == cached.directoryStamp,
               let audioStamp = FileStatStamp.read(at: audioDir), audioStamp == cached.audioDirectoryStamp,
               FileStatStamp.read(at: directory.appendingPathComponent("manifest.json")) == cached.manifestFileStamp,
               FileStatStamp.read(at: directory.appendingPathComponent("transcript.json")) == cached.jsonFileStamp,
               FileStatStamp.read(at: directory.appendingPathComponent("transcript.md")) == cached.markdownFileStamp {
                return RecordingFileInspection(issue: nil, automaticEdit: nil)
            }
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
        }
        guard files.fileExists(atPath: directory.path) else {
            let candidates = try recordingDirectoryCandidates(sessionID: sessionID)
            if candidates.count > 1 { return try problem(.ambiguousLocation, candidates: candidates.map(relativeRecordingPath)) }
            if let candidate = candidates.first {
                guard allowRelocation else { return try problem(.missingDirectory, candidates: [relativeRecordingPath(candidate)]) }
                do { try relocateRecording(sessionID: sessionID, to: candidate) }
                catch ArchiveError.invalidQuery { return try problem(.unsafePath, candidates: [relativeRecordingPath(candidate)]) }
                catch ArchiveError.projectionConflict { return try problem(.audioMismatch, candidates: [relativeRecordingPath(candidate)]) }
                return try inspectRecordingFiles(sessionID: sessionID)
            }
            return try problem(.missingDirectory, actions: [.restoreDatabase, .deleteRecording])
        }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return try problem(.unsafePath) }
        let names = ["transcript.json", "transcript.md", "manifest.json"]
        var data: [String: Data] = [:]
        var hashes: [String: String] = [:]
        var invalidFiles: [String] = []
        for name in names {
            let file = directory.appendingPathComponent(name)
            do { data[name] = try readRecordingFile(file) }
            catch ArchiveError.invalidQuery { return try problem(.unsafePath) }
            catch ArchiveError.invalidTranscript {
                invalidFiles.append(name)
                hashes[name] = try ContentHash.sha256(fileAt: file)
            }
            if hashes[name] == nil { hashes[name] = data[name].map(ContentHash.sha256) ?? "missing" }
        }
        let document = try currentTranscriptOrNil(sessionID: sessionID)
        let currentJSON = try document.map { try WireJSON.encode($0) }
        let currentMarkdown = document.map { Data(transcriptMarkdown($0).utf8) }
        let currentLegacyMarkdown = document.map { Data(legacyTranscriptMarkdown($0).utf8) }
        var actions: [RecordingFileRecoveryAction] = [.restoreDatabase]
        var edits: [RecordingFileRecoveryAction: [TranscriptSpan]] = [:]
        if let document {
            for action in [RecordingFileRecoveryAction.useJSON, .useMarkdown] {
                let bytes = data[action == .useJSON ? "transcript.json" : "transcript.md"]
                if let bytes {
                    do {
                        // Unchanged app projections already carry the authoritative span identities.
                        let unchanged = action == .useJSON
                            ? (bytes == currentJSON)
                            : (bytes == currentMarkdown || bytes == currentLegacyMarkdown)
                        edits[action] = unchanged ? document.spans : try editedSpans(bytes, action: action, original: document)
                        actions.append(action)
                    } catch is DecodingError { /* Invalid edits remain visible and require a different choice. */ }
                    catch ArchiveError.invalidTranscript { }
                    catch ArchiveError.projectionConflict { }
                    catch ArchiveError.staleSource { }
                }
            }
        }
        actions.append(.deleteRecording)
        var required: [String] = projected > 0 ? ["transcript.json", "transcript.md"] : []
        if row.integer(4) == 1 { required.append("manifest.json") }
        if !invalidFiles.isEmpty { return try problem(.invalidEdit, hashes: hashes, actions: actions) }
        let missing = required.filter { data[$0] == nil }
        if !missing.isEmpty { return try problem(.missingFiles, missing: missing, hashes: hashes, actions: actions) }
        if data["manifest.json"] != nil, try directoryIdentity(directory) != sessionID {
            return try problem(.invalidEdit, hashes: hashes, actions: actions)
        }
        let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        do { try validateRecordingPath(audioDirectory) }
        catch ArchiveError.invalidQuery { return try problem(.unsafePath) }
        if !files.fileExists(atPath: audioDirectory.path) {
            return try problem(.missingFiles, missing: ["audio"], hashes: hashes, actions: [.restoreDatabase, .deleteRecording])
        }
        // Initial projection has no prior files. Appends compare against the last projected version.
        if projected == 0, document != nil {
            if let json = data["transcript.json"], json != currentJSON {
                return try problem(.invalidEdit, hashes: hashes, actions: actions)
            }
            if let markdown = data["transcript.md"], markdown != currentMarkdown && markdown != currentLegacyMarkdown {
                return try problem(.invalidEdit, hashes: hashes, actions: actions)
            }
        }
        if projected > 0,
           let projectionHash,
           let existingJSON = data["transcript.json"],
           let existingMarkdown = data["transcript.md"],
           ContentHash.sha256(existingJSON + existingMarkdown) == projectionHash {
            cacheVerifiedRecordingFiles(sessionID: sessionID)
            return RecordingFileInspection(issue: nil, automaticEdit: nil)
        }
        guard projected > 0, let document else {
            cacheVerifiedRecordingFiles(sessionID: sessionID)
            return RecordingFileInspection(issue: nil, automaticEdit: nil)
        }
        let projectedJSON: Data?, projectedMarkdown: Data?, projectedLegacyMarkdown: Data?
        if projected == version {
            projectedJSON = currentJSON
            projectedMarkdown = currentMarkdown
            projectedLegacyMarkdown = currentLegacyMarkdown
        } else if let previous = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?", [.text(sessionID.uuidString), .integer(projected)]).first,
                  let projectedDocument = try? decodeStoredTranscript(previous.requireData(0)) {
            projectedJSON = try WireJSON.encode(projectedDocument)
            projectedMarkdown = Data(transcriptMarkdown(projectedDocument).utf8)
            projectedLegacyMarkdown = Data(legacyTranscriptMarkdown(projectedDocument).utf8)
        } else if let existingJSON = data["transcript.json"],
                  let existingMarkdown = data["transcript.md"],
                  matchesUneditedPriorProjection(existingJSON: existingJSON, existingMarkdown: existingMarkdown,
                                                 projectedVersion: projected, current: document) {
            cacheVerifiedRecordingFiles(sessionID: sessionID)
            return RecordingFileInspection(issue: nil, automaticEdit: nil)
        } else {
            guard let previous = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?", [.text(sessionID.uuidString), .integer(projected)]).first else {
                cacheVerifiedRecordingFiles(sessionID: sessionID)
                return RecordingFileInspection(issue: nil, automaticEdit: nil)
            }
            let projectedDocument = try decodeStoredTranscript(previous.requireData(0))
            projectedJSON = try WireJSON.encode(projectedDocument)
            projectedMarkdown = Data(transcriptMarkdown(projectedDocument).utf8)
            projectedLegacyMarkdown = Data(legacyTranscriptMarkdown(projectedDocument).utf8)
        }
        let jsonChanged = data["transcript.json"] != projectedJSON && data["transcript.json"] != currentJSON
        let markdownChanged = data["transcript.md"] != projectedMarkdown
            && data["transcript.md"] != projectedLegacyMarkdown
            && data["transcript.md"] != currentMarkdown
            && data["transcript.md"] != currentLegacyMarkdown
        if jsonChanged && markdownChanged { return try problem(.conflictingEdits, hashes: hashes, actions: actions) }
        if jsonChanged || markdownChanged {
            verifiedRecordingFilesCache.removeValue(forKey: sessionID)
            let action: RecordingFileRecoveryAction = jsonChanged ? .useJSON : .useMarkdown
            guard let spans = edits[action], projected == version else { return try problem(.invalidEdit, hashes: hashes, actions: actions) }
            return RecordingFileInspection(issue: nil, automaticEdit: spans)
        }
        cacheVerifiedRecordingFiles(sessionID: sessionID)
        return RecordingFileInspection(issue: nil, automaticEdit: nil)
    }

    private func recoverySpans(sessionID: UUID, action: RecordingFileRecoveryAction, original: TranscriptDocument) throws -> [TranscriptSpan] {
        guard action == .useJSON || action == .useMarkdown else { throw ArchiveError.invalidQuery }
        let file = try transcriptDirectory(sessionID: sessionID).appendingPathComponent(action == .useJSON ? "transcript.json" : "transcript.md")
        guard let data = try readRecordingFile(file) else { throw ArchiveError.staleSource }
        return try editedSpans(data, action: action, original: original)
    }

    private func editedSpans(_ data: Data, action: RecordingFileRecoveryAction, original: TranscriptDocument) throws -> [TranscriptSpan] {
        let spans: [TranscriptSpan]
        if action == .useJSON {
            let edited = try WireJSON.decode(TranscriptDocument.self, from: data)
            guard edited.sessionID == original.sessionID, edited.version == original.version, edited.generation == original.generation else { throw ArchiveError.staleSource }
            spans = edited.spans
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidTranscript }
            spans = try parseMarkdownEdit(text, original: original)
        }
        let originals = Dictionary(uniqueKeysWithValues: original.spans.map { ($0.id, $0) })
        guard Set(spans.map(\.id)).count == spans.count, spans.allSatisfy({ edited in
            guard let old = originals[edited.id] else { return false }
            return old.chunkID == edited.chunkID && old.frames == edited.frames && old.sourceRanges == edited.sourceRanges
                && !edited.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && edited.text.utf8.count <= 65_536
        }) else { throw ArchiveError.invalidTranscript }
        return spans
    }

    func sessionTranscriptVersion(_ id: UUID) throws -> Int64 {
        guard let row = try database.rows("SELECT transcript_version FROM sessions WHERE id=?", [.text(id.uuidString)]).first else { throw ArchiveError.missingRecording(id) }
        return try row.requireInt(0)
    }

    func unreadableRecordingIssue(sessionID: UUID, error: any Error) throws -> RecordingFileIssue {
        guard let row = try database.rows("SELECT document_directory,transcript_version,generation FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first else { throw ArchiveError.missingRecording(sessionID) }
        let relative = try row.requireString(0), version = try row.requireInt(1), generation = try row.requireInt(2)
        let failure = error as NSError
        let fingerprint = try issueFingerprint(sessionID: sessionID, version: version, generation: generation, relative: relative,
            kind: .readFailure, candidates: [], missing: [], hashes: ["errorDomain": failure.domain, "errorCode": String(failure.code)])
        return RecordingFileIssue(sessionID: sessionID, kind: .readFailure, relativeDirectory: relative, candidateDirectories: [], missingFiles: [],
            availableActions: [], fingerprint: fingerprint, transcriptVersion: version, generation: generation)
    }

    private func issueFingerprint(sessionID: UUID, version: Int64, generation: Int64, relative: String, kind: RecordingFileIssueKind, candidates: [String], missing: [String], hashes: [String: String]) throws -> String {
        ContentHash.sha256(try WireJSON.encode(FileIssueFingerprint(sessionID: sessionID, version: version, generation: generation, directory: relative,
            kind: kind, candidates: candidates.sorted(), missing: missing.sorted(), hashes: hashes)))
    }

    func relativeRecordingPath(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
    }

    /// Check every existing path component before reading or writing. A missing tail is allowed for explicit recovery.
    func validateRecordingPath(_ url: URL) throws {
        let base = rootURL.standardizedFileURL
        let target = url.standardizedFileURL
        let recordings = base.appendingPathComponent("Documents/recordings").path
        guard target.path == url.path, target.path.hasPrefix(recordings + "/") else { throw ArchiveError.invalidQuery }
        let components = String(target.path.dropFirst(base.path.count + 1)).split(separator: "/")
        var cursor = base
        for (index, component) in components.enumerated() {
            cursor.appendPathComponent(String(component))
            do {
                let attributes = try files.attributesOfItem(atPath: cursor.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular,
                      index == components.count - 1 || type == .typeDirectory else { throw ArchiveError.invalidQuery }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        }
    }

    private func readRecordingFile(_ url: URL) throws -> Data? {
        try validateRecordingPath(url)
        guard files.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ArchiveError.invalidQuery }
        guard let size = values.fileSize, size <= 8 * 1024 * 1024 else { throw ArchiveError.invalidTranscript }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalidTranscript }
        return data
    }

    /// A stable ID must be in a document, not merely in a user-changeable directory name.
    func directoryIdentity(_ directory: URL) throws -> UUID? {
        if let data = try readRecordingFile(directory.appendingPathComponent("manifest.json")) {
            do {
                let manifest = try WireJSON.decode(RecordingManifest.self, from: data)
                let known = try database.rows("SELECT manifest FROM chunks WHERE session_id=?", [.text(manifest.sessionID.uuidString)]).map { try WireJSON.decode(ChunkManifest.self, from: $0.requireData(0)) }
                let byID = Dictionary(uniqueKeysWithValues: known.map { ($0.chunkID, $0) })
                guard !manifest.chunks.isEmpty, Set(manifest.chunks.map(\.chunkID)).count == manifest.chunks.count,
                      try manifest.chunks.allSatisfy({ item in
                          guard let original = byID[item.chunkID] else { return false }
                          return try WireJSON.encode(item) == WireJSON.encode(original)
                      }) else { return nil }
                return manifest.sessionID
            } catch is DecodingError { return nil }
        }
        if let data = try readRecordingFile(directory.appendingPathComponent("transcript.json")) {
            do {
                let document = try WireJSON.decode(TranscriptDocument.self, from: data)
                guard let row = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?", [.text(document.sessionID.uuidString), .integer(document.version)]).first else { return nil }
                let original = try decodeStoredTranscript(row.requireData(0))
                _ = try editedSpans(data, action: .useJSON, original: original)
                return document.sessionID
            } catch is DecodingError { return nil }
            catch ArchiveError.invalidTranscript { return nil }
            catch ArchiveError.staleSource { return nil }
        }
        // Before the first transcript/manifest projection, durable chunk sidecars carry the same ID.
        let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        try validateRecordingPath(audioDirectory)
        guard files.fileExists(atPath: audioDirectory.path) else { return nil }
        var identity: UUID?
        for name in try files.contentsOfDirectory(atPath: audioDirectory.path) where name.hasSuffix(".manifest.json") {
            let file = audioDirectory.appendingPathComponent(name)
            guard let data = try readRecordingFile(file) else { continue }
            let manifest: ChunkManifest
            do { manifest = try WireJSON.decode(ChunkManifest.self, from: data) }
            catch is DecodingError { return nil }
            guard let row = try database.rows("SELECT manifest_hash FROM chunks WHERE id=? AND session_id=?", [.text(manifest.chunkID.uuidString), .text(manifest.sessionID.uuidString)]).first,
                  row.string(0) == ContentHash.sha256(data), identity == nil || identity == manifest.sessionID else { return nil }
            identity = manifest.sessionID
        }
        return identity
    }

    private func recordingDirectoryCandidates(sessionID: UUID) throws -> [URL] {
        let root = rootURL.appendingPathComponent("Documents/recordings", isDirectory: true)
        // Check its ancestors through a synthetic child without following a symlink at recordings itself.
        try validateRecordingPath(root.appendingPathComponent(".path-check"))
        guard files.fileExists(atPath: root.path) else { return [] }
        var pending = [root], result: [URL] = []
        while let directory = pending.popLast() {
            // URL enumeration rewrites /var to /private/var on Apple platforms. Retain the trusted
            // root spelling and check fresh directory-entry attributes without following links.
            for name in try files.contentsOfDirectory(atPath: directory.path) {
                let child = directory.appendingPathComponent(name, isDirectory: true)
                let attributes = try files.attributesOfItem(atPath: child.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                if try directoryIdentity(child) == sessionID { result.append(child) }
                // Audio has no recording directories; skipping it also avoids scanning every chunk sidecar.
                if child.lastPathComponent != "audio" { pending.append(child) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

private struct FileIssueFingerprint: Encodable {
    let sessionID: UUID
    let version: Int64
    let generation: Int64
    let directory: String
    let kind: RecordingFileIssueKind
    let candidates: [String]
    let missing: [String]
    let hashes: [String: String]
}
