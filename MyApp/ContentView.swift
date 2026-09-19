import SwiftUI

/// First-run: shows the settings form until a connection is configured.
/// Once configured, shows a placeholder that Task 5.2 replaces with the
/// browsing UI.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        if !model.isConfigured {
            SettingsView()
        } else {
            NavigationStack {
                // Placeholder — replaced by the browsing UI in Task 5.2.
                Text("Configured — browsing UI arrives in Task 5.2")
                    .padding()
                    .toolbar {
                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                    }
            }
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
