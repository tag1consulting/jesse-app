import XCTest
@testable import JesseNetworking

// The on-disk last-good cache: the thing that makes a COLD LAUNCH WITH NO NETWORK show
// the day instead of a spinner.
//
// Every test here drives a real directory under `temporaryDirectory` rather than a fake
// filesystem, because the whole point of this type is that bytes survive a process
// death, and an in-memory double proves nothing about that.

final class SnapshotCacheTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func cache(maxEntries: Int = SnapshotCache.defaultMaxEntries,
                       maxAge: TimeInterval = SnapshotCache.defaultMaxAge) -> SnapshotCache {
        SnapshotCache(directory: dir, maxEntries: maxEntries, maxAge: maxAge)
    }

    private let t0 = Date(timeIntervalSince1970: 1_772_530_200)

    // MARK: - Round trip

    /// The bytes come back EXACTLY as they went in. This is the invariant the whole
    /// design rests on: the cached document is decoded by the same decoder the live one
    /// is, so a cache hit and a `200` cannot disagree about what the day says.
    func testStoredBytesComeBackUnchanged() {
        let c = cache()
        // Deliberately awkward JSON: a float that would come back as an int through a
        // parse-and-re-serialize round trip, and a non-ASCII string.
        let body = Data(#"{"weight":83.0,"note":"café – ok","n":1}"#.utf8)
        XCTAssertTrue(c.store(body, key: "today", etag: "\"tag-1\"", fetchedAt: t0))

        let entry = c.load(key: "today", now: t0.addingTimeInterval(60))
        XCTAssertEqual(entry?.body, body)
        XCTAssertEqual(entry?.etag, "\"tag-1\"")
        XCTAssertEqual(entry?.fetchedAt.timeIntervalSince1970 ?? 0,
                       t0.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A second write for the same key replaces the first — the cache holds the LAST
    /// good answer, not a history.
    func testAWriteReplacesTheEntryForThatKey() {
        let c = cache()
        c.store(Data("first".utf8), key: "today", fetchedAt: t0)
        c.store(Data("second".utf8), key: "today", fetchedAt: t0.addingTimeInterval(10))

        XCTAssertEqual(c.load(key: "today", now: t0.addingTimeInterval(20))?.body,
                       Data("second".utf8))
        XCTAssertEqual(c.keys(), ["today"])
    }

    func testAMissingKeyLoadsNothing() {
        XCTAssertNil(cache().load(key: "today", now: t0))
    }

    /// A body without an ETag is legal (the diet endpoint has none) and reads back nil
    /// rather than an empty string a caller might send as `If-None-Match`.
    func testAnEntryWithNoETagReadsBackNil() {
        let c = cache()
        c.store(Data("{}".utf8), key: "diet-live", fetchedAt: t0)
        XCTAssertNil(c.load(key: "diet-live", now: t0)?.etag)
    }

    // MARK: - Keys are paths, so they are checked

    /// The keys are ours, not the bridge's — but this is the function that turns one
    /// into a path on the device, so it is checked here rather than trusted.
    func testTraversalAndOddKeysAreRefused() {
        for bad in ["../escape", "a/b", "Today", "today.json", "", String(repeating: "x", count: 65)] {
            XCTAssertFalse(SnapshotCache.isValidKey(bad), "\(bad) must not be a valid key")
            XCTAssertNil(cache().url(for: bad), "\(bad) must not resolve to a path")
            XCTAssertFalse(cache().store(Data("x".utf8), key: bad, fetchedAt: t0),
                           "\(bad) must not be writable")
        }
        for good in ["today", "diet-live", "diet-2026-08-21"] {
            XCTAssertTrue(SnapshotCache.isValidKey(good), "\(good) must be a valid key")
        }
    }

    /// A key that had to be repaired is a key two callers can derive differently, so a
    /// malformed date yields nothing rather than a sanitized guess.
    func testDietKeysAreDerivedOnlyFromRealISODays() {
        XCTAssertEqual(SnapshotCacheKey.diet(date: nil), SnapshotCacheKey.liveDiet)
        XCTAssertEqual(SnapshotCacheKey.diet(date: "2026-08-21"), "diet-2026-08-21")
        XCTAssertNil(SnapshotCacheKey.diet(date: "../etc/passwd"))
        XCTAssertNil(SnapshotCacheKey.diet(date: "2026-8-21"))
        XCTAssertNil(SnapshotCacheKey.diet(date: "yesterday"))
    }

    // MARK: - Eviction

    /// Past `maxAge` an entry is not "stale data to label", it is a different month.
    /// It reads as absent AND is deleted, so it cannot hold a slot against a live one.
    func testAnEntryPastItsMaxAgeIsNeitherServedNorKept() {
        let c = cache(maxAge: 3600)
        c.store(Data("{}".utf8), key: "today", fetchedAt: t0)

        XCTAssertNotNil(c.load(key: "today", now: t0.addingTimeInterval(3599)))
        XCTAssertNil(c.load(key: "today", now: t0.addingTimeInterval(3601)))
        XCTAssertEqual(c.keys(), [], "an unservable entry is deleted, not left holding a slot")
    }

    /// Over the count limit, the oldest writes go first and the newest survive.
    func testTheOldestEntriesAreEvictedOverTheCountLimit() throws {
        // Written through a cache with room for all four, so the eviction under test is
        // the explicit one below rather than the incidental one every `store` performs.
        let roomy = cache(maxEntries: 10)
        // Distinct modification dates, so the ordering is a fact about the files rather
        // than about the order the directory happens to enumerate in.
        for (i, key) in ["diet-2026-08-01", "diet-2026-08-02", "diet-2026-08-03",
                         "diet-2026-08-04"].enumerated() {
            XCTAssertTrue(roomy.store(Data("{}".utf8), key: key, fetchedAt: t0))
            try FileManager.default.setAttributes(
                [.modificationDate: t0.addingTimeInterval(Double(i) * 60)],
                ofItemAtPath: try XCTUnwrap(roomy.url(for: key)).path)
        }
        XCTAssertEqual(roomy.keys().count, 4)

        cache(maxEntries: 3).evictIfNeeded(now: t0.addingTimeInterval(600))

        XCTAssertEqual(roomy.keys(), ["diet-2026-08-02", "diet-2026-08-03", "diet-2026-08-04"])
    }

    /// The same limit applies on the WRITE path, which is where it actually runs in
    /// production — every successful fetch calls it.
    func testAWriteBringsTheCacheBackUnderTheCountLimit() {
        let c = cache(maxEntries: 2)
        for key in ["diet-2026-08-01", "diet-2026-08-02", "diet-2026-08-03"] {
            c.store(Data("{}".utf8), key: key, fetchedAt: t0)
        }
        XCTAssertEqual(c.keys().count, 2)
    }

    /// A body written by a future build is ignored rather than mis-decoded.
    func testAnUnknownEnvelopeVersionIsNotServed() throws {
        let c = cache()
        let url = try XCTUnwrap(c.url(for: "today"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":99,"fetchedAt":0,"etag":null,"body":"e30="}"#.utf8)
            .write(to: url)
        XCTAssertNil(c.load(key: "today", now: t0))
    }

    /// Garbage on disk (a truncated write, a half-full volume) reads as a miss, never as
    /// a crash and never as a document.
    func testAnUnreadableEntryIsAMiss() throws {
        let c = cache()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: try XCTUnwrap(c.url(for: "today")))
        XCTAssertNil(c.load(key: "today", now: t0))
    }

    /// Re-pairing points the app at a different bridge, describing a different vault.
    func testRemoveAllForgetsEverything() {
        let c = cache()
        c.store(Data("{}".utf8), key: "today", fetchedAt: t0)
        c.store(Data("{}".utf8), key: "diet-live", fetchedAt: t0)
        c.removeAll()
        XCTAssertEqual(c.keys(), [])
    }
}

// MARK: - The staleness phrase

final class OfflineStampTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_772_530_200)

    func testNothingKnownHasNoStamp() {
        XCTAssertNil(OfflineStamp.text(fetchedAt: nil, now: t0))
    }

    func testTheBucketsReadAsAPersonWouldSayThem() {
        func stamp(_ ago: TimeInterval) -> String? {
            OfflineStamp.text(fetchedAt: t0, now: t0.addingTimeInterval(ago))
        }
        XCTAssertEqual(stamp(0), "last updated just now")
        XCTAssertEqual(stamp(59), "last updated just now")
        XCTAssertEqual(stamp(60), "last updated 1 minute ago")
        XCTAssertEqual(stamp(60 * 12), "last updated 12 minutes ago")
        XCTAssertEqual(stamp(3600), "last updated 1 hour ago")
        XCTAssertEqual(stamp(3600 * 5), "last updated 5 hours ago")
        XCTAssertEqual(stamp(3600 * 24), "last updated yesterday")
        XCTAssertEqual(stamp(3600 * 24 * 3), "last updated 3 days ago")
        XCTAssertEqual(stamp(3600 * 24 * 30), "last updated more than a week ago")
    }

    /// A clock that moved backwards (a timezone change, a corrected system time) is not
    /// something to report to the user as a fact about their day.
    func testAFutureStampReadsAsJustNowRatherThanANegativeAge() {
        XCTAssertEqual(OfflineStamp.text(fetchedAt: t0.addingTimeInterval(600), now: t0),
                       "last updated just now")
    }

    func testTheBannerLineJoinsTheLeadAndTheAge() {
        XCTAssertEqual(
            OfflineStamp.cachedLine("Showing the last day loaded",
                                    fetchedAt: t0, now: t0.addingTimeInterval(120)),
            "Showing the last day loaded — last updated 2 minutes ago.")
        XCTAssertEqual(
            OfflineStamp.cachedLine("Showing the last day loaded", fetchedAt: nil, now: t0),
            "Showing the last day loaded")
    }
}
