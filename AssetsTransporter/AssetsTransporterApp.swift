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

/// Scenes. macOS behaves like a multi-document app: the "Servers" window is
/// the library, and each server opens in its own window (a `WindowGroup`
/// keyed by profile id, so opening the same server again just raises its
/// window). Window state restoration brings the open servers back on
/// relaunch. iOS is single-scene: `ContentView` swaps between the list and
/// the chosen server.
@main struct AssetsTransporterApp: App {
    @State private var model = AppModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    static let serversWindowID = "servers"
    static let serverWindowID = "server"

    var body: some Scene {
        #if os(macOS)
        Window("Servers", id: Self.serversWindowID) {
            ServerListView()
                .environment(model)
        }
        .defaultSize(width: 420, height: 320)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Server…") {
                    model.presentNewServerEditor = true
                    openWindow(id: Self.serversWindowID)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(before: .windowList) {
                Button("Servers") { openWindow(id: Self.serversWindowID) }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            RefreshCommands()
        }

        WindowGroup(id: Self.serverWindowID, for: ServerProfile.ID.self) { $serverID in
            if let serverID {
                ServerWindowView(serverID: serverID)
                    .environment(model)
            } else {
                // Only reachable through state restoration of a window that
                // never got a value; there's nothing to show for it.
                ContentUnavailableView("No server selected", systemImage: "server.rack",
                                       description: Text("Choose a server from the Servers window."))
                    .environment(model)
            }
        }
        .defaultSize(width: 800, height: 640)
        #else
        WindowGroup {
            ContentView()
                .environment(model)
        }
        #endif
    }

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
}
