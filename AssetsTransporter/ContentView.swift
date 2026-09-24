import SwiftUI

/// iOS root: the server list, or — once a server is chosen — that server's
/// browse UI in place. The choice is remembered across launches so a phone
/// with one server lands straight in it. (macOS uses separate scenes; see
/// `AssetsTransporterApp`.)
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("openServerID") private var openServerIDString = ""

    var body: some View {
        if let id = openServerID, app.server(id: id) != nil {
            ServerWindowView(serverID: id) { openServerIDString = "" }
        } else {
            NavigationStack {
                ServerListView { id in openServerIDString = id.uuidString }
            }
        }
    }

    private var openServerID: ServerProfile.ID? {
        UUID(uuidString: openServerIDString)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
