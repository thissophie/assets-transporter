import SwiftUI

extension FocusedValues {
    /// Reloads whatever the focused server window is showing (clients, the
    /// selected client's projects, and the open project's clips). Published
    /// by `BrowseRootView`; consumed by View ▸ Refresh on macOS.
    @Entry var refreshAction: (@MainActor () -> Void)?
}

#if os(macOS)
/// View ▸ Refresh (⌘R): forwards to the focused server window's published
/// refresh action. Disabled when no server window is focused — the Servers
/// library window is local-only and has nothing remote to refresh.
struct RefreshCommands: Commands {
    @FocusedValue(\.refreshAction) private var refreshAction

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { refreshAction?() }
                .keyboardShortcut("r")
                .disabled(refreshAction == nil)
        }
    }
}
#endif
