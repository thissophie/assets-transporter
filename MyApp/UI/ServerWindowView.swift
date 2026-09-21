import SwiftUI

/// Root of one server's window (macOS) or the in-place server screen (iOS):
/// resolves the session for `serverID`, injects it into the environment, and
/// hosts the browse UI under the server's name. A window restored for a
/// server that has since been deleted shows a placeholder instead.
struct ServerWindowView: View {
    @Environment(AppModel.self) private var app
    var serverID: ServerProfile.ID
    /// iOS: navigates back to the server list. nil on macOS.
    var onShowServers: (() -> Void)? = nil

    var body: some View {
        // `server(id:)` is observed (it reads `servers`), so deleting the
        // server swaps this to the placeholder; `session(for:)` then only
        // creates when the profile still exists.
        if app.server(id: serverID) != nil, let session = app.session(for: serverID) {
            BrowseRootView(onShowServers: onShowServers)
                .environment(session)
                .navigationTitle(session.profile.name)
        } else {
            ContentUnavailableView {
                Label("Server Removed", systemImage: "server.rack")
            } description: {
                Text("This server is no longer in your list.")
            } actions: {
                if let onShowServers {
                    Button("Show Servers", action: onShowServers)
                }
            }
        }
    }
}
