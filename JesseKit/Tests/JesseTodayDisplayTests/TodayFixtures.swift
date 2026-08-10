import Foundation
import JesseNetworking

// Snapshots the semantics and the model are driven with.
//
// Built from the wire types' public inits rather than from JSON, because these tests
// are about the REDUCER, not about decoding — that is `TodayWireDecodeTests`'s job,
// and it runs against the bridge's own serialized output.
//
// The ids, leads and Added dates below are the REAL ones the bridge produces for
// `bridge/tests/fixtures/today/full.md`, including the pair that matters most:
// "Collect the glaze order" hashes to `8dd0678d544b` while it sits in Errands and to
// `66db276d8cbc` once a `to_do_now` move lands it in Do Now. Nothing here invents an
// id, so a test that passes here is testing the identity contract the bridge really
// has rather than one that would be convenient.

enum Fixt {
    // Do Now
    static let thermocouple = "6d1e3c9a0001"
    static let ada = "6d1e3c9a0002"
    static let plain = "6d1e3c9a0003"
    // Errands
    static let clamps = "6d1e3c9a0004"
    /// "Collect the glaze order" while it lives in **Errands**.
    static let glazeInErrands = "8dd0678d544b"
    /// The same item's id once `to_do_now` has moved it into **Do Now**. Produced by
    /// the bridge, not chosen here.
    static let glazeInDoNow = "66db276d8cbc"
    // The standing lead item, above every heading.
    static let standing = "8997e65be5bd"
    // A briefing glanceable.
    static let runDay = "6d1e3c9a0007"
    static let currency = "6d1e3c9a0008"

    static let glazeLead = "Collect the glaze order."
    static let glazeAdded = "2026-03-02"

    static func item(_ id: String, lead: String, section: String, checked: Bool = false,
                     added: String? = nil, updated: String? = nil,
                     text: String? = nil, links: [TodayLink] = [],
                     appCompleted: TodayAppCompleted? = nil) -> TodayItem {
        TodayItem(id: id, checked: checked, lead: lead,
                  text: text ?? "* [\(checked ? "x" : " ")] **\(lead)**",
                  links: links, addedDate: added, updatedDate: updated,
                  appCompleted: appCompleted, sectionName: section)
    }

    static func report(_ id: String, title: String, section: String, kind: String,
                       seen: Bool = false) -> TodayReport {
        TodayReport(id: id, title: title, links: [TodayLink(target: "notes/x", kind: "wiki")],
                    kind: kind, sectionName: section, seen: seen, seenMs: seen ? 1 : 0)
    }

    /// The whole day, shaped like the real fixture: a standing lead item, a Do Now
    /// section, an Errands section, and one briefing section with two glanceables.
    static func snapshot(etag: String = "\"tag-1\"", pending: Bool? = nil) -> TodaySnapshot {
        TodaySnapshot(
            title: "Today: Tuesday, March 3, 2026",
            date: "2026-03-03",
            narrative: "Tuesday, and it is a short day.",
            leadItems: [item(standing, lead: "TOP PRIORITY: Finish the kiln rebuild",
                             section: "", added: "2026-01-04")],
            sections: [
                TodaySection(name: "Do Now", kind: "tasks", items: [
                    item(thermocouple, lead: "Order the replacement thermocouple.",
                         section: "Do Now", added: "2026-03-01", updated: "2026-03-03"),
                    item(ada, lead: "Reply to Ada about the firing schedule.",
                         section: "Do Now", added: "2026-02-27"),
                    item(plain, lead: "Plain unbolded item.", section: "Do Now"),
                ]),
                TodaySection(name: "Errands", kind: "tasks", items: [
                    item(glazeInErrands, lead: glazeLead, section: "Errands",
                         added: glazeAdded),
                    item(clamps, lead: "Return the borrowed clamps.", section: "Errands",
                         checked: true, added: glazeAdded),
                ]),
                TodaySection(name: "Health", kind: "briefing", reports: [
                    report(runDay, title: "Tuesday is a run day.", section: "Health",
                           kind: "health"),
                    report(currency, title: "USD/EUR has not posted.", section: "Health",
                           kind: "currency"),
                ]),
            ],
            counts: TodayCounts(open: 5, done: 1, reportsUnseen: 2),
            etag: etag,
            pending: pending)
    }

    /// The same day AFTER the bridge applied `to_do_now` to the glaze item: it now
    /// sits at the top of Do Now, under a **different id**, and is gone from Errands.
    /// This is exactly what a move response looks like.
    static func snapshotAfterGlazeMovedToDoNow(etag: String = "\"tag-2\"") -> TodaySnapshot {
        var snap = snapshot(etag: etag, pending: false)
        snap.sections[1].items.removeAll { $0.id == glazeInErrands }
        snap.sections[0].items.insert(
            item(glazeInDoNow, lead: glazeLead, section: "Do Now", added: glazeAdded),
            at: 0)
        return snap
    }
}
