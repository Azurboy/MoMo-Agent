import Foundation
import CSQLite

// The connection is confined to ArchiveStore; no handle or cursor leaves this module.
final class ArchiveDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private(set) var insightRevision: UInt64 = 0
    private(set) var timelineRevision: UInt64 = 0
    private(set) var rollbackCount: UInt64 = 0
    private var insightRows: [String: Set<Int64>] = [:]
    private var insightNeedsFullScan = false
    var compactingTranscriptHistory = false
    init(url: URL) throws {
        var pointer: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #endif
        let code = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw ArchiveError.database(code)
        }
        handle = pointer
        do {
            try execute("PRAGMA foreign_keys = ON")
            let existingPages = try rows("PRAGMA page_count").first?.integer(0) ?? 0
            if existingPages == 0 {
                try execute("PRAGMA auto_vacuum = INCREMENTAL")
            }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA temp_store = MEMORY")
            sqlite3_busy_timeout(handle, 5000)
            let version = try rows("PRAGMA user_version").first?.integer(0) ?? 0
            guard version <= 15 else { throw ArchiveError.incompatibleDatabase(Int(version)) }
            if version == 0 { try migrate() }
            else if version < 3 {
                try transaction {
                    if version == 1 { try execute("ALTER TABLE sessions ADD COLUMN keep_audio INTEGER NOT NULL DEFAULT 0") }
                    try execute("ALTER TABLE deletions ADD COLUMN acknowledged_device TEXT")
                    try execute("PRAGMA user_version = 3")
                }
            }
            if version < 4 {
                try transaction {
                    try execute("CREATE TABLE epoch_closures(epoch_id TEXT PRIMARY KEY,end_frame INTEGER NOT NULL)")
                    try execute("CREATE TABLE analysis_epochs(epoch_id TEXT NOT NULL REFERENCES epochs(id),configuration_hash TEXT NOT NULL,generation INTEGER NOT NULL,attempt_id TEXT,last_input_hash TEXT,checkpoint BLOB,PRIMARY KEY(epoch_id,configuration_hash))")
                    try execute("CREATE TABLE analysis_windows(id TEXT PRIMARY KEY,epoch_id TEXT NOT NULL REFERENCES epochs(id),session_id TEXT NOT NULL REFERENCES sessions(id),generation INTEGER NOT NULL,configuration_hash TEXT NOT NULL,descriptor BLOB NOT NULL,state TEXT NOT NULL DEFAULT 'pending',attempt_id TEXT,raw_result BLOB)")
                    try execute("CREATE TABLE analysis_coverage(epoch_id TEXT NOT NULL REFERENCES epochs(id),configuration_hash TEXT NOT NULL,start_frame INTEGER NOT NULL,end_frame INTEGER NOT NULL,kind TEXT NOT NULL,PRIMARY KEY(epoch_id,configuration_hash,start_frame,end_frame,kind))")
                    try execute("PRAGMA user_version = 4")
                }
            }
            if version < 5 {
                try transaction {
                    try execute("CREATE TABLE capture_events(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,epoch_id TEXT NOT NULL,source_device TEXT NOT NULL,kind TEXT NOT NULL,payload BLOB NOT NULL)")
                    try execute("CREATE INDEX capture_events_session ON capture_events(session_id)")
                    try execute("PRAGMA user_version = 5")
                }
            }
            if version < 6 {
                try transaction {
                    try execute("ALTER TABLE sessions ADD COLUMN document_directory TEXT")
                    try execute("ALTER TABLE sessions ADD COLUMN manifest_projected INTEGER NOT NULL DEFAULT 0")
                    for row in try rows("SELECT id,(SELECT relative_path FROM chunks WHERE session_id=s.id ORDER BY rowid LIMIT 1) FROM sessions s") {
                        guard let path = row.string(1) else { continue }
                        let directory = (path as NSString).deletingLastPathComponent
                        try execute("UPDATE sessions SET document_directory=?,manifest_projected=? WHERE id=?", [
                            .text((directory as NSString).deletingLastPathComponent), .integer(version == 0 ? 0 : 1), .text(try row.requireString(0))
                        ])
                    }
                    try execute("CREATE UNIQUE INDEX session_document_directory ON sessions(document_directory) WHERE document_directory IS NOT NULL")
                    try execute("PRAGMA user_version = 6")
                }
            }
            if version < 7 {
                try transaction {
                    try execute("CREATE TABLE transcription_batches(id TEXT PRIMARY KEY,configuration_hash TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'ready',end_reason TEXT,current_execution TEXT)")
                    try execute("CREATE TABLE transcription_batch_windows(batch_id TEXT NOT NULL REFERENCES transcription_batches(id),window_id TEXT NOT NULL,session_id TEXT NOT NULL,epoch_id TEXT NOT NULL,start_frame INTEGER NOT NULL,end_frame INTEGER NOT NULL,PRIMARY KEY(batch_id,window_id))")
                    try execute("CREATE INDEX batch_windows_epoch ON transcription_batch_windows(epoch_id,start_frame,end_frame)")
                    try execute("CREATE TABLE transcription_batch_ranges(batch_id TEXT NOT NULL REFERENCES transcription_batches(id),session_id TEXT NOT NULL,epoch_id TEXT NOT NULL,timebase REAL NOT NULL,start_frame INTEGER NOT NULL,end_frame INTEGER NOT NULL,kind TEXT NOT NULL,PRIMARY KEY(batch_id,epoch_id,start_frame,end_frame,kind))")
                    try execute("CREATE TABLE transcription_batch_executions(id TEXT PRIMARY KEY,batch_id TEXT NOT NULL REFERENCES transcription_batches(id),origin TEXT NOT NULL,end_reason TEXT)")
                    try execute("ALTER TABLE plans ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
                    try execute("ALTER TABLE plans ADD COLUMN projection_hash TEXT")
                    try execute("PRAGMA user_version = 7")
                }
            }
            if version < 8 {
                try transaction {
                    try execute("CREATE TABLE reconcile_requests(id TEXT PRIMARY KEY,source_device TEXT NOT NULL,request_hash TEXT NOT NULL,request BLOB NOT NULL,response BLOB NOT NULL,response_id TEXT NOT NULL,pending INTEGER NOT NULL DEFAULT 1)")
                    try execute("CREATE INDEX reconcile_pending ON reconcile_requests(pending,source_device)")
                    try execute("CREATE TABLE watch_status(session_id TEXT PRIMARY KEY,source_device TEXT NOT NULL,source_store TEXT NOT NULL,revision INTEGER NOT NULL,payload BLOB NOT NULL,observed_at REAL,restored INTEGER NOT NULL)")
                    try execute("PRAGMA user_version = 8")
                }
            }
            if version < 9 {
                try transaction {
                    try execute("CREATE TABLE processing_failures(session_id TEXT NOT NULL REFERENCES sessions(id),epoch_id TEXT NOT NULL REFERENCES epochs(id),generation INTEGER NOT NULL,configuration_hash TEXT NOT NULL,stage TEXT NOT NULL,work_id TEXT NOT NULL,start_frame INTEGER NOT NULL,end_frame INTEGER NOT NULL,error_code TEXT NOT NULL,attempts INTEGER NOT NULL,retry_after REAL NOT NULL,PRIMARY KEY(epoch_id,generation,configuration_hash,stage,work_id))")
                    try execute("PRAGMA user_version = 9")
                }
            }
            if version < 10 {
                try transaction {
                    try execute("ALTER TABLE analysis_epochs ADD COLUMN has_pending INTEGER NOT NULL DEFAULT 1")
                    try execute("CREATE TABLE analysis_range_inputs(epoch_id TEXT NOT NULL REFERENCES epochs(id),configuration_hash TEXT NOT NULL,generation INTEGER NOT NULL,start_frame INTEGER NOT NULL,input_hash TEXT NOT NULL,PRIMARY KEY(epoch_id,configuration_hash,generation,start_frame))")
                    try execute("CREATE TABLE processing_turns(epoch_id TEXT NOT NULL REFERENCES epochs(id),configuration_hash TEXT NOT NULL,last_turn INTEGER NOT NULL,PRIMARY KEY(epoch_id,configuration_hash))")
                    try execute("CREATE INDEX analysis_windows_pending ON analysis_windows(configuration_hash,state,epoch_id)")
                    try execute("CREATE INDEX chunks_epoch_frames ON chunks(epoch_id,json_extract(CAST(manifest AS TEXT),'$.frames.start'))")
                    try execute("CREATE INDEX chunks_epoch_ends ON chunks(epoch_id,json_extract(CAST(manifest AS TEXT),'$.frames.start')+json_extract(CAST(manifest AS TEXT),'$.frames.count'))")
                    try execute("INSERT OR IGNORE INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind) SELECT epoch_id,configuration_hash,json_extract(CAST(descriptor AS TEXT),'$.coreFrames.start'),json_extract(CAST(descriptor AS TEXT),'$.coreFrames.start')+json_extract(CAST(descriptor AS TEXT),'$.coreFrames.count'),'analyzed' FROM analysis_windows")
                    try execute("PRAGMA user_version = 10")
                }
            }
            if version < 11 {
                try transaction {
                    try execute("ALTER TABLE sessions ADD COLUMN transcript_preview TEXT")
                    // Earlier versions rebuilt search rows in document order on every commit.
                    try execute("UPDATE sessions SET transcript_preview=(SELECT substr(t.text,1,160) FROM transcript_search t WHERE t.session_id=sessions.id AND t.version=sessions.transcript_version AND length(trim(t.text))>0 ORDER BY t.rowid LIMIT 1) WHERE deleted=0")
                    try execute("PRAGMA user_version = 11")
                }
            }
            if version < 12 {
                try transaction {
                    // VACUUM can renumber implicit rowids. Persist existing cursors before reclaiming pages.
                    for table in ["sessions", "chunks", "receipt_outbox"] {
                        try execute("ALTER TABLE \(table) ADD COLUMN storage_sequence INTEGER NOT NULL DEFAULT 0")
                        try execute("UPDATE \(table) SET storage_sequence=rowid")
                        try execute("CREATE UNIQUE INDEX \(table)_storage_sequence ON \(table)(storage_sequence)")
                        try execute("CREATE TRIGGER \(table)_assign_sequence AFTER INSERT ON \(table) WHEN NEW.storage_sequence=0 BEGIN UPDATE \(table) SET storage_sequence=(SELECT COALESCE(MAX(storage_sequence),0)+1 FROM \(table)) WHERE rowid=NEW.rowid; END")
                    }
                    try execute("ALTER TABLE transcript_versions ADD COLUMN storage_format INTEGER NOT NULL DEFAULT 0")
                    try execute("CREATE INDEX transcript_uncompacted ON transcript_versions(session_id,version) WHERE storage_format=0")
                    try execute("CREATE TABLE transcript_blocks(id INTEGER PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),hash TEXT NOT NULL,document BLOB NOT NULL,UNIQUE(session_id,hash))")
                    try execute("PRAGMA user_version = 12")
                }
            }
            if version < 13 {
                try transaction {
                    try execute("CREATE TABLE voice_profiles(id TEXT PRIMARY KEY,name TEXT NOT NULL,is_owner INTEGER NOT NULL DEFAULT 0)")
                    try execute("CREATE UNIQUE INDEX one_owner_voice ON voice_profiles(is_owner) WHERE is_owner=1")
                    try execute("CREATE TABLE speaker_clusters(id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),model_revision TEXT NOT NULL,centroid BLOB NOT NULL,sample_count INTEGER NOT NULL)")
                    try execute("CREATE INDEX speaker_cluster_session ON speaker_clusters(session_id,model_revision)")
                    try execute("CREATE TABLE speaker_observations(span_id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),cluster_id TEXT NOT NULL REFERENCES speaker_clusters(id),model_revision TEXT NOT NULL,evidence BLOB NOT NULL,confirmed_person TEXT,rejected_owner INTEGER NOT NULL DEFAULT 0,matched_person TEXT,updated_at REAL NOT NULL)")
                    try execute("CREATE INDEX speaker_observation_session ON speaker_observations(session_id)")
                    try execute("CREATE INDEX speaker_examples ON speaker_observations(model_revision,confirmed_person,updated_at)")
                    try execute("PRAGMA user_version = 13")
                }
            }
            if version < 14 {
                try transaction {
                    try execute("CREATE TABLE voice_rejections(span_id TEXT NOT NULL REFERENCES speaker_observations(span_id) ON DELETE CASCADE,person_id TEXT NOT NULL REFERENCES voice_profiles(id) ON DELETE CASCADE,PRIMARY KEY(span_id,person_id))")
                    try execute("CREATE INDEX voice_rejection_person ON voice_rejections(person_id,span_id)")
                    try execute("INSERT INTO voice_rejections(span_id,person_id) SELECT o.span_id,p.id FROM speaker_observations o JOIN voice_profiles p ON p.is_owner=1 WHERE o.rejected_owner=1")
                    try execute("CREATE TABLE speaker_cluster_conflicts(first_id TEXT NOT NULL REFERENCES speaker_clusters(id) ON DELETE CASCADE,second_id TEXT NOT NULL REFERENCES speaker_clusters(id) ON DELETE CASCADE,PRIMARY KEY(first_id,second_id))")
                    try execute("PRAGMA user_version = 14")
                }
            }
            if version < 15 {
                try transaction {
                    try execute("CREATE TABLE IF NOT EXISTS speaker_feedback_anchors(id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),epoch_id TEXT NOT NULL REFERENCES epochs(id),start_frame INTEGER NOT NULL,end_frame INTEGER NOT NULL,confirmed_person TEXT,rejected_people_json TEXT NOT NULL,batch_key TEXT NOT NULL,batch_size INTEGER NOT NULL,seeded_revision TEXT,reconciled INTEGER NOT NULL DEFAULT 0)")
                    try execute("CREATE INDEX IF NOT EXISTS speaker_feedback_anchor_session ON speaker_feedback_anchors(session_id,epoch_id,reconciled,start_frame)")
                    try execute("CREATE TABLE IF NOT EXISTS voice_profile_seeds(anchor_id TEXT PRIMARY KEY REFERENCES speaker_feedback_anchors(id) ON DELETE CASCADE,person_id TEXT NOT NULL REFERENCES voice_profiles(id) ON DELETE CASCADE,session_id TEXT NOT NULL REFERENCES sessions(id),model_revision TEXT NOT NULL,embedding BLOB NOT NULL,clean_seconds REAL NOT NULL,batch_key TEXT NOT NULL)")
                    try execute("CREATE INDEX IF NOT EXISTS voice_profile_seed_lookup ON voice_profile_seeds(model_revision,person_id)")
                    try execute("PRAGMA user_version = 15")
                }
            }
            // Disposable preview receipts are additive and do not change the archive's data format.
            try execute("CREATE TABLE IF NOT EXISTS waveform_preparations(chunk_id TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,manifest_hash TEXT NOT NULL,generation INTEGER NOT NULL,cache_generation TEXT NOT NULL)")
            // Overlap joining reads one durable neighbor, not every completed window in a long recording.
            try execute("CREATE INDEX IF NOT EXISTS analysis_windows_core_ends ON analysis_windows(configuration_hash,epoch_id,json_extract(CAST(descriptor AS TEXT),'$.coreFrames.start')+json_extract(CAST(descriptor AS TEXT),'$.coreFrames.count')) WHERE state='complete'")
            try ensurePerformanceSchema()
            for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
                _ = try ArchiveFilePolicy.apply(to: URL(fileURLWithPath: path))
            }
            sqlite3_update_hook(handle, { context, operation, _, table, row in
                guard let context, let table else { return }
                Unmanaged<ArchiveDatabase>.fromOpaque(context).takeUnretainedValue()
                    .noteInsightChange(table: String(cString: table), row: row, operation: operation)
            }, Unmanaged.passUnretained(self).toOpaque())
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }
    deinit {
        if let handle { sqlite3_update_hook(handle, nil, nil); sqlite3_close(handle) }
    }

    private func noteInsightChange(table: String, row: Int64, operation: Int32) {
        if compactingTranscriptHistory { return }
        if ["sessions", "chunks", "epochs", "transcript_versions", "capture_events", "epoch_closures",
            "analysis_windows", "analysis_coverage", "transcription_jobs", "processing_failures", "watch_status"].contains(table) {
            timelineRevision &+= 1
        }
        guard ["sessions", "chunks", "transcript_versions", "capture_events", "epoch_closures", "analysis_windows", "analysis_coverage"].contains(table) else { return }
        insightRevision &+= 1
        if operation == SQLITE_DELETE || insightRows.values.reduce(0, { $0 + $1.count }) >= 512 {
            insightNeedsFullScan = true
            insightRows.removeAll()
        } else if !insightNeedsFullScan { insightRows[table, default: []].insert(row) }
    }

    /// Nil includes deletion/rollback ambiguity. Foreign-connection writes are checked separately.
    func changedInsightSessions() throws -> Set<UUID>? {
        guard !insightNeedsFullScan else { return nil }
        var sessions = Set<UUID>()
        for (table, ids) in insightRows {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let selection: String
            switch table {
            case "sessions": selection = "SELECT id FROM sessions WHERE rowid IN (\(placeholders))"
            case "analysis_coverage", "epoch_closures":
                selection = "SELECT e.session_id FROM \(table) c JOIN epochs e ON e.id=c.epoch_id WHERE c.rowid IN (\(placeholders))"
            default: selection = "SELECT session_id FROM \(table) WHERE rowid IN (\(placeholders))"
            }
            let found = try rows(selection, ids.map(SQLValue.integer))
            guard found.count == ids.count else { return nil }
            for row in found { sessions.insert(try row.requireUUID(0)) }
        }
        return sessions
    }

    func acknowledgeInsightChanges() { insightRows.removeAll(); insightNeedsFullScan = false }

    var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    func invalidateRowLocationsAfterVacuum() {
        try? execute("UPDATE epochs SET min_chunk_rowid=(SELECT MIN(rowid) FROM chunks WHERE epoch_id=epochs.id)")
        insightNeedsFullScan = true
        insightRows.removeAll()
        insightRevision &+= 1
        timelineRevision &+= 1
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        Set(try rows("PRAGMA table_info(\(table))").compactMap { $0.string(1) })
    }

    private func ensurePerformanceSchema() throws {
        let chunkCols = try tableColumns("chunks")
        let epochCols = try tableColumns("epochs")
        let windowCols = try tableColumns("analysis_windows")
        let planCols = try tableColumns("plans")

        let neededChunkCols: [(String, String)] = [
            ("start_frame", "INTEGER NOT NULL DEFAULT 0"),
            ("end_frame", "INTEGER NOT NULL DEFAULT 0"),
            ("byte_count", "INTEGER NOT NULL DEFAULT 0"),
            ("sealed_at", "REAL NOT NULL DEFAULT 0"),
            ("wall_clock_anchor", "REAL NOT NULL DEFAULT 0"),
            ("timezone_offset", "INTEGER NOT NULL DEFAULT 0"),
            ("timebase_hz", "REAL NOT NULL DEFAULT 16000")
        ]
        let neededEpochCols: [(String, String)] = [
            ("min_chunk_rowid", "INTEGER"),
            ("max_received_end_frame", "INTEGER NOT NULL DEFAULT 0"),
            ("wall_clock_anchor", "REAL"),
            ("timezone_offset", "INTEGER")
        ]
        let neededWindowCols: [(String, String)] = [
            ("core_start", "INTEGER NOT NULL DEFAULT 0"),
            ("core_end", "INTEGER NOT NULL DEFAULT 0"),
            ("context_start", "INTEGER NOT NULL DEFAULT 0"),
            ("context_end", "INTEGER NOT NULL DEFAULT 0"),
            ("analysis_anchor", "INTEGER NOT NULL DEFAULT 0"),
            ("model_core_start", "INTEGER NOT NULL DEFAULT 0")
        ]

        let missingChunk = neededChunkCols.filter { !chunkCols.contains($0.0) }
        let missingEpoch = neededEpochCols.filter { !epochCols.contains($0.0) }
        let missingWindow = neededWindowCols.filter { !windowCols.contains($0.0) }
        let missingPlanClean = !planCols.contains("files_cleaned")

        if !missingChunk.isEmpty || !missingEpoch.isEmpty || !missingWindow.isEmpty || missingPlanClean {
            try transaction {
                for (name, def) in missingChunk {
                    try execute("ALTER TABLE chunks ADD COLUMN \(name) \(def)")
                }
                if !missingChunk.isEmpty {
                    try execute("""
                        UPDATE chunks SET
                          start_frame = COALESCE(json_extract(CAST(manifest AS TEXT),'$.frames.start'), 0),
                          end_frame = COALESCE(json_extract(CAST(manifest AS TEXT),'$.frames.start') + json_extract(CAST(manifest AS TEXT),'$.frames.count'), 0),
                          byte_count = COALESCE(json_extract(CAST(manifest AS TEXT),'$.byteCount'), 0),
                          sealed_at = COALESCE((julianday(json_extract(CAST(manifest AS TEXT),'$.sealedAt')) - 2440587.5) * 86400.0, 0),
                          wall_clock_anchor = COALESCE((julianday(json_extract(CAST(manifest AS TEXT),'$.wallClockAnchor')) - 2440587.5) * 86400.0, 0),
                          timezone_offset = COALESCE(json_extract(CAST(manifest AS TEXT),'$.timezoneOffset'), 0),
                          timebase_hz = COALESCE(CAST(json_extract(CAST(manifest AS TEXT),'$.timebaseHz') AS REAL), 16000)
                        """)
                }
                for (name, def) in missingEpoch {
                    try execute("ALTER TABLE epochs ADD COLUMN \(name) \(def)")
                }
                if !missingEpoch.isEmpty {
                    try execute("""
                        UPDATE epochs SET
                          min_chunk_rowid = (SELECT MIN(rowid) FROM chunks WHERE epoch_id = epochs.id),
                          max_received_end_frame = COALESCE((SELECT MAX(end_frame) FROM chunks WHERE epoch_id = epochs.id), 0),
                          wall_clock_anchor = (SELECT wall_clock_anchor FROM chunks WHERE epoch_id = epochs.id ORDER BY start_frame, rowid LIMIT 1),
                          timezone_offset = (SELECT timezone_offset FROM chunks WHERE epoch_id = epochs.id ORDER BY start_frame, rowid LIMIT 1)
                        """)
                }
                for (name, def) in missingWindow {
                    try execute("ALTER TABLE analysis_windows ADD COLUMN \(name) \(def)")
                }
                if !missingWindow.isEmpty {
                    try execute("""
                        UPDATE analysis_windows SET
                          core_start = COALESCE(json_extract(CAST(descriptor AS TEXT),'$.coreFrames.start'), 0),
                          core_end = COALESCE(json_extract(CAST(descriptor AS TEXT),'$.coreFrames.start') + json_extract(CAST(descriptor AS TEXT),'$.coreFrames.count'), 0),
                          context_start = COALESCE(json_extract(CAST(descriptor AS TEXT),'$.contextFrames.start'), 0),
                          context_end = COALESCE(json_extract(CAST(descriptor AS TEXT),'$.contextFrames.start') + json_extract(CAST(descriptor AS TEXT),'$.contextFrames.count'), 0),
                          analysis_anchor = COALESCE(json_extract(CAST(descriptor AS TEXT),'$.analysisAnchor'), 0),
                          model_core_start = COALESCE(json_extract(CAST(descriptor AS TEXT),'$.modelCoreFrames.start'), 0)
                        """)
                }
                if missingPlanClean {
                    try execute("ALTER TABLE plans ADD COLUMN files_cleaned INTEGER NOT NULL DEFAULT 0")
                }
            }
        }

        for indexSQL in [
            "CREATE INDEX IF NOT EXISTS epochs_session ON epochs(session_id)",
            "CREATE INDEX IF NOT EXISTS epochs_wall_clock ON epochs(wall_clock_anchor)",
            "CREATE INDEX IF NOT EXISTS analysis_windows_session ON analysis_windows(session_id)",
            "CREATE INDEX IF NOT EXISTS analysis_windows_epoch_state ON analysis_windows(epoch_id, state)",
            "CREATE INDEX IF NOT EXISTS analysis_windows_epoch_config_core ON analysis_windows(epoch_id, configuration_hash, core_start, core_end)",
            "CREATE INDEX IF NOT EXISTS analysis_windows_epoch_core_end ON analysis_windows(configuration_hash, epoch_id, core_end) WHERE state='complete'",
            "CREATE INDEX IF NOT EXISTS analysis_windows_companion ON analysis_windows(epoch_id, generation, configuration_hash, state, analysis_anchor, model_core_start)",
            "CREATE INDEX IF NOT EXISTS chunks_epoch_start ON chunks(epoch_id, start_frame)",
            "CREATE INDEX IF NOT EXISTS chunks_epoch_end ON chunks(epoch_id, end_frame)",
            "CREATE INDEX IF NOT EXISTS chunks_retention_sealed ON chunks(retention, sealed_at, storage_sequence)",
            "CREATE INDEX IF NOT EXISTS transcription_batch_ranges_session ON transcription_batch_ranges(session_id, kind)",
            "CREATE INDEX IF NOT EXISTS transcription_batch_windows_session ON transcription_batch_windows(session_id)",
            "CREATE INDEX IF NOT EXISTS sessions_active_recorded ON sessions(deleted, recorded_at DESC, id)",
            "CREATE INDEX IF NOT EXISTS sessions_projection_pending ON sessions(id) WHERE deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL AND (transcript_version>projection_version OR manifest_projected=0)",
            "CREATE INDEX IF NOT EXISTS receipt_outbox_pending ON receipt_outbox(sent, storage_sequence)",
            "CREATE INDEX IF NOT EXISTS deletions_pending_clean ON deletions(files_cleaned)",
            "CREATE INDEX IF NOT EXISTS plans_state ON plans(state)",
            "CREATE INDEX IF NOT EXISTS plans_pending_clean ON plans(state, files_cleaned)"
        ] {
            try execute(indexSQL)
        }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw ArchiveError.database(code) }
    }

    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [SQLRow] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var columns: [SQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: columns.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: columns.append(.double(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT: columns.append(.text(String(cString: sqlite3_column_text(statement, index))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index) { columns.append(.blob(Data(bytes: bytes, count: count))) }
                    else { columns.append(.blob(Data())) }
                default: columns.append(.null)
                }
            }
            result.append(SQLRow(values: columns))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw ArchiveError.database(code) }
        return result
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            rollbackCount &+= 1
            let original = error
            // SQLITE_FULL and some I/O errors can already have rolled back the
            // transaction. Preserve that error instead of replacing it with
            // SQLITE_ERROR from a second ROLLBACK outside a transaction.
            if sqlite3_get_autocommit(handle) == 0 { try execute("ROLLBACK") }
            throw original
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
        guard code == SQLITE_OK, let pointer else { throw ArchiveError.database(code) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string): result = sqlite3_bind_text(pointer, index, string, -1, transient)
            case .integer(let integer): result = sqlite3_bind_int64(pointer, index, integer)
            case .double(let double): result = sqlite3_bind_double(pointer, index, double)
            case .blob(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: result = sqlite3_bind_null(pointer, index)
            }
            if result != SQLITE_OK { sqlite3_finalize(pointer); throw ArchiveError.database(result) }
        }
        return pointer
    }

    private func migrate() throws {
        try transaction {
            for sql in [
                "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                "CREATE TABLE sessions (id TEXT PRIMARY KEY, source_device TEXT NOT NULL, recorded_at REAL NOT NULL, source_kind TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, transcript_version INTEGER NOT NULL DEFAULT 0, projection_version INTEGER NOT NULL DEFAULT 0, projection_hash TEXT, projection_blocked INTEGER NOT NULL DEFAULT 0, keep_audio INTEGER NOT NULL DEFAULT 0)",
                "CREATE TABLE epochs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), timebase REAL NOT NULL)",
                "CREATE TABLE chunks (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), epoch_id TEXT NOT NULL REFERENCES epochs(id), manifest BLOB NOT NULL, manifest_hash TEXT NOT NULL, audio_hash TEXT NOT NULL, relative_path TEXT NOT NULL, retention TEXT NOT NULL DEFAULT 'present', receipt_applied INTEGER NOT NULL DEFAULT 0)",
                "CREATE TABLE transcription_jobs (id TEXT PRIMARY KEY, chunk_id TEXT NOT NULL UNIQUE REFERENCES chunks(id), generation INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'pending', attempt_id TEXT, configuration_hash TEXT, error_code TEXT)",
                "CREATE TABLE receipt_outbox (id TEXT PRIMARY KEY, chunk_id TEXT NOT NULL UNIQUE REFERENCES chunks(id), payload BLOB NOT NULL, sent INTEGER NOT NULL DEFAULT 0)",
                "CREATE TABLE transcript_versions (session_id TEXT NOT NULL REFERENCES sessions(id), version INTEGER NOT NULL, document BLOB NOT NULL, PRIMARY KEY(session_id, version))",
                "CREATE TABLE transcript_search (session_id TEXT NOT NULL REFERENCES sessions(id), span_id TEXT NOT NULL, text TEXT NOT NULL, version INTEGER NOT NULL, PRIMARY KEY(session_id,span_id))",
                "CREATE TABLE plans (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE, input_hash TEXT NOT NULL, document BLOB NOT NULL, state TEXT NOT NULL DEFAULT 'pending')",
                "CREATE TABLE plan_sources (plan_id TEXT NOT NULL REFERENCES plans(id), session_id TEXT NOT NULL REFERENCES sessions(id), PRIMARY KEY(plan_id,session_id))",
                "CREATE TABLE deletions (id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id), message BLOB NOT NULL, files_cleaned INTEGER NOT NULL DEFAULT 0, acknowledged_device TEXT)",
                "CREATE TABLE agent_sources (agent_session_id TEXT NOT NULL, session_id TEXT NOT NULL REFERENCES sessions(id), version INTEGER NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(agent_session_id, session_id))",
                "CREATE TABLE agent_cleanup (agent_session_id TEXT PRIMARY KEY, completed INTEGER NOT NULL DEFAULT 0)",
                "CREATE INDEX jobs_state ON transcription_jobs(state)",
                "CREATE INDEX chunks_session ON chunks(session_id)",
                "PRAGMA user_version = 3"
            ] { try execute(sql) }
        }
    }
}

enum SQLValue { case text(String), integer(Int64), double(Double), blob(Data), null }
struct SQLRow {
    let values: [SQLValue]
    func string(_ index: Int) -> String? { if case .text(let value) = values[index] { return value }; return nil }
    func integer(_ index: Int) -> Int64? { if case .integer(let value) = values[index] { return value }; return nil }
    func double(_ index: Int) -> Double? { if case .double(let value) = values[index] { return value }; return nil }
    func data(_ index: Int) -> Data? { if case .blob(let value) = values[index] { return value }; return nil }
}
