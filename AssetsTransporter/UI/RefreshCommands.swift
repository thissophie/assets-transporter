import SwiftUI

extension FocusedValues {
    /// Reloads whatever the focused server window is showing (clients, the
    /// selected client's projects, and the open project's clips). Published
    /// by `BrowseRootView`; consumed by View ▸ Refresh on macOS.
    @Entry var refreshAction: (@MainActor () -> Void)?

    /// Opens the focused server window's upload queue. Published by
    /// `BrowseRootView`; consumed by View ▸ Uploads on macOS. The queue's
    /// status lives at the foot of the sidebar, so the menu is the way in
    /// when the sidebar is collapsed.
    @Entry var showUploadQueueAction: (@MainActor () -> Void)?
}

#if os(macOS)
/// View ▸ Refresh (⌘R) and View ▸ Uploads (⌘U): both forward to the focused
/// server window's published action, and both are disabled when no server
/// window is focused — the Servers library window is local-only, with nothing
/// remote to refresh and no queue of its own.
struct RefreshCommands: Commands {
    @FocusedValue(\.refreshAction) private var refreshAction
    @FocusedValue(\.showUploadQueueAction) private var showUploadQueueAction

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { refreshAction?() }
                .keyboardShortcut("r")
                .disabled(refreshAction == nil)
            Button("Uploads") { showUploadQueueAction?() }
                .keyboardShortcut("u")
                .disabled(showUploadQueueAction == nil)
        }
    }
}
#endif
