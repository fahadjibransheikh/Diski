import XCTest
@testable import Diski

final class UpdaterTests: XCTestCase {
    func testVersionComparison() throws {
        XCTAssertGreaterThan(try Updater.compareVersions("0.1.10", "0.1.9"), 0)
        XCTAssertLessThan(try Updater.compareVersions("0.1.9", "0.1.10"), 0)
        XCTAssertEqual(try Updater.compareVersions("v0.1.4-alpha", "0.1.4"), 0)
        XCTAssertEqual(try Updater.compareVersions("0.1", "0.1.0"), 0)
    }

    func testInvalidVersionsThrow() {
        for bad in ["1.x", "", "-alpha", "1..2", "-1.0"] {
            XCTAssertThrowsError(try Updater.compareVersions(bad, "0.1.0"), bad)
        }
    }

    func testChecksumLineFromReleaseScript() throws {
        let sum = String(repeating: "ab12", count: 16)
        let body = "### Install\n3. From then on Diski updates itself.\n\nSHA-256: `\(sum)`\n\nThis is an alpha."
        XCTAssertEqual(try Updater.checksum(in: body), sum)
        XCTAssertEqual(try Updater.checksum(in: body.replacingOccurrences(of: sum, with: sum.uppercased())), sum)
        XCTAssertNil(try Updater.checksum(in: "SHA-256: `\(sum.dropLast())`"))
        XCTAssertNil(try Updater.checksum(in: "no checksum here"))
    }
}
