import SwiftUI

/// Client/project browsing (Task 5.2).
///
/// Layout: a three-column `NavigationSplitView` (clients → projects → project
/// detail) on all platforms. On iPhone the split view automatically
/// collapses into a navigation-stack presentation, so no size-class branching
/// is needed — one hierarchy serves macOS, iPad, and iPhone.
struct BrowseRootView: View {
    @Environment(ServerSession.self) private var session
    /// iOS: navigates back to the server list. nil on macOS, where the
    /// Servers window is always reachable from the Window menu.
    var onShowServers: (() -> Void)? = nil

    @State private var browse = BrowseModel()
    @State private var selectedClientID: ClientRef.ID?
    @State private var selectedProjectID: ProjectRef.ID?
    @State private var showingUploadQueue = false
    /// Bumped by the published refresh action; `ProjectDetailView` reloads
    /// its clip list whenever it changes.
    @State private var refreshTrigger = 0

    var body: some View {
        NavigationSplitView {
            ClientListView(browse: browse,
                           selection: $selectedClientID,
                           showingUploadQueue: $showingUploadQueue,
                           onShowServers: onShowServers)
        } content: {
            if let client = selectedClient {
                ProjectListView(browse: browse, client: client,
                                selection: $selectedProjectID)
            } else {
                Text("Select a client")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            Group {
                if let project = selectedProject {
                    ProjectDetailView(project: project, refreshTrigger: refreshTrigger)
                } else {
                    Text("Select a project")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            #if os(macOS)
            // The upload queue is server-wide, not per client, so on macOS it
            // lives in the main content area's toolbar rather than the sidebar.
            .toolbar {
                ToolbarItem {
                    UploadQueueButton(activeCount: session.intake.active.count) {
                        showingUploadQueue = true
                    }
                }
            }
            #endif
        }
        .task(id: session.profile.settings) {
            // Re-runs when the server's connection settings are edited, so
            // the list reflects the new bucket without a manual refresh.
            await browse.refreshClients(reader: session.reader)
        }
        .focusedSceneValue(\.refreshAction, refreshVisible)
        .onChange(of: selectedClientID) {
            selectedProjectID = nil
        }
        .sheet(isPresented: $showingUploadQueue) {
            UploadQueueView()
        }
    }

    private var selectedClient: ClientRef? {
        selectedClientID.flatMap { id in browse.clients.first { $0.id == id } }
    }

    private var selectedProject: ProjectRef? {
        guard let clientPrefix = selectedClientID, let projectID = selectedProjectID else { return nil }
        return browse.projects(for: clientPrefix).first { $0.id == projectID }
    }

    /// View ▸ Refresh: reloads every level this window is showing — the
    /// client list, the selected client's projects, and (via the trigger)
    /// the open project's clip list.
    private func refreshVisible() {
        refreshTrigger += 1
        Task {
            await browse.refreshClients(reader: session.reader)
            if let client = selectedClient {
                await browse.refreshProjects(reader: session.reader, clientPrefix: client.prefix)
            }
        }
    }
}

// MARK: - Clients column

struct ClientListView: View {
    @Environment(ServerSession.self) private var session
    var browse: BrowseModel
    @Binding var selection: ClientRef.ID?
    @Binding var showingUploadQueue: Bool
    var onShowServers: (() -> Void)? = nil

    @State private var showingNewClient = false
    @State private var newClientName = ""
    @State private var renameTarget: ClientRef?
    @State private var renameText = ""
    @State private var deletionPrompt: DeletionPrompt?
    /// Row whose deletion preview is being fetched (tiny loading state).
    @State private var previewingID: ClientRef.ID?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            BrowseStatusHeader(browse: browse)
            list
        }
        .navigationTitle("Clients")
        .toolbar {
            if let onShowServers {
                ToolbarItem(placement: .navigation) {
                    Button("Servers", systemImage: "chevron.backward", action: onShowServers)
                }
            }
            ToolbarItem {
                Button("New Client", systemImage: "plus") {
                    newClientName = ""
                    showingNewClient = true
                }
                .disabled(browse.isMutating)
            }
            #if os(iOS)
            ToolbarItem {
                UploadQueueButton(activeCount: session.intake.active.count) {
                    showingUploadQueue = true
                }
            }
            #endif
        }
        .onDisappear { previewTask?.cancel() }
        .confirmationDialog("Delete “\(deletionPrompt?.name ?? "")”?",
                            isPresented: deletionPromptPresented,
                            titleVisibility: .visible,
                            presenting: deletionPrompt) { prompt in
            Button("Delete", role: .destructive) { performDelete(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            DeletionPromptMessage(prompt: prompt)
        }
        .alert("New Client", isPresented: $showingNewClient) {
            TextField("Client name", text: $newClientName)
            Button("Create") {
                let name = newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await browse.createClient(name: name, writer: session.writer, reader: session.reader) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Client", isPresented: renameAlertPresented, presenting: renameTarget) { client in
            TextField("Client name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await browse.renameClient(client, to: name, writer: session.writer, reader: session.reader) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var list: some View {
        if browse.clients.isEmpty {
            if browse.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // In a ScrollView so pull-to-refresh is available from the
                // empty state — exactly where a failed or stale load needs a
                // retry; a bare ContentUnavailableView has no scroll surface.
                ScrollView {
                    ContentUnavailableView("No clients yet",
                                           systemImage: "person.2",
                                           description: Text("Tap + to create one"))
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await refresh() }
            }
        } else {
            List(selection: $selection) {
                ForEach(browse.visibleClients) { client in
                    BrowseRow(title: client.displayName, subtitle: nil,
                              isBusy: previewingID == client.id)
                        .opacity(client.isHidden ? 0.5 : 1)
                        .tag(client.id)
                        .contextMenu {
                            Button("Rename") { beginRename(client) }
                                .disabled(browse.isMutating)
                            Button(client.isHidden ? "Unhide" : "Hide") { toggleHidden(client) }
                                .disabled(browse.isMutating)
                            Button("Delete…", role: .destructive) { beginDelete(client) }
                                .disabled(deletionDisabled)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete…", role: .destructive) { beginDelete(client) }
                                .disabled(deletionDisabled)
                            Button("Rename") { beginRename(client) }
                                .disabled(browse.isMutating)
                        }
                }
                if browse.hiddenClientCount > 0 {
                    Button(browse.showHiddenClients
                           ? "Hide Hidden Clients"
                           : "Show ^[\(browse.hiddenClientCount) Hidden Client](inflect: true)") {
                        browse.showHiddenClients.toggle()
                        // Collapsing the hidden rows shouldn't leave one
                        // invisibly selected.
                        if !browse.showHiddenClients, isSelectionHidden {
                            selection = nil
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                }
            }
            .refreshable { await refresh() }
        }
    }

    private var isSelectionHidden: Bool {
        browse.clients.contains { $0.id == selection && $0.isHidden }
    }

    private func toggleHidden(_ client: ClientRef) {
        Task {
            await browse.setClientHidden(client, hidden: !client.isHidden,
                                         writer: session.writer, reader: session.reader)
            // Hiding the selected client removes its row (unless hidden rows
            // are shown), so drop the selection with it.
            if !browse.showHiddenClients, isSelectionHidden {
                selection = nil
            }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var deletionPromptPresented: Binding<Bool> {
        Binding(get: { deletionPrompt != nil },
                set: { if !$0 { deletionPrompt = nil } })
    }

    private var deletionDisabled: Bool {
        browse.isMutating || previewingID != nil
    }

    private func beginRename(_ client: ClientRef) {
        renameText = client.displayName
        renameTarget = client
    }

    /// Fetches what deleting this client would remove, then raises the
    /// confirmation dialog. The fetch is cancellable (superseded request or
    /// view teardown) and its row shows a small spinner while it runs.
    private func beginDelete(_ client: ClientRef) {
        let writer = session.writer
        previewTask?.cancel()
        previewingID = client.id
        previewTask = Task {
            defer { if previewingID == client.id { previewingID = nil } }
            do {
                let preview = try await writer.deletionPreview(prefix: client.prefix)
                guard !Task.isCancelled else { return }
                deletionPrompt = DeletionPrompt(name: client.displayName,
                                                prefix: client.prefix,
                                                preview: preview)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                browse.lastError = "Could not check what deleting would remove: \(ErrorText.describe(error))"
            }
        }
    }

    private func performDelete(_ prompt: DeletionPrompt) {
        Task {
            await browse.deleteClient(prefix: prompt.prefix,
                                      writer: session.writer, reader: session.reader)
            // Deleting the selected client clears the selection — unless the
            // delete failed and the client survived the refresh.
            if selection == prompt.prefix,
               !browse.clients.contains(where: { $0.id == prompt.prefix }) {
                selection = nil
            }
        }
    }

    private func refresh() async {
        await browse.refreshClients(reader: session.reader)
    }
}

// MARK: - Projects column

struct ProjectListView: View {
    @Environment(ServerSession.self) private var session
    var browse: BrowseModel
    var client: ClientRef
    @Binding var selection: ProjectRef.ID?

    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var renameTarget: ProjectRef?
    @State private var renameText = ""
    @State private var deletionPrompt: DeletionPrompt?
    /// Row whose deletion preview is being fetched (tiny loading state).
    @State private var previewingID: ProjectRef.ID?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            BrowseStatusHeader(browse: browse)
            list
        }
        .navigationTitle(client.displayName)
        .toolbar {
            Button("New Project", systemImage: "plus") {
                newProjectName = ""
                showingNewProject = true
            }
            .disabled(browse.isMutating)
        }
        .task(id: client.prefix) {
            await refresh()
        }
        .onDisappear { previewTask?.cancel() }
        .confirmationDialog("Delete “\(deletionPrompt?.name ?? "")”?",
                            isPresented: deletionPromptPresented,
                            titleVisibility: .visible,
                            presenting: deletionPrompt) { prompt in
            Button("Delete", role: .destructive) { performDelete(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            DeletionPromptMessage(prompt: prompt)
        }
        .alert("New Project", isPresented: $showingNewProject) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    await browse.createProject(name: name, in: client.prefix,
                                               writer: session.writer, reader: session.reader)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Project", isPresented: renameAlertPresented, presenting: renameTarget) { project in
            TextField("Project name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    await browse.renameProject(project, to: name, in: client.prefix,
                                               writer: session.writer, reader: session.reader)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var projects: [ProjectRef] { browse.projects(for: client.prefix) }

    @ViewBuilder private var list: some View {
        if projects.isEmpty {
            if browse.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Same shape as the empty client list: scrollable so a failed
                // or stale load can be retried by pulling down.
                ScrollView {
                    ContentUnavailableView("No projects yet",
                                           systemImage: "folder",
                                           description: Text("Tap + to create one"))
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await refresh() }
            }
        } else {
            List(selection: $selection) {
                ForEach(projects) { project in
                    BrowseRow(title: project.manifest.displayName,
                              subtitle: project.manifest.createdAt
                                  .formatted(.dateTime.year().month().day()),
                              isBusy: previewingID == project.id)
                        .tag(project.id)
                        .contextMenu {
                            Button("Rename") { beginRename(project) }
                                .disabled(browse.isMutating)
                            Button("Delete…", role: .destructive) { beginDelete(project) }
                                .disabled(deletionDisabled)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete…", role: .destructive) { beginDelete(project) }
                                .disabled(deletionDisabled)
                            Button("Rename") { beginRename(project) }
                                .disabled(browse.isMutating)
                        }
                }
                // Drag-to-reorder uses legacy `onMove`, NOT the modern
                // `reorderable()`/`reorderContainer` API: on macOS 27 the
                // reorder modifiers block List selection entirely (clicks,
                // double-clicks, and keyboard selection all stop working —
                // verified by XCUITest against the real app), even though the
                // documentation shows them combined with `List(selection:)`.
                // `onMove` coexists with selection on both platforms and
                // natively provides the (IndexSet, Int) that
                // `BrowseModel.moveProjects` consumes. On iOS it reorders via
                // long-press drag on a row.
                .onMove { from, to in
                    moveRows(from: from, to: to)
                }
                .moveDisabled(browse.isMutating)
            }
            .refreshable { await refresh() }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var deletionPromptPresented: Binding<Bool> {
        Binding(get: { deletionPrompt != nil },
                set: { if !$0 { deletionPrompt = nil } })
    }

    private var deletionDisabled: Bool {
        browse.isMutating || previewingID != nil
    }

    private func beginRename(_ project: ProjectRef) {
        renameText = project.manifest.displayName
        renameTarget = project
    }

    /// Fetches what deleting this project would remove, then raises the
    /// confirmation dialog. See `ClientListView.beginDelete` for the shape.
    private func beginDelete(_ project: ProjectRef) {
        let writer = session.writer
        previewTask?.cancel()
        previewingID = project.id
        previewTask = Task {
            defer { if previewingID == project.id { previewingID = nil } }
            do {
                let preview = try await writer.deletionPreview(prefix: project.prefix)
                guard !Task.isCancelled else { return }
                deletionPrompt = DeletionPrompt(name: project.manifest.displayName,
                                                prefix: project.prefix,
                                                preview: preview)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                browse.lastError = "Could not check what deleting would remove: \(ErrorText.describe(error))"
            }
        }
    }

    private func performDelete(_ prompt: DeletionPrompt) {
        Task {
            await browse.deleteProject(prefix: prompt.prefix, in: client.prefix,
                                       writer: session.writer, reader: session.reader)
            // Deleting the selected project clears the selection — unless the
            // delete failed and the project survived the refresh.
            if selection == prompt.prefix,
               !projects.contains(where: { $0.id == prompt.prefix }) {
                selection = nil
            }
        }
    }

    private func refresh() async {
        await browse.refreshProjects(reader: session.reader, clientPrefix: client.prefix)
    }

    /// Hands an `onMove` reorder to the model (optimistic local move, then
    /// sortIndex writes, then refresh).
    private func moveRows(from: IndexSet, to: Int) {
        guard !browse.isMutating else { return }
        Task {
            await browse.moveProjects(in: client.prefix, from: from, to: to,
                                      writer: session.writer, reader: session.reader)
        }
    }
}

// MARK: - Shared pieces

/// A prefix deletion awaiting user confirmation: display name, the prefix to
/// delete, and the fetched preview of what that would remove.
private struct DeletionPrompt {
    var name: String
    var prefix: String
    var preview: DeletionPreview
}

/// Confirmation-dialog body: raw object count (clips *and* their sidecars and
/// the manifest — hence "files", not "clips") plus the total size.
private struct DeletionPromptMessage: View {
    var prompt: DeletionPrompt

    var body: some View {
        Text("This will permanently delete ^[\(prompt.preview.objectCount) file](inflect: true) (\(prompt.preview.totalBytes.formatted(.byteCount(style: .file)))). This cannot be undone.")
    }
}

/// Toolbar entry to the upload queue, with a count badge while uploads are
/// active (waiting/uploading/failed — anything still needing attention).
private struct UploadQueueButton: View {
    var activeCount: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Uploads", systemImage: "arrow.up.circle")
                .overlay(alignment: .topTrailing) {
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
        }
        // The visual badge is a tiny overlay; give assistive tech the count
        // as part of the button's name instead.
        .accessibilityLabel(activeCount > 0 ? "Uploads, \(activeCount) active" : "Uploads")
    }
}

/// One browse row: title, optional secondary line, and (on iOS) a trailing
/// chevron. macOS sidebar/list rows conventionally have no chevron.
/// `isBusy` shows a small trailing spinner (deletion-preview fetch).
private struct BrowseRow: View {
    var title: String
    var subtitle: String?
    var isBusy: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isBusy {
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            #if os(iOS)
            if !isBusy { Spacer() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)   // purely decorative
            #endif
        }
        .contentShape(Rectangle())
    }
}

/// Offline banner plus a dismissible one-shot error line, shown above lists.
struct BrowseStatusHeader: View {
    @Bindable var browse: BrowseModel

    var body: some View {
        VStack(spacing: 0) {
            if browse.isOffline {
                Text("Showing cached data — last refresh failed")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.25))
            }
            if let error = browse.lastError {
                HStack(alignment: .firstTextBaseline) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark.circle.fill") {
                        browse.lastError = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

#Preview("Browse (placeholder server, unreachable endpoint)") {
    BrowseRootView()
        .environment(ServerSession.preview())
        .environment(AppModel())
}
