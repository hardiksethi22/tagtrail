import XCTest
@testable import TagTrailCore

final class CoreTests: XCTestCase {
    func observation(_ id: String = UUID().uuidString, time: Int64? = 1_700_000_000_000,
                     lat: Double = 0, accuracy: Double? = nil) -> Sighting {
        Sighting(id:id,deviceID:"d",kind:.geographic,latitude:lat,longitude:0,accuracy:accuracy,
                 providerTimestampMS:time,timestampProvenance:time == nil ? "unavailable":"provider-report",
                 ingestedAtMS:1_700_000_100_000,source:"fixture")
    }
    func database() async throws -> (Database,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TagTrail-tests-\(UUID())/history.sqlite")
        let db = try Database(url:url)
        try await db.upsertProfile(id:"p",provider:"demo",label:"Demo")
        try await db.upsertDevice(TrackerDevice(id:"d",profileID:"p",canonicID:"upstream",name:"Synthetic",network:"demo",trackingEnabled:true))
        return (db,url)
    }
    func testValidity() throws {
        try observation().validate()
        try observation(time:nil).validate()
        try Sighting(deviceID:"d",kind:.semantic,ingestedAtMS:1,semanticLabel:"Home",source:"fixture").validate()
        XCTAssertThrowsError(try observation(lat:91).validate())
        XCTAssertThrowsError(try observation(lat:.nan).validate())
        XCTAssertThrowsError(try observation(accuracy: -1).validate())
        var incomplete = observation(); incomplete.longitude = nil
        XCTAssertThrowsError(try incomplete.validate())
        XCTAssertNil(observation().accuracy)
    }
    func testFingerprint() throws {
        let first = observation()
        var second = first; second.id = "new"; second.ingestedAtMS += 100
        XCTAssertEqual(try first.fingerprint(),try second.fingerprint())
        second.latitude = 0.1
        XCTAssertNotEqual(try first.fingerprint(),try second.fingerprint())
        second = first; second.latitude = -0.0
        XCTAssertEqual(try first.fingerprint(),try second.fingerprint())
    }
    func testPersistenceDedupAndOrdering() async throws {
        let (db,url) = try await database()
        let first = observation("a")
        var duplicate = first; duplicate.id = "duplicate"; duplicate.ingestedAtMS += 999
        let sameTime = observation("b",lat:1)
        let old = observation("old",time:1_600_000_000_000)
        let inserted = try await db.ingest([first,duplicate,sameTime,old])
        XCTAssertEqual(inserted,3)
        let reopened = try Database(url:url)
        let rows = try await reopened.observations(deviceID:"d")
        XCTAssertEqual(rows.map(\.id),["old","a","b"])
        let again = try await reopened.ingest([duplicate])
        XCTAssertEqual(again,0)
        let page = try await reopened.observations(deviceID:"d",limit:1,offset:1)
        XCTAssertEqual(page.map(\.id),["a"])
    }
    func testRollbackForeignKeysAndStableReportID() async throws {
        let (db,_) = try await database()
        var valid = observation("a"); valid.reportID = "verified-report"
        var changed = valid; changed.id = "b"; changed.latitude = 10
        let inserted = try await db.ingest([valid,changed])
        XCTAssertEqual(inserted,1)
        var invalid = observation("foreign"); invalid.deviceID = "missing-device"
        do { _ = try await db.ingest([observation("rolledback",lat:2),invalid]); XCTFail("Foreign key must fail") }
        catch {}
        let rows = try await db.observations(deviceID:"d")
        XCTAssertEqual(rows.count,1)
        var independent = valid; independent.id = "distinct"; independent.reportID = "different-report"
        let independentCount = try await db.ingest([independent])
        XCTAssertEqual(independentCount,1)
    }
    func testSimplificationAndSegments() throws {
        let a = observation("a",time:1_000,accuracy:20)
        let b = observation("b",time:2_000,lat:0.00001,accuracy:20)
        let c = observation("c",time:3_700_001,lat:0.00002,accuracy:20)
        let raw = [a,b,c]
        let groups = Simplifier.groups(raw,simplified:true)
        XCTAssertEqual(groups.count,2)
        XCTAssertEqual(groups[0].representative.id,"b")
        XCTAssertEqual(groups[0].count,2)
        XCTAssertEqual(groups.last?.representative.id,"c")
        XCTAssertEqual(Simplifier.groups(raw,simplified:false).count,3)
        XCTAssertEqual(Simplifier.segments(raw).count,2)
        let semantic = Sighting(id:"s",deviceID:"d",kind:.semantic,providerTimestampMS:1_500,
                                ingestedAtMS:1_500,semanticLabel:"Home",source:"fixture")
        XCTAssertEqual(Simplifier.segments([a,semantic,b]).count,2)
        XCTAssertEqual(Simplifier.groups([a,semantic,b],simplified:true).count,3)
        XCTAssertEqual(Simplifier.groups([observation("x",time:1),observation("y",time:2)],simplified:true).count,2)
        XCTAssertEqual(try XCTUnwrap(Simplifier.distance(a,b)),1.111949,accuracy:0.001)
    }
    func testCSV() {
        var row = observation(lat:-12.5)
        row.semanticLabel = "=SUM(A1)\n\"हैलो\","
        let csv = CSVExporter.string(deviceName:"@unsafe",observations:[row])
        XCTAssertTrue(csv.contains("\"'@unsafe\""))
        XCTAssertTrue(csv.contains("\"'=SUM(A1)\n\"\"हैलो\"\","))
        XCTAssertTrue(csv.contains(",-12.5,0.0,,,")); XCTAssertTrue(csv.contains("Z,"))
        XCTAssertFalse(csv.contains("'-12.5"))
        row.providerTimestampMS = nil
        XCTAssertTrue(CSVExporter.string(deviceName:"safe",observations:[row]).contains("\"fixture\",,"))
    }
    func testRetentionSettingsGeocodeAndPoll() async throws {
        let (db,_) = try await database()
        _ = try await db.ingest([observation("old",time:10),observation("new",time:30)])
        try await db.retain(sinceMS:20)
        let retained = try await db.observations(deviceID:"d")
        XCTAssertEqual(retained.map(\.id),["new"])
        try await db.setSetting(key:"not-before",value:"500")
        let stored = try await db.setting(key:"not-before"); XCTAssertEqual(stored,"500")
        try await db.saveGeocode(key:"0,0",locale:"en",shortLabel:nil,fullAddress:nil,status:"no-result",attempts:1,nextRetryMS:500,resolvedMS:nil)
        let cache = try await db.geocode(key:"0,0",locale:"en"); XCTAssertEqual(cache?.status,"no-result")
        try await db.recordPoll(deviceID:"d",attemptMS:40,completedMS:50,classification:"no-new-data",insertedCount:0,errorCode:nil)
        let devices = try await db.devices(profileID:"p")
        XCTAssertEqual(devices.first?.lastSuccessMS,50)
        try await db.deleteHistory(deviceID:"d")
        let empty = try await db.observations(deviceID:"d"); XCTAssertTrue(empty.isEmpty)
        let profiles = try await db.devices(profileID:"p"); XCTAssertEqual(profiles.count,1)
    }
    func testTenThousandIndexedRetrieval() async throws {
        let (db,_) = try await database()
        let rows = (0..<10_000).map { observation("row-\($0)",time:1_700_000_000_000+Int64($0)*1000,lat:Double($0)/1000) }
        let start = ContinuousClock.now
        let count = try await db.ingest(rows)
        let ingestDuration = start.duration(to:.now)
        let queryStart = ContinuousClock.now
        let page = try await db.observations(deviceID:"d",sinceMS:1_700_009_000_000,limit:100)
        let queryDuration = queryStart.duration(to:.now)
        XCTAssertEqual(count,10_000); XCTAssertEqual(page.count,100)
        XCTAssertLessThan(queryDuration,.seconds(2))
        print("PERFORMANCE 10000 ingestion=\(ingestDuration) indexed100=\(queryDuration)")
    }
}
