import WidgetKit
import SwiftUI

/// The watch widget extension's entry point. One widget today — the Today
/// complication — but the bundle is where a second would go.
///
/// Separate from `JesseWidgets` (the iOS extension that hosts the in-flight-turn
/// Live Activity) because they are different platforms with different bundles: an
/// iOS `.appex` cannot be embedded in a watch app, and a watch complication cannot
/// live in an iOS extension.
@main
struct JesseWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JesseTodayComplication()
    }
}
