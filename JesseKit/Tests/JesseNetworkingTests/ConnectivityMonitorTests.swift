import XCTest
@testable import JesseNetworking

/// The one place the app asks whether it has a network. Every recovery in the app now
/// hangs off the transitions asserted here, so they are driven directly — `apply` is
/// internal for exactly this reason — rather than through a real `NWPathMonitor`.
final class ConnectivityMonitorTests: XCTestCase {

    /// A source a test drives by hand, for the one test that is about the source.
    private struct FakeSource: NetworkPathSource {
        let stream: AsyncStream<NetworkPathSnapshot>
        func paths() -> AsyncStream<NetworkPathSnapshot> { stream }
    }

    private func path(satisfied: Bool, expensive: Bool = false, constrained: Bool = false,
                      kind: NetworkInterfaceKind = .wifi) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: satisfied, isExpensive: expensive,
                            isConstrained: constrained, interfaceKind: kind)
    }

    @MainActor
    private func monitor() -> ConnectivityMonitor {
        let (stream, _) = AsyncStream<NetworkPathSnapshot>.makeStream()
        return ConnectivityMonitor(source: FakeSource(stream: stream))
    }

    // MARK: - The unknown default

    /// Before the first callback the monitor must behave EXACTLY as the app did before it
    /// existed: try the request, and let the request's own failure be the evidence.
    /// Starting at "unsatisfied" would gate the first send of every cold launch on a
    /// callback that has not fired yet.
    func testUnknownPathReadsAsSatisfiedAndUnmetered() {
        XCTAssertTrue(NetworkPathSnapshot.unknown.isSatisfied)
        XCTAssertFalse(NetworkPathSnapshot.unknown.isExpensive)
        XCTAssertFalse(NetworkPathSnapshot.unknown.isConstrained)
        XCTAssertEqual(NetworkPathSnapshot.unknown.interfaceKind, .unknown)
    }

    // MARK: - Adoption and fan-out

    @MainActor
    func testAdoptsReportedPathAndMirrorsItForOffMainReaders() {
        let m = monitor()
        let cellular = path(satisfied: true, expensive: true, kind: .cellular)
        m.apply(cellular)
        XCTAssertEqual(m.path, cellular)
        XCTAssertEqual(CurrentNetworkPath.current, cellular,
                       "the off-main mirror is written as the path is adopted, so a "
                       + "nonisolated reader (the send path, the downscaler) is never one "
                       + "path behind the observable one")
    }

    /// `NWPathMonitor` reports every interface event. A consumer that re-attached in-flight
    /// jobs on each one would do so several times for a single walk out of the front door,
    /// so an unchanged path is not republished.
    @MainActor
    func testRepeatedIdenticalPathIsNotRepublished() async {
        let m = monitor()
        let collector = Collector()
        let stream = m.paths()
        let pump = Task { for await p in stream { await collector.append(p) } }
        await Task.yield()

        let wifi = path(satisfied: true)
        m.apply(wifi)
        m.apply(wifi)
        m.apply(wifi)
        // The first element is the CURRENT path at subscribe time; then exactly one change.
        await collector.waitForCount(2)
        pump.cancel()
        let seen = await collector.values
        XCTAssertEqual(seen.count, 2, "got \(seen)")
        XCTAssertEqual(seen.first, .unknown)
        XCTAssertEqual(seen.last, wifi)
    }

    /// A late subscriber must not be blind until the network next moves.
    @MainActor
    func testSubscriberReceivesTheCurrentPathImmediately() async {
        let m = monitor()
        m.apply(path(satisfied: false, kind: .unknown))
        var first: NetworkPathSnapshot?
        for await p in m.paths() { first = p; break }
        XCTAssertEqual(first?.isSatisfied, false)
    }

    /// The source is actually consumed once `start()` runs — the one test that is about
    /// the seam rather than about the transitions.
    @MainActor
    func testStartConsumesTheSource() async {
        let (stream, continuation) = AsyncStream<NetworkPathSnapshot>.makeStream()
        let m = ConnectivityMonitor(source: FakeSource(stream: stream))
        XCTAssertFalse(m.isRunning)
        m.start()
        XCTAssertTrue(m.isRunning)
        defer { m.stop() }
        let cell = path(satisfied: true, expensive: true, kind: .cellular)
        continuation.yield(cell)
        await waitUntil { m.path == cell }
        XCTAssertEqual(m.path, cell)

        // Idempotent: a second start must not stand up a second NWPathMonitor.
        m.start()
        XCTAssertTrue(m.isRunning)
    }

    // MARK: - What counts as a recovery

    /// The transition the whole feature keys off. Stated as a table because three separate
    /// recoveries (re-attach, outbox drain, snapshot refresh) must agree on it.
    func testOnlyUnsatisfiedToSatisfiedIsARecovery() {
        let down = path(satisfied: false, kind: .unknown)
        let wifi = path(satisfied: true, kind: .wifi)
        let cell = path(satisfied: true, expensive: true, kind: .cellular)

        XCTAssertTrue(pathDidRecover(from: down, to: wifi))
        XCTAssertTrue(pathDidRecover(from: down, to: cell))
        XCTAssertFalse(pathDidRecover(from: wifi, to: down), "going away is not coming back")
        XCTAssertFalse(pathDidRecover(from: down, to: down))
        XCTAssertFalse(
            pathDidRecover(from: wifi, to: cell),
            "an interface SWAP is not a recovery: nothing was waiting on it, and treating "
            + "it as one turns a walk past the front door into a burst of refetches")
    }

    // MARK: - The bounded wait

    @MainActor
    func testAwaitSatisfiedReturnsImmediatelyWhenAlreadySatisfied() async {
        // `.unknown` reads as satisfied, so this must not wait at all.
        let satisfied = await monitor().awaitSatisfied(timeout: 30)
        XCTAssertTrue(satisfied)
    }

    @MainActor
    func testAwaitSatisfiedReturnsWhenThePathComesBack() async {
        let m = monitor()
        m.apply(path(satisfied: false, kind: .unknown))
        XCTAssertFalse(m.path.isSatisfied)

        let waiter = Task { await m.awaitSatisfied(timeout: 30) }
        // Let the waiter subscribe before the path moves; its subscription is what carries
        // the change to it.
        await Task.yield()
        await Task.yield()
        m.apply(path(satisfied: true))
        let came = await waiter.value
        XCTAssertTrue(came)
    }

    /// The bound is what makes this safe inside a poll loop: an unbounded wait would turn
    /// "the network is gone" into a spinner that never stops.
    @MainActor
    func testAwaitSatisfiedGivesUpAtTheTimeout() async {
        let m = monitor()
        m.apply(path(satisfied: false, kind: .unknown))
        let came = await m.awaitSatisfied(timeout: 0.05)
        XCTAssertFalse(came)
    }
}

/// Collects what a subscription yielded, across isolation domains.
private actor Collector {
    private(set) var values: [NetworkPathSnapshot] = []
    func append(_ p: NetworkPathSnapshot) { values.append(p) }

    /// Wait until at least `count` elements have arrived, or give up. Polling rather than
    /// a continuation because the point of the assertion is the count, and a test that
    /// hangs on a missing element is worse than one that fails on it.
    func waitForCount(_ count: Int) async {
        for _ in 0..<200 where values.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Spin until `condition` holds, bounded. Free function because `XCTestCase` is not
/// `Sendable`, so a nonisolated method on `self` called from a `@MainActor` test is a
/// data-race diagnostic.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
