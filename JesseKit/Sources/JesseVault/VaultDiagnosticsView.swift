import Foundation
import SwiftUI

// THE SCREEN THAT SETTLES THE ARGUMENT.
//
// The question this whole spike exists to answer — can this app hold the Obsidian
// vault folder, and what can the on-device model hold — is a question about
// Jeremy's iPhone and Jeremy's Mac, not about a simulator and not about a design
// document. So the four measurements are buttons, the results are numbers, and
// every result line is selectable so a number can leave the device as text rather
// than as a recollection.
//
// One screen, both platforms, for the reason the Ops screens are shared: two copies
// would be two answers to the same question.
//
// NOTHING RUNS ON APPEAR except reading the folder's status, which is a bookmark
// resolution and costs nothing. The scan, the read, the append and the model probe
// all wait to be asked. The model probe in particular must never be speculative:
// it is minutes of on-device inference.

/// The four probes, and what each one last produced.
@MainActor
@Observable
public final class VaultDiagnosticsModel {
    /// See the GOTCHA in this target's `Package.swift` comment: under an explicit
    /// `@MainActor` the synthesized deinit is MainActor-isolated, and a unit-test
    /// host releasing this off the main actor routes through the isolated-deinit
    /// executor hop, which aborts. The same empty `nonisolated deinit` that
    /// `ThreadSearchModel` and `FoundationModelExpander` carry.
    nonisolated deinit {}

    public private(set) var status: VaultFolderStatus = .notSet
    public private(set) var scanLines: [String] = []
    public private(set) var readLines: [String] = []
    public private(set) var appendLines: [String] = []
    public private(set) var modelLines: [String] = []
    public private(set) var busy: String?

    private let folder: VaultFolder
    private let probeSession: any ProbeSessioning
    /// Where the probe's measured prompt size is persisted, and where the offline
    /// answer path reads it from.
    private let settings: OfflineLookupSettings
    /// The last few offline questions. Held, not owned — the composer writes to it.
    public let offline: OfflineLookupDiagnostics
    /// What this device has written into the vault's `Inbox/`, newest first. Read from the
    /// log rather than mirrored: the composer and the reader both write captures, so a copy
    /// held here would be a second answer to "what did this device write".
    public private(set) var captures: [OfflineWriteRecord] = []
    /// The capture service, for the verification pass and Re-capture.
    private let capture: InboxCaptureService
    /// The index's own state, shown here rather than re-derived: one object owns "is a
    /// reindex running", and a screen that kept its own copy of that would be a second
    /// answer to the same question.
    public let indexer: VaultIndexer

    public init(folder: VaultFolder = VaultFolder(),
                probeSession: any ProbeSessioning = FoundationModelProbeSession(),
                indexer: VaultIndexer = VaultIndexer(),
                settings: OfflineLookupSettings = OfflineLookupSettings(),
                offline: OfflineLookupDiagnostics = .shared,
                capture: InboxCaptureService = .shared) {
        self.folder = folder
        self.probeSession = probeSession
        self.indexer = indexer
        self.settings = settings
        self.offline = offline
        self.capture = capture
    }

    /// The offline answer rows, newest first, or the one line that says there are none.
    public var offlineLines: [String] {
        guard !offline.records.isEmpty else {
            return ["No questions have been answered on this device yet."]
        }
        return offline.records.map(\.line)
    }

    /// What the index holds, as lines.
    public var indexLines: [String] {
        var lines = [
            "FTS5 available: \(VaultIndex.fts5IsAvailable ? "yes" : "NO — the index cannot be built")",
            "Files indexed: \(indexer.counts.fileCount)",
            "Chunks: \(indexer.counts.chunkCount)",
            "Wiki links: \(indexer.counts.linkCount)",
            "Database: \(Self.bytes(indexer.counts.databaseBytes))",
        ]
        if let report = indexer.lastReport {
            lines.append("Last reindex: \(report.summary)")
        }
        if let error = indexer.lastError {
            lines.append("Last error: \(error)")
        }
        return lines
    }

    /// The capture rows, or the one line that says there are none.
    public var captureLines: [String] {
        guard !captures.isEmpty else {
            return ["Nothing has been captured into the vault from this device yet."]
        }
        return captures.map { "\(Self.time($0.written))  \($0.line)" }
    }

    /// The captures the verification pass could not find. Each one keeps its text, so it
    /// can be written again.
    public var missingCaptures: [OfflineWriteRecord] {
        captures.filter { $0.status.needsAttention }
    }

    public func refreshStatus() {
        status = folder.resolve()
    }

    /// Read the log back. Cheap (one small JSON file) and called on appear and after every
    /// action, which is what keeps this screen agreeing with what the composer just wrote.
    public func refreshCaptures() {
        captures = capture.recent
    }

    /// Re-read the capture files and record what is still in them.
    ///
    /// The same pass app activation runs. It is here as a button too because "is my capture
    /// really in the file" is a question a person asks at the moment they are worried, not
    /// at the moment the scene phase changes.
    public func verifyCaptures() async {
        busy = "Checking the captures…"
        defer { busy = nil }
        await capture.verifyRecent()
        refreshCaptures()
    }

    /// Write one missing capture's own line back into its own file.
    ///
    /// Only from a press. NOTHING here re-appends on its own — a background pass that kept
    /// making captures good would be the mechanism by which one thought becomes four.
    public func recapture(_ record: OfflineWriteRecord) async {
        busy = "Writing it again…"
        defer { busy = nil }
        switch await capture.recapture(record) {
        case .success:
            await capture.verifyRecent()
        case .failure(let failure):
            appendLines = ["Re-capture failed: \(failure.description)"]
        }
        refreshCaptures()
    }

    /// The whole vault, counted and timed.
    public func scan() async {
        busy = "Scanning…"
        defer { busy = nil }
        let folder = self.folder
        // OFF THE MAIN ACTOR. A full walk of the vault is the one operation here
        // that is measured in seconds, and the number being measured must not be
        // the number a blocked UI produces.
        let outcome: Result<VaultScan, Error> = await Task.detached {
            do { return .success(try folder.withAccess { VaultScanner().scan(root: $0) }) }
            catch { return .failure(error) }
        }.value

        switch outcome {
        case .failure(let error):
            scanLines = ["Scan failed: \(Self.describe(error))"]
        case .success(let scan):
            var lines = [
                "Files: \(scan.fileCount) markdown",
                "Bytes: \(Self.bytes(scan.totalBytes))",
                String(format: "Duration: %.3f s", scan.duration),
            ]
            if scan.unreadableCount > 0 {
                lines.append("Unreadable entries skipped: \(scan.unreadableCount)")
            }
            lines.append("Five most recently modified:")
            for entry in scan.mostRecentlyModified(5) {
                lines.append("  \(entry.relativePath) — \(Self.stamp(entry.modified))")
            }
            scanLines = lines
        }
    }

    /// `Today.md` from the vault root.
    public func readToday() async {
        busy = "Reading…"
        defer { busy = nil }
        let folder = self.folder
        let outcome: Result<String, Error> = await Task.detached {
            do { return .success(try folder.withAccess { try VaultFile(root: $0).read(relativePath: "Today.md") }) }
            catch { return .failure(error) }
        }.value

        switch outcome {
        case .failure(let error):
            readLines = ["Read failed: \(Self.describe(error))"]
        case .success(let text):
            readLines = [
                "Today.md: \(text.utf8.count) bytes",
                "First 300 characters:",
                String(text.prefix(300)),
            ]
        }
    }

    /// One stamped line into today's probe file under `Inbox/`.
    ///
    /// This is the ONLY thing in the whole target that writes to the vault, and it
    /// writes only here: one appended line, in one file, under one directory.
    public func appendProbe() async {
        busy = "Appending…"
        defer { busy = nil }
        let relativePath = Self.probeRelativePath(for: Date())
        let line = Self.probeLine(for: Date(), device: Self.deviceName())
        let folder = self.folder
        let outcome: Result<Int, Error> = await Task.detached {
            do { return .success(try folder.withAccess { try VaultFile(root: $0).append(relativePath: relativePath, text: line) }) }
            catch { return .failure(error) }
        }.value

        switch outcome {
        case .failure(let error):
            appendLines = ["Append failed: \(Self.describe(error))"]
        case .success(let size):
            appendLines = [
                "Appended to \(relativePath)",
                "Line: \(line.trimmingCharacters(in: .newlines))",
                "File is now \(Self.bytes(size))",
            ]
        }
    }

    /// The on-device model's availability and measured capacity. Minutes of
    /// inference, and only ever on an explicit press.
    public func probeModel() async {
        busy = "Probing the on-device model — this takes a while…"
        defer { busy = nil }
        let report = await ModelProbe(session: probeSession).run()
        // PERSISTED, and this is the only place it is written. The offline answer path
        // spends a share of this number on every question, and the report it used to
        // live in existed for as long as this screen did. A measurement made once, on
        // this device, is exactly the kind of fact that belongs in `UserDefaults`.
        settings.measuredPromptCharacters = report.largestPromptCharacters
        modelLines = report.lines + [VaultRetrievalBudget.describe(report.largestPromptCharacters)]
    }

    // MARK: - Pure formatting, assertable without a device
    //
    // Every one of these is `nonisolated` explicitly. They are pure functions over a
    // `Date` and a `Calendar`, and inheriting the class's `@MainActor` would mean a
    // test (or an off-main caller building the probe's path before hopping) could not
    // call them at all. Same convention as the pure declarations in `FlagSync.swift`.

    /// `Inbox/YYYY-MM-DD-phone-probe.md`, in the DEVICE's own time zone: the file
    /// is looked for by a human opening Obsidian on the day they pressed the button.
    public nonisolated static func probeRelativePath(for date: Date, calendar: Calendar = .current) -> String {
        "Inbox/\(isoDay(date, calendar: calendar))-phone-probe.md"
    }

    /// The one appended line, with its trailing newline so a second append cannot
    /// land on the same physical line as the first.
    public nonisolated static func probeLine(for date: Date, device: String, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d:%02d",
                           parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0)
        return "- \(stamp) Jesse vault probe from \(device)\n"
    }

    public nonisolated static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// This device's name, WITHOUT importing UIKit. `UIDevice.current.name` is
    /// entitlement-gated since iOS 16 and would drag UIKit into a target that has no
    /// other reason to link it; the host name is what both platforms answer with.
    public nonisolated static func deviceName() -> String {
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    nonisolated static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    nonisolated static func time(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let vault = error as? VaultFileError { return vault.description }
        if let folder = error as? VaultFolderError { return folder.description }
        return error.localizedDescription
    }
}

/// The screen itself.
public struct VaultDiagnosticsView: View {
    @State private var model: VaultDiagnosticsModel

    public init(model: VaultDiagnosticsModel = VaultDiagnosticsModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Form {
            Section {
                Text(model.status.display)
                    .textSelection(.enabled)
                if let busy = model.busy {
                    HStack { ProgressView(); Text(busy).foregroundStyle(.secondary) }
                }
                Text("Everything below runs against the folder held on this device, and only when you press it. Nothing here is sent anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Folder")
            }

            probeSection(title: "Scan",
                         explanation: "Walks every markdown file in the vault and times itself. Under about two seconds on the phone is the number this is looking for.",
                         button: "Scan the vault",
                         lines: model.scanLines) { await model.scan() }

            probeSection(title: "Read",
                         explanation: "Reads Today.md from the vault root through a coordinated read.",
                         button: "Read Today.md",
                         lines: model.readLines) { await model.readToday() }

            probeSection(title: "Append",
                         explanation: "Appends one stamped line to today's probe file under Inbox/. This is the only thing here that writes, and it never rewrites a byte that is already there.",
                         button: "Append a probe line",
                         lines: model.appendLines) { await model.appendProbe() }

            Section {
                Text("The search index over this vault: one SQLite database in Application Support, never inside the vault folder. Reindex reads only the files whose modification time or size changed; Rebuild throws the whole index away first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reindex") { Task { await model.indexer.reindexNow() } }
                        .disabled(model.indexer.isIndexing || !model.status.isReady)
                    Button("Rebuild") { Task { await model.indexer.rebuild() } }
                        .disabled(model.indexer.isIndexing || !model.status.isReady)
                }
                if model.indexer.isIndexing {
                    HStack {
                        ProgressView(value: model.indexer.progress)
                        Text("\(Int(model.indexer.progress * 100))%")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(model.indexLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Index")
            }

            Section {
                Text("The last \(OfflineLookupDiagnostics.capacity) questions this device answered from the vault on its own, with the bridge unreachable. Held in memory only — it is empty again after a relaunch, and nothing here is written anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Array(model.offlineLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Offline answers")
            }

            Section {
                Text("What this device wrote into the vault's Inbox/ on its own, without the Studio. Each row carries a checksum of the line it appended; Check re-reads the files and says whether the line is still there. Nothing here is ever re-written automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Check the captures") { Task { await model.verifyCaptures() } }
                    .disabled(model.busy != nil || !model.status.isReady)
                ForEach(Array(model.captureLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A row per missing capture rather than one "fix them all": each of these is
                // a thought somebody wrote down, and writing four of them back at once is
                // not a decision to take on somebody's behalf.
                ForEach(model.missingCaptures) { record in
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.summary)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Re-capture") { Task { await model.recapture(record) } }
                            .disabled(model.busy != nil || !model.status.isReady)
                    }
                }
            } header: {
                Text("Captures")
            }

            probeSection(title: "On-device model",
                         explanation: "Grows a prompt until the on-device model refuses it, then narrows down to the nearest 500 characters. Takes a few minutes and runs entirely on this device.",
                         button: "Probe the model",
                         lines: model.modelLines) { await model.probeModel() }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Vault diagnostics")
        .onAppear {
            model.refreshStatus()
            model.indexer.refreshCounts()
            model.refreshCaptures()
        }
    }

    @ViewBuilder
    private func probeSection(title: String,
                              explanation: String,
                              button: String,
                              lines: [String],
                              action: @escaping () async -> Void) -> some View {
        Section {
            // The explanation is a ROW, not a `footer:`. On macOS a long footer
            // ellipsises to a single line, and what it would be eating here is the
            // sentence that says what the number means ("under about two seconds is
            // the number this is looking for"), which is the whole point of the
            // screen. A row wraps on both platforms.
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(button) { Task { await action() } }
                .disabled(model.busy != nil || !model.status.isReady)
            // Each line is its own selectable `Text` rather than one blob: a row is
            // what a person actually wants to copy, and a single selectable blob on
            // iOS selects all of it or none.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text(title)
        }
    }
}
