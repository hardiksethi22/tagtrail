import Foundation
import CSQLite

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum Value {
    case text(String), integer(Int64), real(Double), null
    static func optional(_ v: Int64?) -> Value { v.map(Value.integer) ?? .null }
    static func optional(_ v: Double?) -> Value { v.map(Value.real) ?? .null }
    static func optional(_ v: String?) -> Value { v.map(Value.text) ?? .null }
}

public actor Database {
    private var handle: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close_v2(db) }
            throw DataError.database("open-failed")
        }
        handle = db
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 3000)
            try Self.execute(db, "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")
            try Self.migrate(db)
        } catch { sqlite3_close_v2(db); handle = nil; throw error }
    }
    deinit { sqlite3_close_v2(handle) }

    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DataError.database("sql-failed") }
    }
    private static func migrate(_ db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&statement,nil) == SQLITE_OK else { throw DataError.database("migration-version") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DataError.database("migration-version") }
        let version = sqlite3_column_int(statement,0)
        guard version <= 2 else { throw DataError.database("newer-schema") }
        try execute(db,"BEGIN IMMEDIATE")
        do {
            if version == 0 {
                try execute(db, """
                CREATE TABLE profiles(id TEXT PRIMARY KEY, provider TEXT NOT NULL, label TEXT NOT NULL);
                CREATE TABLE devices(
                  id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id),
                  canonic_id TEXT NOT NULL, name TEXT NOT NULL, network TEXT NOT NULL,
                  tracking_enabled INTEGER NOT NULL DEFAULT 0 CHECK(tracking_enabled IN (0,1)),
                  last_attempt_ms INTEGER, last_success_ms INTEGER, last_ingestion_ms INTEGER,
                  UNIQUE(profile_id,canonic_id));
                CREATE TABLE location_pings(
                  id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
                  report_id TEXT, fingerprint TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('geographic','semantic')),
                  latitude REAL, longitude REAL, altitude REAL, accuracy REAL,
                  provider_timestamp_ms INTEGER, timestamp_provenance TEXT NOT NULL,
                  ingested_at_ms INTEGER NOT NULL, semantic_label TEXT, source TEXT NOT NULL,
                  payload TEXT NOT NULL,
                  CHECK((latitude IS NULL AND longitude IS NULL AND kind='semantic') OR
                     (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 AND latitude IS NOT NULL AND longitude IS NOT NULL)),
                  CHECK(accuracy IS NULL OR accuracy>=0), UNIQUE(device_id,fingerprint));
                CREATE UNIQUE INDEX ping_report ON location_pings(device_id,source,report_id) WHERE report_id IS NOT NULL;
                CREATE INDEX ping_time ON location_pings(device_id,COALESCE(provider_timestamp_ms,ingested_at_ms),id);
                CREATE TABLE geocode_cache(
                  key TEXT NOT NULL, locale TEXT NOT NULL, short_label TEXT, full_address TEXT,
                  status TEXT NOT NULL, attempts INTEGER NOT NULL, next_retry_ms INTEGER, resolved_ms INTEGER,
                  PRIMARY KEY(key,locale));
                CREATE TABLE semantic_places(
                  id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id),
                  device_id TEXT REFERENCES devices(id), label TEXT NOT NULL,
                  latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
                  longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180));
                CREATE TABLE poll_runs(
                  id INTEGER PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
                  attempt_ms INTEGER NOT NULL, completed_ms INTEGER NOT NULL,
                  classification TEXT NOT NULL, inserted_count INTEGER NOT NULL, error_code TEXT);
                PRAGMA user_version=1;
                """)
            }
            if version < 2 {
                try execute(db,"CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); PRAGMA user_version=2;")
            }
            try execute(db,"COMMIT")
        } catch { try? execute(db,"ROLLBACK"); throw error }
    }

    private func run(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) throws -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw DataError.database("prepare-failed") }
        defer { sqlite3_finalize(statement) }
        for (offset,value) in values.enumerated() {
            let index = Int32(offset+1)
            let code: Int32
            switch value {
            case .text(let v): code = sqlite3_bind_text(statement,index,v,-1,transient)
            case .integer(let v): code = sqlite3_bind_int64(statement,index,v)
            case .real(let v): code = sqlite3_bind_double(statement,index,v)
            case .null: code = sqlite3_bind_null(statement,index)
            }
            guard code == SQLITE_OK else { throw DataError.database("bind-failed") }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw DataError.database("statement-failed") }
            try row?(statement)
        }
    }
    private func string(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s,i).map { String(cString:$0) } ?? ""
    }
    private func optionalString(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s,i) == SQLITE_NULL ? nil : string(s,i)
    }
    private func integer(_ s: OpaquePointer, _ i: Int32) -> Int64? {
        sqlite3_column_type(s,i) == SQLITE_NULL ? nil : sqlite3_column_int64(s,i)
    }
    public func upsertProfile(id: String, provider: String, label: String) throws {
        try run("INSERT INTO profiles VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET provider=excluded.provider,label=excluded.label",
                [.text(id),.text(provider),.text(label)])
    }
    public func upsertDevice(_ d: TrackerDevice) throws {
        try run("""
        INSERT INTO devices VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name,network=excluded.network
        """,[.text(d.id),.text(d.profileID),.text(d.canonicID),.text(d.name),.text(d.network),
              .integer(d.trackingEnabled ? 1:0),.optional(d.lastAttemptMS),.optional(d.lastSuccessMS),.optional(d.lastIngestionMS)])
    }
    public func devices(profileID: String) throws -> [TrackerDevice] {
        var result: [TrackerDevice] = []
        try run("SELECT id,profile_id,canonic_id,name,network,tracking_enabled,last_attempt_ms,last_success_ms,last_ingestion_ms FROM devices WHERE profile_id=? ORDER BY name,id",
                [.text(profileID)]) { s in
            result.append(TrackerDevice(id:self.string(s,0),profileID:self.string(s,1),canonicID:self.string(s,2),
                name:self.string(s,3),network:self.string(s,4),trackingEnabled:sqlite3_column_int(s,5) == 1,
                lastAttemptMS:self.integer(s,6),lastSuccessMS:self.integer(s,7),lastIngestionMS:self.integer(s,8)))
        }
        return result
    }
    public func setTracking(deviceID: String, enabled: Bool) throws {
        try run("UPDATE devices SET tracking_enabled=? WHERE id=?", [.integer(enabled ? 1:0),.text(deviceID)])
    }
    /// Caller validates individual entries before passing a batch; a database failure rolls back the entire batch.
    public func ingest(_ sightings: [Sighting]) throws -> Int {
        for sighting in sightings { try sighting.validate() }
        try Self.execute(handle,"BEGIN IMMEDIATE")
        var inserted = 0
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for s in sightings {
                let payload = String(decoding:try encoder.encode(s),as:UTF8.self)
                try run("""
                INSERT INTO location_pings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT DO NOTHING
                """,[.text(s.id),.text(s.deviceID),.optional(s.reportID),.text(try s.fingerprint()),.text(s.kind.rawValue),
                     .optional(s.latitude),.optional(s.longitude),.optional(s.altitude),.optional(s.accuracy),
                     .optional(s.providerTimestampMS),.text(s.timestampProvenance),.integer(s.ingestedAtMS),
                     .optional(s.semanticLabel),.text(s.source),.text(payload)])
                if sqlite3_changes(handle) > 0 {
                    inserted += 1
                    try run("UPDATE devices SET last_ingestion_ms=MAX(COALESCE(last_ingestion_ms,0),?) WHERE id=?",
                            [.integer(s.ingestedAtMS),.text(s.deviceID)])
                }
            }
            try Self.execute(handle,"COMMIT")
        } catch { try? Self.execute(handle,"ROLLBACK"); throw error }
        return inserted
    }
    public func observations(deviceID: String, sinceMS: Int64? = nil, limit: Int = 10000, offset: Int = 0) throws -> [Sighting] {
        guard limit > 0, limit <= 100_000, offset >= 0 else { throw DataError.database("invalid-pagination") }
        var rows: [Sighting] = []
        try run("""
        SELECT payload FROM location_pings WHERE device_id=? AND COALESCE(provider_timestamp_ms,ingested_at_ms)>=?
        ORDER BY COALESCE(provider_timestamp_ms,ingested_at_ms),id LIMIT ? OFFSET ?
        """,[.text(deviceID),.integer(sinceMS ?? 0),.integer(Int64(limit)),.integer(Int64(offset))]) { s in
            rows.append(try JSONDecoder().decode(Sighting.self,from:Data(self.string(s,0).utf8)))
        }
        return rows
    }
    public func recordPoll(deviceID: String, attemptMS: Int64, completedMS: Int64, classification: String, insertedCount: Int, errorCode: String?) throws {
        let allowed = ["authentication-required","credentials-locked","unsupported-device","rate-limited","network-unavailable","timeout","protocol-error","decryption-error","internal-error"]
        guard errorCode == nil || allowed.contains(errorCode!) else { throw DataError.database("invalid-error-code") }
        guard (allowed + ["success","ready","no-new-data","partial-validity","error","cancelled"]).contains(classification) else {
            throw DataError.database("invalid-poll-classification")
        }
        try Self.execute(handle,"BEGIN IMMEDIATE")
        do {
            try run("INSERT INTO poll_runs(device_id,attempt_ms,completed_ms,classification,inserted_count,error_code) VALUES(?,?,?,?,?,?)",
                    [.text(deviceID),.integer(attemptMS),.integer(completedMS),.text(classification),.integer(Int64(insertedCount)),.optional(errorCode)])
            let success = errorCode == nil
            try run("UPDATE devices SET last_attempt_ms=?, last_success_ms=CASE WHEN ? THEN ? ELSE last_success_ms END WHERE id=?",
                    [.integer(attemptMS),.integer(success ? 1:0),.integer(completedMS),.text(deviceID)])
            try Self.execute(handle,"COMMIT")
        } catch { try? Self.execute(handle,"ROLLBACK"); throw error }
    }
    public func deleteHistory(deviceID: String?) throws {
        try Self.execute(handle,"BEGIN IMMEDIATE")
        do {
            if let deviceID {
                try run("DELETE FROM location_pings WHERE device_id=?", [.text(deviceID)])
                try run("DELETE FROM poll_runs WHERE device_id=?", [.text(deviceID)])
                try run("UPDATE devices SET last_ingestion_ms=NULL WHERE id=?", [.text(deviceID)])
            } else {
                try run("DELETE FROM location_pings"); try run("DELETE FROM poll_runs")
                try run("UPDATE devices SET last_ingestion_ms=NULL")
            }
            try Self.execute(handle,"COMMIT")
        } catch { try? Self.execute(handle,"ROLLBACK"); throw error }
    }
    public func retain(sinceMS: Int64) throws {
        try run("DELETE FROM location_pings WHERE COALESCE(provider_timestamp_ms,ingested_at_ms)<?", [.integer(sinceMS)])
    }
    public func setSetting(key: String, value: String) throws {
        try run("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key),.text(value)])
    }
    public func setting(key: String) throws -> String? {
        var result: String?
        try run("SELECT value FROM settings WHERE key=?", [.text(key)]) { result = self.string($0,0) }
        return result
    }
    public func saveGeocode(key: String, locale: String, shortLabel: String?, fullAddress: String?, status: String, attempts: Int, nextRetryMS: Int64?, resolvedMS: Int64?) throws {
        try run("""
        INSERT INTO geocode_cache VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(key,locale) DO UPDATE SET
        short_label=excluded.short_label,full_address=excluded.full_address,status=excluded.status,
        attempts=excluded.attempts,next_retry_ms=excluded.next_retry_ms,resolved_ms=excluded.resolved_ms
        """,[.text(key),.text(locale),.optional(shortLabel),.optional(fullAddress),.text(status),.integer(Int64(attempts)),.optional(nextRetryMS),.optional(resolvedMS)])
    }
    public func geocode(key: String, locale: String) throws -> GeocodeEntry? {
        var result: GeocodeEntry?
        try run("SELECT key,locale,short_label,full_address,status,attempts,next_retry_ms,resolved_ms FROM geocode_cache WHERE key=? AND locale=?",
                [.text(key),.text(locale)]) { s in
            result = GeocodeEntry(key:self.string(s,0),locale:self.string(s,1),shortLabel:self.optionalString(s,2),
                fullAddress:self.optionalString(s,3),status:self.string(s,4),attempts:Int(sqlite3_column_int(s,5)),
                nextRetryMS:self.integer(s,6),resolvedMS:self.integer(s,7))
        }
        return result
    }
    public func saveSemanticPlace(id: String, profileID: String, deviceID: String?, label: String, latitude: Double, longitude: Double) throws {
        guard latitude.isFinite,longitude.isFinite,(-90...90).contains(latitude),(-180...180).contains(longitude),!label.isEmpty else { throw DataError.invalidObservation }
        try run("INSERT INTO semantic_places VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET label=excluded.label,latitude=excluded.latitude,longitude=excluded.longitude",
                [.text(id),.text(profileID),.optional(deviceID),.text(label),.real(latitude),.real(longitude)])
    }
    public func semanticPlaces(profileID: String, deviceID: String) throws -> [SemanticPlace] {
        var result: [SemanticPlace] = []
        try run("SELECT id,profile_id,device_id,label,latitude,longitude FROM semantic_places WHERE profile_id=? AND (device_id IS NULL OR device_id=?) ORDER BY device_id IS NOT NULL DESC,id",
                [.text(profileID),.text(deviceID)]) { s in
            result.append(SemanticPlace(id:self.string(s,0),profileID:self.string(s,1),deviceID:self.optionalString(s,2),
                label:self.string(s,3),latitude:sqlite3_column_double(s,4),longitude:sqlite3_column_double(s,5)))
        }
        return result
    }
    public func deleteSemanticPlace(id: String) throws {
        try run("DELETE FROM semantic_places WHERE id=?", [.text(id)])
    }
    public func latestObservations(deviceID: String, sinceMS: Int64? = nil, limit: Int = 1000) throws -> [Sighting] {
        guard limit > 0,limit <= 100_000 else { throw DataError.database("invalid-pagination") }
        var rows: [Sighting] = []
        try run("""
        SELECT payload FROM location_pings WHERE device_id=? AND COALESCE(provider_timestamp_ms,ingested_at_ms)>=?
        ORDER BY COALESCE(provider_timestamp_ms,ingested_at_ms) DESC,id DESC LIMIT ?
        """,[.text(deviceID),.integer(sinceMS ?? 0),.integer(Int64(limit))]) { s in
            rows.append(try JSONDecoder().decode(Sighting.self,from:Data(self.string(s,0).utf8)))
        }
        return rows.reversed()
    }
}
