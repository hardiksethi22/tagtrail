import Foundation
import TagTrailCore
import CSQLite

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func check(_ condition: Bool, _ label: String) throws {
    if !condition { throw CheckFailure(description:label) }
}
func rejects(_ operation: () throws -> Void, _ label: String) throws {
    do { try operation() } catch { return }
    throw CheckFailure(description:label)
}
func observation(_ id: String, time: Int64? = 1_700_000_000_000,
                 lat: Double = 0, accuracy: Double? = nil) -> Sighting {
    Sighting(id:id,deviceID:"d",kind:.geographic,latitude:lat,longitude:0,accuracy:accuracy,
             providerTimestampMS:time,timestampProvenance:time == nil ? "unavailable":"provider-report",
             ingestedAtMS:1_700_000_100_000,source:"fixture")
}
func migrationSQL(_ url: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path,&handle) == SQLITE_OK else { throw CheckFailure(description:"migration fixture open") }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle,sql,nil,nil,nil) == SQLITE_OK else { throw CheckFailure(description:"migration fixture SQL") }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TagTrail-corechecks-\(UUID())")
do {
    let url = directory.appendingPathComponent("history.sqlite")
    let db = try Database(url:url)
    let permissions = try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber
    try check(permissions?.intValue == 0o600,"restrictive database permissions")
    try migrationSQL(url,"DROP TABLE settings; PRAGMA user_version=1;")
    let migrated = try Database(url:url)
    try await migrated.setSetting(key:"migration",value:"v2")
    let migrationValue = try await migrated.setting(key:"migration")
    try check(migrationValue == "v2","v1-to-v2 migration")
    let badURL = directory.appendingPathComponent("newer.sqlite")
    try migrationSQL(badURL,"PRAGMA user_version=99;")
    try rejects({ _ = try Database(url:badURL) },"newer schema rejected")
    try await db.upsertProfile(id:"p",provider:"demo",label:"Demo")
    try await db.upsertDevice(TrackerDevice(id:"d",profileID:"p",canonicID:"upstream",name:"Synthetic",network:"demo"))
    try observation("zero").validate()
    try observation("missing-time",time:nil).validate()
    let semantic = Sighting(id:"semantic",deviceID:"d",kind:.semantic,providerTimestampMS:1_700_000_001_000,
                            ingestedAtMS:1_700_000_100_000,semanticLabel:"Home",source:"fixture")
    try semantic.validate()
    try rejects({ try observation("range",lat:91).validate() },"invalid latitude")
    try rejects({ try observation("nan",lat:.nan).validate() },"nonfinite latitude")
    try rejects({ try observation("accuracy",accuracy:-1).validate() },"negative accuracy")
    try rejects({ try observation("infinite",accuracy:.infinity).validate() },"nonfinite accuracy")
    var badAltitude = observation("altitude"); badAltitude.altitude = .nan
    try rejects({ try badAltitude.validate() },"nonfinite altitude")
    var badLongitude = observation("longitude"); badLongitude.longitude = 181
    try rejects({ try badLongitude.validate() },"invalid longitude")
    var badTime = observation("time"); badTime.providerTimestampMS = -1
    try rejects({ try badTime.validate() },"negative provider timestamp")
    var incomplete = observation("incomplete"); incomplete.longitude = nil
    try rejects({ try incomplete.validate() },"incomplete pair")
    let a = observation("a")
    var duplicate = a; duplicate.id = "duplicate"; duplicate.ingestedAtMS += 100
    try check(try a.fingerprint() == duplicate.fingerprint(),"stable fingerprint")
    let inserted = try await db.ingest([a,duplicate,observation("same-time",lat:1),observation("older",time:100),semantic])
    try check(inserted == 4,"idempotence and same-time distinction")
    let reopened = try Database(url:url)
    let rows = try await reopened.observations(deviceID:"d")
    try check(rows.count == 4 && rows.first?.id == "older","persistence and out-of-order")
    let page = try await reopened.observations(deviceID:"d",limit:1,offset:1)
    try check(page.first?.id == "a","indexed pagination")
    var reportA = observation("identity-a",lat:2); reportA.reportID = "stable-a"
    var reportB = reportA; reportB.id = "identity-b"; reportB.reportID = "stable-b"
    var reportRepeat = reportA; reportRepeat.id = "repeat"; reportRepeat.latitude = 3
    let reportCount = try await db.ingest([reportA,reportB,reportRepeat])
    try check(reportCount == 2,"stable provider identity preferred")
    var foreign = observation("foreign"); foreign.deviceID = "missing"
    var rolledBack = false
    do { _ = try await db.ingest([observation("rollback",lat:4),foreign]) }
    catch { rolledBack = true }
    let after = try await db.observations(deviceID:"d")
    try check(rolledBack && !after.contains(where:{$0.id == "rollback"}),"foreign key transactional rollback")
    let display = [observation("g1",time:1000,accuracy:20),observation("g2",time:2000,lat:0.00001,accuracy:20),
                   observation("g3",time:3_700_001,lat:0.00002,accuracy:20)]
    let groups = Simplifier.groups(display,simplified:true)
    try check(groups.count == 2 && groups[0].count == 2 && groups[0].representative.id == "g2" && groups.last?.representative.id == "g3","group newest preservation")
    try check(Simplifier.groups(display,simplified:false).count == 3,"raw display")
    try check(Simplifier.segments(display).count == 2,"long-gap segmentation")
    var between = semantic; between.providerTimestampMS = 1500
    try check(Simplifier.segments([display[0],between,display[1]]).count == 2,"semantic route break")
    try check(Simplifier.groups([observation("u1",time:1),observation("u2",time:2)],simplified:true).count == 2,"unknown accuracy not grouped")
    try check(abs((Simplifier.distance(display[0],display[1]) ?? 0)-1.111949) < 0.001,"Haversine meters")
    let boundaryA = observation("boundary-a",time:0,accuracy:500)
    let boundaryB = observation("boundary-b",time:1_800_000,lat:0.0004,accuracy:500)
    try check(Simplifier.groups([boundaryA,boundaryB],simplified:true).count == 1,"30-minute inclusive boundary")
    var beyondGap = boundaryB; beyondGap.providerTimestampMS = 1_800_001
    try check(Simplifier.groups([boundaryA,beyondGap],simplified:true).count == 2,"over-30-minute not grouped")
    var beyondDistance = boundaryB; beyondDistance.latitude = 0.0005
    try check(Simplifier.groups([boundaryA,beyondDistance],simplified:true).count == 2,"accuracy threshold capped at 50m")
    let routeBoundary = observation("route-boundary",time:3_600_000)
    try check(Simplifier.segments([boundaryA,routeBoundary]).count == 1,"60-minute inclusive connector")
    var export = observation("csv",lat:-12.5); export.semanticLabel = "=SUM(A1)\n\"हैलो\","
    let csv = CSVExporter.string(deviceName:"@unsafe",observations:[export])
    try check(csv.contains("\"'@unsafe\"") && csv.contains("\"'=SUM(A1)\n\"\"हैलो\"\","),"CSV escaping Unicode and formulas")
    try check(csv.contains(",-12.5,0.0,,,") && !csv.contains("'-12.5"),"numeric coordinates preserved")
    try await db.setSetting(key:"not-before",value:"500")
    let setting = try await reopened.setting(key:"not-before")
    try check(setting == "500","persisted cooldown")
    try await db.saveGeocode(key:"0,0",locale:"en",shortLabel:nil,fullAddress:nil,status:"no-result",attempts:1,nextRetryMS:500,resolvedMS:nil)
    let cache = try await reopened.geocode(key:"0,0",locale:"en")
    try check(cache?.status == "no-result" && cache?.attempts == 1,"geocode no-result cache")
    try await db.saveSemanticPlace(id:"home",profileID:"p",deviceID:"d",label:"Home",latitude:1,longitude:2)
    let places = try await db.semanticPlaces(profileID:"p",deviceID:"d")
    try check(places.count == 1 && places[0].latitude == 1,"explicit semantic mappings")
    try await db.recordPoll(deviceID:"d",attemptMS:40,completedMS:50,classification:"no-new-data",insertedCount:0,errorCode:nil)
    let devices = try await reopened.devices(profileID:"p")
    try check(devices[0].lastSuccessMS == 50,"successful poll separate from report time")
    var diagnosticRejected = false
    do {
        try await db.recordPoll(deviceID:"d",attemptMS:60,completedMS:70,classification:"planted-private-value",
                                insertedCount:0,errorCode:"internal-error")
    } catch { diagnosticRejected = true }
    try check(diagnosticRejected,"nonallowlisted poll diagnostic rejected")
    try await db.retain(sinceMS:1_700_000_000_000)
    let retained = try await reopened.observations(deviceID:"d")
    try check(!retained.contains(where:{$0.id == "older"}),"retention cutoff")
    try await db.deleteHistory(deviceID:"d")
    let empty = try await reopened.observations(deviceID:"d")
    try check(empty.isEmpty,"scoped deletion")
    let synthetic = (0..<10_000).map { observation("row-\($0)",time:1_700_000_000_000+Int64($0)*1000,lat:Double($0)/1000) }
    let ingestStart = ContinuousClock.now
    let count = try await db.ingest(synthetic)
    let ingestDuration = ingestStart.duration(to:.now)
    let queryStart = ContinuousClock.now
    let indexed = try await db.observations(deviceID:"d",sinceMS:1_700_009_000_000,limit:100)
    let queryDuration = queryStart.duration(to:.now)
    try check(count == 10_000 && indexed.count == 100 && queryDuration < .seconds(2),"10000 indexed retrieval threshold")
    let latest = try await db.latestObservations(deviceID:"d",limit:1)
    try check(latest.first?.id == "row-9999","latest page never selects oldest")
    print("PASS core database/validity/identity/display/CSV/settings/geocode/mapping/retention")
    print("PERFORMANCE 10000 ingestion=\(ingestDuration) indexed100=\(queryDuration)")
    try FileManager.default.removeItem(at:directory)
} catch {
    fputs("FAIL core checks: \(error)\n",stderr)
    if FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.removeItem(at:directory) }
    exit(1)
}
