import Foundation

// WHERE A MESSAGE GOES WHEN THE BRIDGE IS NOT THERE.
//
// Before this, a send with the bridge unreachable had exactly one destination: the
// outbox, to be delivered whenever the laptop came back. That is the right answer for
// most messages and a poor one for "when is the school concert", because the answer to
// that question is on the phone already, in the folder Obsidian syncs, in an index the
// app built itself.
//
// The decision is four inputs and no state, so it is a pure function and a test can
// state all four cases in four lines. Every input has to be true for the on-device path
// to be taken, and the default in every other combination is the behaviour that existed
// before this file — which is the property that makes this change safe to ship: a
// device with no folder, no model, or the toggle off cannot tell that this code is
// present.

/// Where one composed message goes.
public enum OfflineSendRoute: Equatable, Sendable {
    /// The path that existed before this file: the bridge, via the outbox when there is
    /// one.
    case bridge
    /// Ask the device.
    case onDevice
}

/// The routing decision, and the reply text each outcome produces.
public enum OfflineLookupRouting {

    /// Whether this send is answered on the device.
    ///
    /// `reachability` must be `.unreachable`, not merely "not reachable": `.unknown` is
    /// the pre-probe state of a cold launch, and answering from a four-hour-old vault
    /// copy because no probe has completed YET would be the worst of both — a stale
    /// local answer on a device that is perfectly online.
    public static func route(reachability: BridgeReachabilityState,
                             hasVaultFolder: Bool,
                             isEnabled: Bool,
                             modelAvailable: Bool) -> OfflineSendRoute {
        guard reachability == .unreachable else { return .bridge }
        guard hasVaultFolder else { return .bridge }
        guard isEnabled else { return .bridge }
        guard modelAvailable else { return .bridge }
        return .onDevice
    }
}

/// Reachability as this target can see it.
///
/// A restatement of `JesseNetworking`'s `BridgeReachability`, for the reason
/// `SearchQueryRules` restates the search rules: this target depends on NOTHING, and
/// importing the networking layer to read a three-case enum would put the bridge client
/// inside the vault index. The app maps one to the other in one line.
public enum BridgeReachabilityState: Equatable, Sendable {
    case unknown
    case reachable
    case unreachable
}

/// The reply an offline turn puts in the transcript.
///
/// Every string a person reads on this path is in this one enum's renderer, because the
/// wording IS the honesty guarantee: "answered from the notes on this device" and
/// "answered by Jesse" have to be impossible to confuse, and two screens composing
/// their own version of that sentence is how they stop being impossible to confuse.
public enum OfflineLookupReply {

    /// The badge, in the same shape the bridge's own local-route badges use
    /// (`[local · vault · …]`). Square brackets, middle dots, first line of the reply.
    public static let badge = "[on-device · offline]"

    /// What the reply says happened.
    public enum Kind: Equatable, Sendable {
        /// Answered here, with at least one checked citation.
        case answered(VaultAnswer)
        /// The notes on this device do not hold it.
        case abstained
        /// Not a lookup: nothing was asked of the model.
        case notALookup
    }

    /// Render one reply.
    ///
    /// `queued` says whether this device actually has somewhere to put the message
    /// until the bridge is back. The phone does (the send outbox); the Mac does not,
    /// and telling a Mac user their question is "queued for the bridge" when nothing is
    /// holding it would be a plain untruth.
    public static func body(_ kind: Kind, queued: Bool) -> String {
        switch kind {
        case .answered(let answer):
            var out = badge + "\n\n" + answer.text
            out += "\n\nFrom:\n"
            out += answer.citations.map { "- [\($0.reference)](\(link($0)))" }
                .joined(separator: "\n")
            return out
        case .abstained:
            let tail = queued ? " Queued for the bridge." : ""
            return badge + "\n\nNot found in the vault on this device." + tail
        case .notALookup:
            return badge + "\n\nQueued for the bridge."
        }
    }

    /// The link a citation renders as: the app's own `jesse://` scheme, already
    /// registered on both platforms, so opening the reader needs no new URL type and no
    /// entitlement.
    static func link(_ citation: VaultCitation) -> String {
        VaultNoteRoute(path: citation.path, line: citation.line).url.absoluteString
    }
}

// MARK: - A note route as a URL

extension VaultNoteRoute {
    /// The scheme the app already registers (`jesse://share-audio` is the other user of
    /// it). Reusing it is deliberate: a second scheme would be a second Info.plist
    /// entry, on two platforms, for a link that never leaves the app.
    public static let urlScheme = "jesse"
    public static let urlHost = "note"

    /// `jesse://note?path=Workshop/Kiln-Rebuild.md&line=12`
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = Self.urlHost
        var items = [URLQueryItem(name: "path", value: path)]
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        components.queryItems = items
        // The components are all set and the path is percent-encoded by `URLComponents`
        // itself, so this cannot fail; an empty note route is still preferable to a
        // crash in a composer.
        return components.url ?? URL(string: "\(Self.urlScheme)://\(Self.urlHost)")!
    }

    /// The route a `jesse://note?…` URL names, or nil for any other URL — including
    /// `jesse://share-audio`, which this must not claim.
    public static func parse(_ url: URL) -> VaultNoteRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == urlScheme,
              components.host?.lowercased() == urlHost
        else { return nil }
        let items = components.queryItems ?? []
        guard let path = items.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else { return nil }
        let line = items.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
        return VaultNoteRoute(path: path, line: line)
    }
}

/// A route identifies itself by the note and the line, so a sheet can be presented from
/// one. Declared here rather than on the type so the reader's own file stays about the
/// reader; same module, so this is not a retroactive conformance.
extension VaultNoteRoute: Identifiable {
    public var id: String { "\(path)#\(line ?? 0)" }
}
