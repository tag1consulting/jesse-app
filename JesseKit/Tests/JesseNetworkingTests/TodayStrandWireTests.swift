import XCTest
@testable import JesseNetworking

// The strand an item belongs to, decoded.
//
// `today-strands.json` is the BRIDGE'S OWN OUTPUT over `bridge/tests/fixtures/today/
// strands/vault/Today.md`, stamped by the bridge's `StrandTable` over the invented notes
// beside it: the fixture the bridge's own derivation tests run against. The content is
// invented throughout.

final class TodayStrandWireTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: "json"),
                                "fixture \(name).json is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func item(_ snap: TodaySnapshot, _ leadPrefix: String) throws -> TodayItem {
        try XCTUnwrap(snap.allItems.first { $0.lead.hasPrefix(leadPrefix) },
                      "item \(leadPrefix) missing")
    }

    /// A derived strand decodes to its slug and title.
    func testAStrandDecodesToItsSlugAndTitle() throws {
        let snap = try TodaySnapshot.decode(from: fixture("today-strands"))
        XCTAssertEqual(try item(snap, "A direct strand link wins").strand,
                       TodayItemStrand(slug: "Other-Strand", title: "Other Strand"))
        XCTAssertEqual(try item(snap, "A note three generations link").strand?.slug,
                       "Grandchild-Strand")
    }

    /// The bridge's explicit `null` is `nil`, not a decode failure.
    func testANullStrandDecodesToNil() throws {
        let snap = try TodaySnapshot.decode(from: fixture("today-strands"))
        XCTAssertNil(try item(snap, "A note two unrelated strands link").strand)
    }

    /// A bridge before 0.152.0 sends no `strand` key at all, and every item still decodes,
    /// with no strand. `today-projects.json` predates the field, which is exactly the case.
    func testAnAbsentStrandKeyDecodesToNil() throws {
        let data = try fixture("today-projects")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"strand\""),
                       "the fixture must predate the field for this test to mean anything")
        let snap = try TodaySnapshot.decode(from: data)
        XCTAssertFalse(snap.allItems.isEmpty)
        XCTAssertTrue(snap.allItems.allSatisfy { $0.strand == nil })
    }
}
