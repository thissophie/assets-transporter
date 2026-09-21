import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Installs the UIKit hook the background URLSession relaunch path needs:
/// when uploads finish while the app is dead, the system relaunches it and
/// delivers the session's completion handler here. Storing it on
/// `BackgroundTransport.shared` (whose init recreates the session for the
/// matching identifier) lets `urlSessionDidFinishEvents` call it once all
/// queued delegate events have been delivered.
///
/// Not behaviorally testable in CI — the flow requires the system to kill
/// and relaunch the app for a background session — so this is build-verified
/// and exercised manually.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransport.sessionIdentifier else {
            // Not our session: nothing will ever drain its events, so tell
            // the system we're done immediately instead of leaving it waiting.
            completionHandler()
            return
        }
        // Touching .shared also recreates the background session, so the
        // pending delegate events have somewhere to land.
        BackgroundTransport.shared.backgroundCompletionHandler = completionHandler
    }
}
#endif

@main struct MyApp: App {
    @State private var model = AppModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
        }
        #endif
    }
}
