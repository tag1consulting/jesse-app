import XCTest
import HealthKit
@testable import Jesse

/// The reliability + correction core of meal write-back (`JESSE_MEAL_LOG v2`), driven
/// entirely with fakes (no HealthKit, no SwiftData): the gate (toggle + write auth), the
/// upsert matrix (insert / skip / rewrite / retract / tombstone / revival / stale replay /
/// meal move), the transactional ack (advanced on full apply, withheld on failure, and
/// advanced-but-not-applied when the mirror is off), and the pending-queue drain. Proves
/// the guarantees the on-device path relies on without a device.
@MainActor
final class MealHealthWriterTests: XCTestCase {

    /// Records an ordered op log; each id can be forced to fail write and/or delete; auth
    /// is togglable. `delete` returns true (idempotent) unless the id is in `failDeletes`.
    private actor FakeMealWriter: MealWriting {
        enum Op: Equatable { case write(String), delete(String) }
        private(set) var ops: [Op] = []
        private var failWrites: Set<String> = []
        private var failDeletes: Set<String> = []
        private var authorized = true
        func setFailingWrites(_ ids: Set<String>) { failWrites = ids }
        func setFailingDeletes(_ ids: Set<String>) { failDeletes = ids }
        func setAuthorized(_ on: Bool) { authorized = on }
        func log() -> [Op] { ops }
        func writes() -> [String] { ops.compactMap { if case let .write(id) = $0 { return id } else { return nil } } }
        func deletes() -> [String] { ops.compactMap { if case let .delete(id) = $0 { return id } else { return nil } } }
        func write(_ meal: Meal) async -> Bool {
            if failWrites.contains(meal.id) { return false }
            ops.append(.write(meal.id)); return true
        }
        func delete(id: String) async -> Bool {
            if failDeletes.contains(id) { return false }
            ops.append(.delete(id)); return true
        }
        func isAuthorizedToWrite() async -> Bool { authorized }
    }

    private final class InMemoryWrittenStore: WrittenMealStoring {
        var records: [String: WrittenMealRecord] = [:]
        func record(for id: String) -> WrittenMealRecord? { records[id] }
        func recordWritten(id: String, contentHash: String) {
            records[id] = WrittenMealRecord(contentHash: contentHash, tombstoned: false)
        }
        func recordTombstoned(id: String) {
            let hash = records[id]?.contentHash ?? ""
            records[id] = WrittenMealRecord(contentHash: hash, tombstoned: true)
        }
    }

    private final class InMemoryPending: PendingMealStoring {
        private var batch = PendingMealBatch.empty
        func enqueue(_ b: PendingMealBatch) {
            for m in b.upserts where !batch.upserts.contains(where: { $0.id == m.id }) { batch.upserts.append(m) }
            for r in b.retracts where !batch.retracts.contains(r) { batch.retracts.append(r) }
        }
        func dequeueAll() -> PendingMealBatch { let out = batch; batch = .empty; return out }
        func peek() -> PendingMealBatch { batch }
    }

    /// Captures the acked seqs (in order) so tests can assert what was acked.
    private final class AckCapture { var seqs: [Int] = [] }

    private func meal(_ id: String, kcal: Double? = 100, sodiumMg: Double? = nil,
                      calciumMg: Double? = nil, at: TimeInterval = 1_780_000_000) -> Meal {
        Meal(id: id, consumedAt: Date(timeIntervalSince1970: at),
             name: "Meal \(id)", kcal: kcal, proteinGrams: nil, carbGrams: nil,
             fatGrams: nil, fiberGrams: nil, sodiumMg: sodiumMg,
             satFatGrams: nil, sugarGrams: nil, potassiumMg: nil,
             calciumMg: calciumMg, magnesiumMg: nil)
    }

    private func batch(_ upserts: [Meal] = [], retract: [String] = [], seq: Int? = nil) -> MealBatch {
        MealBatch(upserts: upserts, retracts: retract, correctionsSeq: seq)
    }

    private func makeWriter(_ w: FakeMealWriter, _ p: InMemoryPending, _ ack: AckCapture,
                            enabled: Bool = true) -> MealHealthWriter {
        MealHealthWriter(writer: w, pending: p, isEnabled: { enabled },
                         recordAck: { ack.seqs.append($0) })
    }

    // MARK: - Upsert matrix

    func testUnseenIdIsInsertedAndRecordedWithItsHash() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        let m = meal("a")
        await makeWriter(w, p, ack).apply(batch([m], seq: 5), written: store)
        let writes = await w.writes()
        XCTAssertEqual(writes, ["a"])
        XCTAssertEqual(store.record(for: "a")?.contentHash, m.contentHash)
        XCTAssertEqual(store.record(for: "a")?.tombstoned, false)
        XCTAssertTrue(p.peek().isEmpty)
        XCTAssertEqual(ack.seqs, [5], "a fully-applied batch advances the ack to its seq")
    }

    func testSameContentIsSkippedNoSecondWrite() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        let m = meal("a")
        store.records["a"] = WrittenMealRecord(contentHash: m.contentHash, tombstoned: false)
        await makeWriter(w, p, ack).apply(batch([m], seq: 2), written: store)
        let log = await w.log()
        XCTAssertTrue(log.isEmpty, "identical content is neither written nor deleted")
        XCTAssertEqual(ack.seqs, [2], "an all-skip batch is still acked")
    }

    func testChangedContentRewritesExactlyOnce() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        store.records["a"] = WrittenMealRecord(contentHash: "stale", tombstoned: false)
        let corrected = meal("a", kcal: 250)
        await makeWriter(w, p, ack).apply(batch([corrected], seq: 3), written: store)
        let log = await w.log()
        XCTAssertEqual(log, [.delete("a"), .write("a")],
                       "a changed meal is delete-then-rewritten, exactly one entry")
        XCTAssertEqual(store.record(for: "a")?.contentHash, corrected.contentHash)
        XCTAssertEqual(ack.seqs, [3])
    }

    func testMicronutrientOnlyCorrectionRewritesOnce() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        let before = meal("soup", kcal: 120, sodiumMg: nil)  // no sodium estimate yet
        store.records["soup"] = WrittenMealRecord(contentHash: before.contentHash, tombstoned: false)
        let after = meal("soup", kcal: 120, sodiumMg: 900)   // ONLY sodium added
        XCTAssertNotEqual(before.contentHash, after.contentHash,
                          "adding a first sodium estimate must change the hash (absent ≠ 0)")
        await makeWriter(w, p, ack).apply(batch([after], seq: 7), written: store)
        let log = await w.log()
        XCTAssertEqual(log, [.delete("soup"), .write("soup")],
                       "a micronutrient-only change rewrites exactly once")
        XCTAssertEqual(ack.seqs, [7])
    }

    func testCalciumOnlyCorrectionRewritesOnce() async {
        // Adding a first calcium estimate changes the content hash (absent ≠ 0), so the
        // meal is delete-then-rewritten exactly once — the same correction path the other
        // micronutrients flow through, now carrying calcium/magnesium in the hash.
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        let before = meal("soup", kcal: 120, calciumMg: nil)  // no calcium estimate yet
        store.records["soup"] = WrittenMealRecord(contentHash: before.contentHash, tombstoned: false)
        let after = meal("soup", kcal: 120, calciumMg: 250)   // ONLY calcium added
        XCTAssertNotEqual(before.contentHash, after.contentHash,
                          "adding a first calcium estimate must change the hash (absent ≠ 0)")
        await makeWriter(w, p, ack).apply(batch([after], seq: 14), written: store)
        let log = await w.log()
        XCTAssertEqual(log, [.delete("soup"), .write("soup")],
                       "a calcium-only change rewrites exactly once")
        XCTAssertEqual(ack.seqs, [14])
    }

    func testRetractDeletesAndTombstones() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        store.records["a"] = WrittenMealRecord(contentHash: meal("a").contentHash, tombstoned: false)
        await makeWriter(w, p, ack).apply(batch(retract: ["a"], seq: 4), written: store)
        let deletes = await w.deletes()
        XCTAssertEqual(deletes, ["a"])
        XCTAssertEqual(store.record(for: "a")?.tombstoned, true)
        XCTAssertEqual(ack.seqs, [4])
    }

    func testRetractOfUnknownIdIsANoopButTombstones() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        await makeWriter(w, p, ack).apply(batch(retract: ["ghost"], seq: 1), written: store)
        XCTAssertEqual(store.record(for: "ghost")?.tombstoned, true,
                       "an unknown retract tombstones so a later stale insert is ignored")
        XCTAssertEqual(ack.seqs, [1], "an unknown retract is not an error — still acked")
    }

    func testStaleReplayAfterTombstoneIsIgnored() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        let m = meal("a")
        store.records["a"] = WrittenMealRecord(contentHash: m.contentHash, tombstoned: true)
        await makeWriter(w, p, ack).apply(batch([m], seq: 9), written: store)
        let writes = await w.writes()
        XCTAssertTrue(writes.isEmpty, "a stale replay of a retracted meal is not re-written")
        XCTAssertEqual(store.record(for: "a")?.tombstoned, true, "it stays tombstoned")
        XCTAssertEqual(ack.seqs, [9])
    }

    func testTombstoneRevivalOnDifferentContent() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        store.records["a"] = WrittenMealRecord(contentHash: "old", tombstoned: true)
        let reLogged = meal("a", kcal: 333)  // different content
        await makeWriter(w, p, ack).apply(batch([reLogged], seq: 6), written: store)
        let writes = await w.writes()
        XCTAssertEqual(writes, ["a"], "a re-logged meal wins over a stale deletion")
        XCTAssertEqual(store.record(for: "a")?.tombstoned, false, "the tombstone is cleared")
        XCTAssertEqual(store.record(for: "a")?.contentHash, reLogged.contentHash)
    }

    func testMealMoveRetractOldPlusUpsertNewYieldsOneEntryAtTheNewTime() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        store.records["snack-1500"] = WrittenMealRecord(
            contentHash: meal("snack-1500").contentHash, tombstoned: false)
        let moved = meal("snack-1630", at: 1_780_005_000)  // new id (embeds new time)
        await makeWriter(w, p, ack).apply(
            batch([moved], retract: ["snack-1500"], seq: 8), written: store)
        // Upserts apply BEFORE retracts: write the new, then delete the old — one entry left.
        let log = await w.log()
        XCTAssertEqual(log, [.write("snack-1630"), .delete("snack-1500")])
        XCTAssertEqual(store.record(for: "snack-1500")?.tombstoned, true)
        XCTAssertEqual(store.record(for: "snack-1630")?.tombstoned, false)
        XCTAssertEqual(ack.seqs, [8])
    }

    // MARK: - Transactional ack + pending drain

    func testPartialFailureWithholdsAckAndEnqueuesRemainder() async {
        let w = FakeMealWriter(); await w.setFailingWrites(["b"])
        let p = InMemoryPending(); let ack = AckCapture(); let store = InMemoryWrittenStore()
        await makeWriter(w, p, ack).apply(batch([meal("a"), meal("b")], seq: 10), written: store)
        let writes = await w.writes()
        XCTAssertEqual(writes, ["a"], "the good meal still applies")
        XCTAssertEqual(p.peek().upserts.map(\.id), ["b"], "the failed meal is enqueued")
        XCTAssertTrue(ack.seqs.isEmpty, "the ack is WITHHELD on a partial failure → bridge redelivers")
    }

    func testFailedRetractWithholdsAckAndEnqueues() async {
        let w = FakeMealWriter(); await w.setFailingDeletes(["x"])
        let p = InMemoryPending(); let ack = AckCapture(); let store = InMemoryWrittenStore()
        store.records["x"] = WrittenMealRecord(contentHash: meal("x").contentHash, tombstoned: false)
        await makeWriter(w, p, ack).apply(batch(retract: ["x"], seq: 11), written: store)
        XCTAssertEqual(p.peek().retracts, ["x"], "a failed delete is queued for retry")
        XCTAssertTrue(ack.seqs.isEmpty)
        XCTAssertNotEqual(store.record(for: "x")?.tombstoned, true, "not tombstoned until the delete succeeds")
    }

    func testDrainRetriesPendingUpsertsAndRetracts() async {
        let w = FakeMealWriter(); await w.setFailingWrites(["b"])
        let p = InMemoryPending(); let ack = AckCapture(); let store = InMemoryWrittenStore()
        await makeWriter(w, p, ack).apply(batch([meal("a"), meal("b")], seq: 10), written: store)
        XCTAssertEqual(p.peek().upserts.map(\.id), ["b"])
        // The transient failure clears; a drain now succeeds and empties the queue.
        await w.setFailingWrites([])
        await makeWriter(w, p, ack).drainPending(written: store)
        let writes = await w.writes()
        XCTAssertEqual(writes, ["a", "b"])
        XCTAssertTrue(p.peek().isEmpty, "a successful drain clears the pending queue")
        XCTAssertEqual(ack.seqs, [], "the drain path advances no ack (redelivery owns seq)")
    }

    // MARK: - Gate (toggle + auth)

    func testMirrorOffAcksButDoesNotApply() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        await makeWriter(w, p, ack, enabled: false).apply(batch([meal("a")], seq: 12), written: store)
        let log = await w.log()
        XCTAssertTrue(log.isEmpty, "toggle off ⇒ nothing written or deleted")
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(p.peek().isEmpty, "toggle off ⇒ nothing queued")
        XCTAssertEqual(ack.seqs, [12], "toggle off still ACKS (Health is a mirror only while on)")
    }

    func testWriteDeniedAcksButDoesNotApply() async {
        let w = FakeMealWriter(); await w.setAuthorized(false)
        let p = InMemoryPending(); let ack = AckCapture(); let store = InMemoryWrittenStore()
        await makeWriter(w, p, ack).apply(batch([meal("a")], seq: 13), written: store)
        let log = await w.log()
        XCTAssertTrue(log.isEmpty, "write denied ⇒ nothing applied")
        XCTAssertEqual(ack.seqs, [13], "denied still acks so the bridge stops redelivering")
    }

    func testDrainWhileOffPutsPendingBack() async {
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        p.enqueue(PendingMealBatch(upserts: [meal("a")], retracts: ["b"]))
        await makeWriter(w, p, ack, enabled: false).drainPending(written: store)
        XCTAssertEqual(p.peek().upserts.map(\.id), ["a"], "draining while off must not lose queued work")
        XCTAssertEqual(p.peek().retracts, ["b"])
    }

    func testBatchWithNoSeqAppliesButAcksNothing() async {
        // A turn's own reply block carries no corrections_seq — apply it, ack nothing.
        let w = FakeMealWriter(); let p = InMemoryPending(); let ack = AckCapture()
        let store = InMemoryWrittenStore()
        await makeWriter(w, p, ack).apply(batch([meal("a")], seq: nil), written: store)
        let writes = await w.writes()
        XCTAssertEqual(writes, ["a"])
        XCTAssertTrue(ack.seqs.isEmpty, "a seq-less (turn-extracted) block acks nothing")
    }

    // MARK: - HealthKit sample building (micronutrients, unknown ≠ zero)

    /// A meal carrying an explicit set of macros/micronutrients (any may be nil).
    private func fullMeal(kcal: Double? = 100, sodiumMg: Double? = nil,
                          satFatGrams: Double? = nil, sugarGrams: Double? = nil,
                          potassiumMg: Double? = nil, calciumMg: Double? = nil,
                          magnesiumMg: Double? = nil) -> Meal {
        Meal(id: "m", consumedAt: Date(timeIntervalSince1970: 1_780_000_000),
             name: "M", kcal: kcal, proteinGrams: 20, carbGrams: 30, fatGrams: 10,
             fiberGrams: 5, sodiumMg: sodiumMg, satFatGrams: satFatGrams,
             sugarGrams: sugarGrams, potassiumMg: potassiumMg,
             calciumMg: calciumMg, magnesiumMg: magnesiumMg)
    }

    private func samples(of meal: Meal, _ id: HKQuantityTypeIdentifier) -> [HKQuantitySample] {
        HealthKitMealWriter.samples(for: meal)
            .compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType == HKQuantityType(id) }
    }

    func testMealWithKnownSodiumWritesOneSodiumSample() {
        let m = fullMeal(sodiumMg: 800)
        let sodium = samples(of: m, .dietarySodium)
        XCTAssertEqual(sodium.count, 1)
        XCTAssertEqual(sodium[0].quantity.doubleValue(for: .gramUnit(with: .milli)), 800, accuracy: 0.001,
                       "the summed known sodium is written in milligrams")
    }

    func testMealWithAllUnknownPotassiumWritesNoPotassiumSample() {
        // potassiumMg nil ⇒ no item carried a value ⇒ NO sample (never a zero sample).
        let m = fullMeal(sodiumMg: 800, potassiumMg: nil, calciumMg: nil, magnesiumMg: nil)
        XCTAssertTrue(samples(of: m, .dietaryPotassium).isEmpty,
                      "an all-unknown micronutrient writes no sample")
    }

    func testExistingMacroSamplesAreUnchangedByMicronutrients() {
        // The five macro samples are present and correct regardless of micronutrients.
        let m = fullMeal(sodiumMg: 800, satFatGrams: 3, sugarGrams: 12, potassiumMg: 500)
        XCTAssertEqual(samples(of: m, .dietaryEnergyConsumed).first?.quantity.doubleValue(for: .kilocalorie()), 100)
        XCTAssertEqual(samples(of: m, .dietaryProtein).first?.quantity.doubleValue(for: .gram()), 20)
        XCTAssertEqual(samples(of: m, .dietaryCarbohydrates).first?.quantity.doubleValue(for: .gram()), 30)
        XCTAssertEqual(samples(of: m, .dietaryFatTotal).first?.quantity.doubleValue(for: .gram()), 10)
        XCTAssertEqual(samples(of: m, .dietaryFiber).first?.quantity.doubleValue(for: .gram()), 5)
        // And the micronutrient samples ride alongside them.
        XCTAssertEqual(samples(of: m, .dietaryFatSaturated).first?.quantity.doubleValue(for: .gram()), 3)
        XCTAssertEqual(samples(of: m, .dietarySugar).first?.quantity.doubleValue(for: .gram()), 12)
        XCTAssertEqual(samples(of: m, .dietaryPotassium).first?.quantity.doubleValue(for: .gramUnit(with: .milli)), 500)
    }

    func testMealWithNoMicronutrientsWritesOnlyTheFiveMacroSamples() {
        let m = fullMeal()   // all six micronutrients nil
        let count = HealthKitMealWriter.samples(for: m).count
        XCTAssertEqual(count, 5, "no micronutrient values ⇒ only the five macro samples")
    }

    func testMealWithKnownCalciumAndMagnesiumWritesThoseSamples() {
        let m = fullMeal(calciumMg: 250, magnesiumMg: 90)
        let calcium = samples(of: m, .dietaryCalcium)
        let magnesium = samples(of: m, .dietaryMagnesium)
        XCTAssertEqual(calcium.count, 1)
        XCTAssertEqual(calcium[0].quantity.doubleValue(for: .gramUnit(with: .milli)), 250, accuracy: 0.001,
                       "the summed known calcium is written in milligrams")
        XCTAssertEqual(magnesium.count, 1)
        XCTAssertEqual(magnesium[0].quantity.doubleValue(for: .gramUnit(with: .milli)), 90, accuracy: 0.001,
                       "the summed known magnesium is written in milligrams")
    }

    func testMealWithAllUnknownCalciumMagnesiumWritesNoSample() {
        // Both nil ⇒ no item carried a value ⇒ NO sample (never a zero sample).
        let m = fullMeal(sodiumMg: 800, calciumMg: nil, magnesiumMg: nil)
        XCTAssertTrue(samples(of: m, .dietaryCalcium).isEmpty,
                      "an all-unknown calcium writes no sample")
        XCTAssertTrue(samples(of: m, .dietaryMagnesium).isEmpty,
                      "an all-unknown magnesium writes no sample")
    }

    func testMealWithEveryMicronutrientWritesElevenSamplesAndNoOmega3() {
        // Five macros + six HealthKit micros = eleven; omega-3 and unsaturated fat are
        // NOT written (no HealthKit type / gauge-only), so there is no twelfth sample.
        let m = fullMeal(sodiumMg: 800, satFatGrams: 3, sugarGrams: 12, potassiumMg: 500,
                         calciumMg: 250, magnesiumMg: 90)
        XCTAssertEqual(HealthKitMealWriter.samples(for: m).count, 11,
                       "five macros plus the six HealthKit-bound micronutrients")
    }
}
