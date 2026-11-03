#if !canImport(XCTest)
import Foundation
import Darwin

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

private enum Assertions {
    static let lock = NSLock()
    static var failures = 0

    static func fail(_ message: String, file: StaticString, line: UInt) {
        lock.lock()
        failures += 1
        lock.unlock()
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
    }
}

func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    Assertions.fail(message, file: file, line: line)
}

func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { XCTFail("Expected true.", file: file, line: line) }
}

func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value { XCTFail("Expected false.", file: file, line: line) }
}

func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    if lhs != rhs { XCTFail("Values differ.", file: file, line: line) }
}

func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { XCTFail("Expected nil.", file: file, line: line) }
}

func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        XCTFail("Expected a value.", file: file, line: line)
        throw PortableTestError.missingValue
    }
    return value
}

func XCTAssertThrowsError<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try operation()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {}
}

func XCTAssertNoThrow<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try operation() }
    catch { XCTFail("Unexpected error.", file: file, line: line) }
}

private enum PortableTestError: Error { case missingValue }
#endif

#if !canImport(XCTest) && !SWIFT_PACKAGE
@main
enum AppServiceChecks {
    static func main() async {
        let tests: [(String, (ServiceTests) async throws -> Void)] = [
            ("demo-clock-and-isolation", { try await $0.testDemoIsClockAnchoredAndSeparateFromLive() }),
            ("persistent-manual-cooldown", { try await $0.testCooldownIncludesManualPollsAndSurvivesCoordinatorRestart() }),
            ("credentials-locked-pause", { try await $0.testCredentialLockPausesAccountUntilExplicitRepair() }),
            ("unsupported-device-scope", { try await $0.testUnsupportedDeviceDoesNotPauseOtherDevices() }),
            ("geocode-labels-and-cache", { try await $0.testGeocoderUsesLabelsWithoutNetworkAndCachesByCoordinateAndLocale() }),
            ("geocode-negative-cache", { try await $0.testNoGeocodeResultIsNegativelyCached() }),
            ("credential-validation", { try $0.testImportRejectsPartialOversizeAndMalformedCredentials() }),
            ("worker-request-contract", { try $0.testWorkerRequestKeepsCredentialsInNDJSONAndUsesContractKeys() }),
            ("worker-unicode-and-credential-envelopes", { try $0.testWorkerParserAcceptsUnicodeAndBothCredentialEnvelopeShapes() }),
            ("worker-malformed-stream-rejection", { try $0.testWorkerParserRejectsBadVersionIdentityEOFAndPostTerminalEvents() }),
            ("worker-error-classification", { try $0.testWorkerParserPreservesMachineReadableFailureClassification() }),
            ("latest-display-and-paginated-export", { try await $0.testLatestDisplayAndExportPaginationPreserveNewestAndAllRawRows() }),
            ("semantic-mapping-preserves-evidence", { try await $0.testSemanticMappingUsesCorePersistenceWithoutChangingRawEvidence() }),
            ("actual-worker-pipes-and-cancellation", { try await $0.testActualWorkerPipesBoundEOFNonzeroOverflowTimeoutAndCancellation() }),
            ("shared-worker-protocol-fixture", { try $0.testSharedWorkerProtocolFixture() })
        ]
        for (name, operation) in tests {
            let test = ServiceTests()
            do {
                try test.setUpWithError()
                do { try await operation(test) }
                catch {
                    XCTFail("\(name): unexpected \(type(of: error)).")
                }
                try test.tearDownWithError()
            } catch {
                XCTFail("\(name): setup or cleanup failed.")
            }
        }
        guard Assertions.failures == 0 else {
            fputs("FAIL TagTrail AppServiceChecks: \(Assertions.failures) assertions.\n", stderr)
            exit(1)
        }
        print("PASS TagTrail AppServiceChecks: \(tests.count) service tests")
    }
}
#endif
