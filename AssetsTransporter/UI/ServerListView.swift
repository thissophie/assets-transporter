import SwiftUI

/// The server library: every saved server, with open / add / edit / delete.
/// On macOS this is the "Servers" window and opening a server opens (or
/// raises) that server's own window; on iOS the owner supplies `onOpen` and
/// navigates in place.
struct ServerListView: View {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// iOS: how to show a server. Ignored on macOS (windows are opened
    /// through the environment instead).
    var onOpen: ((ServerProfile.ID) -> Void)? = nil

    @State private var selection: ServerProfile.ID?
    @State private var editorTarget: EditorTarget?
    @State private var deleteTarget: ServerProfile?

    var body: some View {
        @Bindable var app = app
        Group {
            if app.servers.isEmpty {
                ContentUnavailableView {
                    Label("No servers yet", systemImage: "server.rack")
                } description: {
                    Text("Add a server to browse and upload video.")
                } actions: {
                    Button("Add Server…") { editorTarget = .new }
                }
            } else {
                list
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button("Open", systemImage: "arrow.up.forward.square") {
                    if let selection { open(selection) }
                }
                .disabled(selection == nil)
            }
            #endif
            ToolbarItem {
                Button("New Server", systemImage: "plus") { editorTarget = .new }
            }
        }
        .sheet(item: $editorTarget) { target in
            ServerEditorView(existing: target.profile)
        }
        .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                            isPresented: deletePromptPresented,
                            titleVisibility: .visible,
                            presenting: deleteTarget) { profile in
            Button("Delete Server", role: .destructive) { performDelete(profile) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the saved connection and its local upload queue. Nothing in the bucket is deleted.")
        }
        .onChange(of: app.presentNewServerEditor, initial: true) {
            if app.presentNewServerEditor {
                editorTarget = .new
                app.presentNewServerEditor = false
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 240)
        #endif
    }

    private var list: some View {
        List(selection: $selection) {
            if let configError = app.configError {
                Text(configError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(app.servers) { profile in
                HStack {
                    ServerRow(profile: profile, status: status(for: profile))
                    Spacer()
                    // Inline entry to the editor so it's discoverable without
                    // knowing about the context menu or swipe actions.
                    Button("Edit “\(profile.name)”…", systemImage: "info.circle") {
                        editorTarget = .edit(profile)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                    .tag(profile.id)
                    .swipeActions(edge: .trailing) {
                        Button("Delete…", role: .destructive) { deleteTarget = profile }
                            .disabled(isUploading(profile))
                        Button("Edit…") { editorTarget = .edit(profile) }
                    }
            }
            .onMove { from, to in
                try? app.move(fromOffsets: from, toOffset: to)
            }
        }
        // Double-click (macOS) / tap (iOS) opens; right-click gets the menu.
        .contextMenu(forSelectionType: ServerProfile.ID.self) { ids in
            if let id = ids.first, let profile = app.server(id: id) {
                Button("Open") { open(id) }
                Button("Edit…") { editorTarget = .edit(profile) }
                Divider()
                Button("Delete…", role: .destructive) { deleteTarget = profile }
                    .disabled(isUploading(profile))
            }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
    }

    // MARK: - Actions

    private func open(_ id: ServerProfile.ID) {
        #if os(macOS)
        openWindow(id: MyApp.serverWindowID, value: id)
        #else
        onOpen?(id)
        #endif
    }

    private func performDelete(_ profile: ServerProfile) {
        do {
            try app.remove(id: profile.id)
            if selection == profile.id { selection = nil }
        } catch {
            app.configError = "Could not delete the server: \(ErrorText.describe(error))"
        }
    }

    private func isUploading(_ profile: ServerProfile) -> Bool {
        app.existingSession(for: profile.id)?.isUploading ?? false
    }

    /// Live activity line for servers with a running session: uploads in
    /// progress and (macOS) an armed watched folder.
    private func status(for profile: ServerProfile) -> String? {
        guard let session = app.existingSession(for: profile.id) else { return nil }
        var parts: [String] = []
        let active = session.intake.active.count
        if active > 0 { parts.append("\(active) upload\(active == 1 ? "" : "s") active") }
        #if os(macOS)
        if session.watch.activeConfig != nil { parts.append("Watching a folder") }
        #endif
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var deletePromptPresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    /// What the editor sheet is for — a fresh server or an existing one.
    private enum EditorTarget: Identifiable {
        case new
        case edit(ServerProfile)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let profile): profile.id.uuidString
            }
        }

        var profile: ServerProfile? {
            if case .edit(let profile) = self { return profile }
            return nil
        }
    }
}

private struct ServerRow: View {
    var profile: ServerProfile
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.name)
            Text(profile.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        ServerListView()
    }
    .environment(AppModel())
}
