import Foundation

// The Chats tab's "Good morning" button: the fixed message it sends, and the
// confirmation copy both platforms present before sending it. A peer of
// `HealthNewDay.swift` and `TodayPrompts.swift`, and shared here for the same reason
// they are — the iPhone and the Mac must send the same bytes and offer the same
// choice, and a second spelling on the other platform is a second definition of what
// the morning button does.
//
// WHAT THIS IS. The Studio-side agent has a start-of-day routine: any session-opening
// greeting triggers it, it fans out parallel scanners over mail, chat, calendar and
// the vault, and it ends by rebuilding the day file and delivering one briefing.
// Jeremy has always started it by opening a chat and typing "good morning it's August
// 10th". This is that typed greeting, as a button.
//
// ISOLATION. This target compiles with `defaultIsolation(MainActor.self)` (it holds
// the @Model layer, authored against the app's MainActor default), so everything here
// would be MainActor-isolated by default. `prompt` and its helpers are `nonisolated`
// DELIBERATELY, for the reason `TodayPrompts.swift` sets out at length: they are pure
// functions of their arguments, and inheriting the default would make each one an
// await for no reason and make them untestable from a plain synchronous test method.

/// The full start-of-day routine, fired from the Chats tab.
///
/// FOUR PROPERTIES OF THE WORDING ARE LOAD-BEARING and survive any reword:
///
///   1. **The positive scope sentence.** It asks for start of day by name. The vault's
///      routines are selected by what a turn's text says, so a prompt that merely
///      described the morning would not run it.
///   2. **The negative clause in the default body**, naming the health and diet new-day
///      refresh and forbidding it. That refresh is the Health tab button's job and also
///      runs as a scheduled task; without this clause one tap can roll the diet
///      dashboard over twice in a morning.
///   3. **The ordering and the interim report line in the opt-in body.** When the health
///      refresh is folded in it goes FIRST and reports the moment it lands, because
///      until the diet rollover is done Jeremy cannot log food or exercise for the new
///      day, and start of day takes long enough that waiting it out is the whole
///      problem being solved. The ordering is the feature, not a detail.
///   4. **The date**, interpolated from the device. The agent's own idea of "today"
///      comes from a different machine in a different time zone, and Jeremy types the
///      date when he does this by hand.
///
/// KEYWORD CLASSIFICATION. On iOS a Tell turn whose text reads as health-related gets
/// this morning's weigh-in attached (`HealthKeywordClassifier`). Both bodies clear that
/// floor — the default one on "health", the opt-in one on "health", "log" and "weigh" —
/// and the routine's health check-in wants the block. A reword that drops those words
/// silently drops the attachment, so a test pins the classification of both bodies.
public enum MorningRoutine {

    // MARK: - The prompt

    /// The message one tap sends, on a fresh Tell thread.
    ///
    /// `now` and `calendar` are parameters rather than reads of `Date.now` so a test can
    /// pin the rendered date against a fixed instant and a fixed time zone — the two
    /// halves of "the phone's date, not the agent's".
    ///
    /// `includeHealthNewDay` defaults to `false`: folding the health and diet refresh in
    /// is an explicit second choice in the confirmation, never what a plain confirm does.
    public nonisolated static func prompt(now: Date,
                                          calendar: Calendar = .current,
                                          includeHealthNewDay: Bool = false) -> String {
        let date = formattedDate(now, calendar: calendar)
        // Two whole bodies rather than one body plus an inserted paragraph, and the
        // opt-in one is NOT assembled from `HealthNewDay.prompt`: that constant carries
        // its own clause forbidding start of day, which would contradict the second half
        // of this instruction. The two share wording because they name the same work, and
        // they are allowed to drift apart.
        if includeHealthNewDay {
            return "Good morning. It is \(date). Two things, in this order. FIRST, the health and diet new day refresh, finished completely before anything else starts: audit yesterday's diet logging and fix any errors, write yesterday's diet journal, roll the diet dashboard over to today, log this morning's weigh-in from my health data, then regenerate the fancy dashboard. The moment that part is done, send one short line beginning STILL RUNNING: saying so, before you go on, because I cannot log today's food or exercise until it has landed and I do not want to wait out the rest of the turn. SECOND, the full start of day routine: the scanners, the inbox, the calendar, the currency check, whatever else today's day of the week calls for, then rebuild Today.md and give me the briefing at the end. If start of day already ran today, give me the delta rather than a full rerun."
        }
        return "Good morning. It is \(date). Run the full start of day routine now: the scanners, the inbox, the calendar, the currency check, whatever else today's day of the week calls for, then rebuild Today.md and give me the briefing at the end. If start of day already ran today, give me the delta rather than a full rerun. Do not run the health and diet new day refresh: the Health tab button owns that one and it may already have run."
    }

    /// The date as the greeting spells it — `Monday, August 10, 2026`.
    ///
    /// Pinned to `en_US_POSIX` and to the calendar's own time zone. The locale pin is not
    /// cosmetic: the agent reads English, and a device set to Italian would otherwise send
    /// "lunedì, agosto 10, 2026" — a silent behavior change on a phone whose language
    /// setting has nothing to do with what the vault speaks.
    private nonisolated static func formattedDate(_ now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: now)
    }

    // MARK: - The confirmation

    /// The confirmation's title, and the accessibility label of the toolbar button.
    public nonisolated static let dialogTitle = "Good morning"
    /// The leading confirm action: start of day alone. First in the list because a
    /// `confirmationDialog`'s leading action reads as the default, and this is the
    /// common case.
    public nonisolated static let startAction = "Start the day"
    /// The second confirm action: the same turn with the health and diet refresh folded
    /// in at the head of it. Two actions rather than a toggle — a dialog presents
    /// actions, not controls, and a sheet with a switch would trade a one-tap confirm for
    /// a two-tap form on something Jeremy does every morning.
    public nonisolated static let includeHealthAction = "Include health and diet first"

    /// The ordinary message: a tap starts a long routine, so say what it starts.
    public nonisolated static let message = "Run the full start of day routine now?"
    /// The message shown when this device already fired the routine today.
    public nonisolated static let alreadyFiredMessage =
        "Start of day already ran from this device today. Run it again for a delta?"

    /// `@AppStorage` key holding the last local day this device fired the routine, as
    /// `yyyy-MM-dd`. Shared by both platforms so the two agree on what "today" means.
    public nonisolated static let lastFiredDayKey = "morningRoutineLastFiredDay"

    /// Today's local day as the stored stamp spells it.
    public nonisolated static func dayStamp(_ now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// Which message the confirmation shows, given the stored last-fired day.
    ///
    /// This is the ONLY thing the stamp changes. It never disables or hides either
    /// action: the routine may have run from the other device or from a scheduled task,
    /// and the app has no way to know that — so "already ran" is a note, and re-running
    /// for a delta is a legitimate thing to want.
    public nonisolated static func confirmationMessage(lastFiredDay: String?,
                                                       now: Date,
                                                       calendar: Calendar = .current) -> String {
        lastFiredDay == dayStamp(now, calendar: calendar) ? alreadyFiredMessage : message
    }
}
