import XCTest
import JesseConversations
import JesseCore

/// Regression guard for the "two same-name conversations collapse into one" report: the
/// shared `threadListLayout` must key rows on thread identity, never on title or derived
/// title, so two conversations that share a name (and even the same first message) render
/// as two distinct rows. The Mac and the iPhone both drive their lists from this function,
/// so pinning it here protects both. The Mac side re-checks the same property end to end
/// through adoption in `Jesse MacTests`.
@MainActor
final class SameTitleDistinctTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date { date(2026, 6, 25, 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func sameTitledThread(at updatedAt: Date) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = "Weekly sync"
        t.updatedAt = updatedAt
        t.turns = [Turn(role: .user, text: "Weekly sync", createdAt: updatedAt)]
        return t
    }

    private func rowCount(_ layout: ThreadListLayout) -> Int {
        switch layout {
        case .flat(let t): return t.count
        case .sectioned(let s): return s.reduce(0) { $0 + $1.threads.count }
        }
    }

    func testTwoSameTitledThreadsRenderAsTwoDistinctSectionedRows() {
        // Same day, same title, same first message; distinct object identity only.
        let a = sameTitledThread(at: date(2026, 6, 25, 9))
        let b = sameTitledThread(at: date(2026, 6, 25, 10))
        XCTAssertNotEqual(a.id, b.id)

        let layout = threadListLayout([a, b], favoritesOnly: false, searchQueries: [""],
                                      expanded: [], now: now, calendar: calendar)
        XCTAssertEqual(rowCount(layout), 2, "same-titled threads must not be de-duplicated")

        // And their identities survive distinctly (not merged onto one).
        var ids: Set<UUID> = []
        if case .sectioned(let sections) = layout {
            for s in sections { for t in s.threads { ids.insert(t.id) } }
        }
        XCTAssertEqual(ids, [a.id, b.id])
    }

    func testTwoSameTitledFavoritesRenderAsTwoFlatRows() {
        let a = sameTitledThread(at: date(2026, 6, 25, 9)); a.setFavorite(true, now: a.updatedAt)
        let b = sameTitledThread(at: date(2026, 6, 25, 10)); b.setFavorite(true, now: b.updatedAt)

        let layout = threadListLayout([a, b], favoritesOnly: true, searchQueries: [""],
                                      expanded: [], now: now, calendar: calendar)
        guard case .flat(let flat) = layout else { return XCTFail("favorites is a flat layout") }
        XCTAssertEqual(flat.count, 2)
        XCTAssertEqual(Set(flat.map(\.id)), [a.id, b.id])
    }
}
