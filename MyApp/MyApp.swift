import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

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
