import SwiftUI

/// First-run: shows the settings form until a connection is configured.
/// Once configured, shows the client/project browsing UI.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        if !model.isConfigured {
            SettingsView()
        } else {
            BrowseRootView(showingSettings: $showingSettings)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
