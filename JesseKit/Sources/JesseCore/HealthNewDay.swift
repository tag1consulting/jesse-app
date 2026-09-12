import Foundation

/// The fixed message the Health tab's "Start new day" button sends on a fresh Tell
/// thread. Shared here in JesseCore because both the iOS and macOS Health tabs fire it.
///
/// The wording is load-bearing and must keep three properties if ever reworded:
///   1. It names its own scope ("do only this") so the Studio-side routine runs the
///      morning health/diet refresh alone and does NOT fall into full start-of-day.
///   2. It contains "health", "weigh-in", and "log" so the iOS keyword classifier
///      (`HealthKeywordClassifier`) treats it as health-related and attaches this
///      morning's weigh-in block. Drop those words and the weigh-in silently stops
///      attaching. A test pins the classification.
///
/// On iOS the same text is also sent WITHOUT a tap, when the first body-mass reading of a
/// diet day lands in Apple Health (`HealthAutoTurn.morningRefresh`). The two are one
/// operation: the automatic thread carries `ThreadOrigin.automatic` instead of a prefix,
/// so the text stays byte-identical, and both write `lastFiredDayKey`.
public enum HealthNewDay {
    public static let prompt = "Start my new health day. This is the daily health and diet new-day refresh, and only that. Audit yesterday's diet logging and fix any errors, write yesterday's diet journal, roll the diet dashboard over to today, log this morning's weigh-in from my health data, then regenerate the fancy dashboard. Do only this. Do not run start of day, the inbox or message scanners, currency, cheatsheets, or any other routine."

    /// `UserDefaults` key holding the last DIET day (`DietDay.stamp`) this device ran the
    /// refresh for, by the button, by a new weigh-in, or folded into the morning routine.
    /// A per-device date, not a secret. iOS only: the Mac's button keeps its old behaviour.
    public nonisolated static let lastFiredDayKey = "healthNewDayLastFiredDay"

    /// What the button says when the refresh already ran on this device for this diet day.
    public nonisolated static let alreadyRanNotice =
        "Today's new-day refresh already ran from this device, so it wasn't sent again. Automatic runs are under Auto in Chats."
}
