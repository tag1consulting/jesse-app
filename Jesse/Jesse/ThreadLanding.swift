import Foundation
import SwiftData
import JesseCore

// WHERE A CONVERSATION OPENED FROM OUTSIDE THE CHATS TAB LANDS.
//
// Four things open a conversation without the user having asked the Chats tab for it:
// a tapped notification, a Siri or voice request, the hands-free wake capture, and a
// recording arriving from the share sheet. All four converge on `ContentView`'s
// navigation path, and all four used to write that path alone.
//
// Writing the path alone is what broke: the pushed `ThreadDetailView` hides the root
// TabView's bar (`.toolbar(.hidden, for: .tabBar)`), and it hides it for the whole
// shell, not for one tab. Push a conversation while the user is looking at Today and
// the bar goes away under a tab that shows no conversation — no way to reach the thread
// that was just opened, no back swipe to undo it, and a force quit as the only recovery.
//
// So the landing is a PAIR of writes, never one: select Chats, then push. Kept here,
// out of the view, because "which tab a landing selects" is a decision worth a test, and
// a `@State`/`@Binding` pair inside a SwiftUI view is not drivable from one.
enum ThreadLanding {
    /// Land on `thread`: select Chats, then push it.
    ///
    /// ORDER IS PART OF THE CONTRACT. The tab is selected FIRST so the push lands on a
    /// tab that is already the visible one; the detail view can then hide the tab bar
    /// with the user looking straight at the screen that owns the back swipe.
    static func apply(thread: JesseThread,
                      selection: inout RootTabView.Tab,
                      path: inout [JesseThread]) {
        selection = .chats
        path = [thread]
    }
}
