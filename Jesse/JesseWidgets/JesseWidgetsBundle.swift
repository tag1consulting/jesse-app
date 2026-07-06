import WidgetKit
import SwiftUI

/// The widget extension's entry point. It hosts only the in-flight-turn Live
/// Activity today — there are no Home Screen / Lock Screen widgets — but the bundle
/// is the standard place to add them later.
@main
struct JesseWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JesseTurnLiveActivity()
    }
}
