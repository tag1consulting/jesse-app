import Foundation
import Security
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

// Shared fakes for the macOS client tests: an in-memory Keychain backend (so the config
// round-trip and legacy-migration tests run without Keychain entitlements) and a scriptable
// bridge client (so the whole coordinator (send, hydrate, session list) is driven off a
// fake). Both mirror the seams already used by the iOS `ConfigStoreRoundTripTests` and the
// existing Mac `FakeBridgeClient`, just factored out so several test files share them.

/// In-memory Keychain keyed by each item's `kSecAttrAccount`. The `add`/`copy`/`delete`
/// closures plug straight into `KeychainConfigStore` and into `MacConfigStore`'s legacy
/// migration seams, all backed by the SAME store so a legacy item seeded here is visible to
/// both the migration read and the post-migration rewrite.
final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func seed(account: String, _ value: String) { lock.withLock { items[account] = Data(value.utf8) } }
    func string(account: String) -> String? {
        lock.withLock { items[account] }.flatMap { String(data: $0, encoding: .utf8) }
    }
    func has(account: String) -> Bool { lock.withLock { items[account] != nil } }

    private func account(_ d: CFDictionary) -> String? {
        (d as NSDictionary)[kSecAttrAccount as String] as? String
    }

    func add(_ attrs: CFDictionary, _ out: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let acct = account(attrs) else { return errSecParam }
        lock.withLock { items[acct] = (attrs as NSDictionary)[kSecValueData as String] as? Data }
        return errSecSuccess
    }
    func copy(_ query: CFDictionary, _ out: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let acct = account(query) else { return errSecParam }
        return lock.withLock {
            guard let data = items[acct] else { return errSecItemNotFound }
            out?.pointee = data as CFData
            return errSecSuccess
        }
    }
    func delete(_ query: CFDictionary) -> OSStatus {
        if let acct = account(query) { lock.withLock { items[acct] = nil } }
        return errSecSuccess
    }

    /// A `KeychainConfigStore` (the shared new-accounts store) over this backend.
    func configStore(service: String) -> KeychainConfigStore {
        KeychainConfigStore(service: service, add: add, copy: copy, delete: delete)
    }
}

/// A scriptable `BridgeClientProtocol`. Defaults are inert; each test sets only what it
/// exercises. `@unchecked Sendable` with a lock because the protocol methods are
/// `nonisolated` and may run off the main actor.
final class MacFakeBridgeClient: BridgeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()

    private var sessions: SessionsResult
    private var sendResult: JesseSendResult
    /// Answers `hydrate(sessionId:after:)`. Throwing simulates a 404 / transport error.
    private var hydrateHandler: (String, UInt64) throws -> (turns: [HydratedTurn], nextOffset: UInt64)

    private var _hydrateCalls: [(sessionId: String, after: UInt64)] = []
    private var _deleted: [String] = []

    var hydrateCalls: [(sessionId: String, after: UInt64)] { lock.withLock { _hydrateCalls } }
    var deletedCalls: [String] { lock.withLock { _deleted } }

    nonisolated init(
        sessions: SessionsResult = .notModified,
        sendResult: JesseSendResult = .reply(JesseReply(text: "reply", sessionId: "sess"), jobId: nil),
        hydrate: @escaping (String, UInt64) throws -> (turns: [HydratedTurn], nextOffset: UInt64) = { _, after in ([], after) }
    ) {
        self.sessions = sessions
        self.sendResult = sendResult
        self.hydrateHandler = hydrate
    }

    nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }

    nonisolated func listSessions(since: UInt64?, etag: String?) async throws -> SessionsResult {
        lock.withLock { sessions }
    }
    nonisolated func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {}
    nonisolated func deleteSession(_ sessionId: String) async throws {
        lock.withLock { _deleted.append(sessionId) }
    }
    nonisolated func hydrate(sessionId: String, after: UInt64) async throws -> (turns: [HydratedTurn], nextOffset: UInt64) {
        lock.withLock { _hydrateCalls.append((sessionId, after)) }
        return try lock.withLock { try hydrateHandler(sessionId, after) }
    }
    nonisolated func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                          instructions: String?, floorOverride: String?,
                          attachments: [JesseRequest.Attachment], requestId: String?) async throws -> JesseSendResult {
        lock.withLock { sendResult }
    }
    nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult {
        lock.withLock { sendResult }
    }
    nonisolated func result(jobId: String) async throws -> JesseResultState { .cancelled }
    nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    nonisolated func title(text: String, sessionId: String?) async -> String? { nil }
    nonisolated func cancelJob(jobId: String) async throws {}
    nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
    nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { throw DietFetchError.notConfigured }
    nonisolated func fetchPrompts() async throws -> PromptDefaults { throw JesseError.notConfigured }
}

// MARK: - Shared builders

@MainActor
enum MacTestFixtures {
    /// A fresh in-memory `ModelContext` over the Mac schema.
    static func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A scratch pending-deletion store on a throwaway suite.
    static func deletionStore() -> PendingSessionDeletionStore {
        PendingSessionDeletionStore(defaults: UserDefaults(suiteName: "MacTests.\(UUID().uuidString)")!)
    }

    /// A scratch UserDefaults suite for the hydration cursor, isolated per test.
    static func defaults() -> UserDefaults { UserDefaults(suiteName: "MacTests.\(UUID().uuidString)")! }

    static func configured() -> MacConfigStore {
        MacConfigStore(config: JesseConfig(host: "studio", port: 8765, token: "tok"))
    }
    static func unconfigured() -> MacConfigStore {
        MacConfigStore(config: JesseConfig(host: "", port: JesseConfig.defaultPort, token: ""))
    }
}
