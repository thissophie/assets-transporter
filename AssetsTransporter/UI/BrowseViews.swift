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
    /// Bound purely to place the upload footer: the sidebar toggle writes the
    /// new visibility back here, and when the client column goes away the
    /// project column picks the footer up.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ClientListView(browse: browse,
                           selection: $selectedClientID,
                           showingUploadQueue: $showingUploadQueue,
                           onShowServers: onShowServers,
                           showsNewClientButton: sidebarOnScreen)
            // Narrower than this and the sidebar's titlebar can't fit the
            // New Client button beside the traffic lights and sidebar toggle,
            // so macOS pushes it into the window's trailing overflow menu.
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            Group {
                if let client = selectedClient {
                    ProjectListView(browse: browse, client: client,
                                    selection: $selectedProjectID,
                                    showingUploadQueue: $showingUploadQueue,
                                    showsUploadFooter: !clientColumnCarriesFooter)
                } else {
                    noClientSelected
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Without toolbar content this column gets no
                        // titlebar section of its own and the detail
                        // column's toolbar spills across it to the window's
                        // trailing edge, so stand in a disabled New Project.
                        .toolbar {
                            Button("New Project", systemImage: "folder.badge.plus") {}
                                .disabled(true)
                        }
                }
            }
            // Room for the "Client – Server" title beside the New Project
            // button without truncating it at ordinary name lengths.
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            Group {
                if let project = selectedProject {
                    ProjectDetailView(project: project, refreshTrigger: refreshTrigger)
                } else {
                    // Also keeps the detail column's toolbar section claimed,
                    // so the project column's New Project button doesn't
                    // drift to the window's trailing edge on macOS.
                    // Only prompts when there are projects to pick from; with
                    // no client, or a client with no projects, the column to
                    // its left already says what's missing.
                    NoProjectSelectedView(showsPlaceholder: selectedClientHasProjects)
                }
            }
            #if os(macOS)
            // The window title is the browsing context — which client, on
            // which server — with the open project as the subtitle beneath
            // it. It lives here because the detail column's title is the one
            // macOS puts in the titlebar, which is why `ProjectDetailView`
            // sets no title of its own on macOS.
            .navigationTitle(BrowseTitle.clientAndServer(client: selectedClient?.displayName,
                                                         serverName: session.profile.name))
            .navigationSubtitle(selectedProject?.manifest.displayName ?? "")
            #endif
        }
        // View ▸ Uploads (⌘U). The upload queue used to hang off a toolbar
        // button; now that its status lives at the foot of the sidebar, the
        // menu is what still opens the queue when the sidebar is collapsed.
        .focusedSceneValue(\.showUploadQueueAction) { showingUploadQueue = true }
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

    /// Whether the client column is the one showing the upload footer. The
    /// client list renders its footer whenever it's on screen — which in a
    /// collapsed stack includes being the stack's root — so only the project
    /// column needs to ask; it takes the footer over when this is false.
    private var clientColumnCarriesFooter: Bool {
        UploadActivity.clientColumnCarriesFooter(isCompact: isCompact,
                                                 columnVisibility: columnVisibility)
    }

    /// Whether the client list's toolbar belongs on screen. A collapsed
    /// sidebar on macOS/iPad leaves its New Client button stranded in the
    /// window toolbar, so it goes with the sidebar. In a compact stack the
    /// client list's toolbar only shows while the list itself does.
    private var sidebarOnScreen: Bool {
        isCompact || columnVisibility == .all
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var selectedClient: ClientRef? {
        selectedClientID.flatMap { id in browse.clients.first { $0.id == id } }
    }

    private var selectedProject: ProjectRef? {
        guard let clientPrefix = selectedClientID, let projectID = selectedProjectID else { return nil }
        return browse.projects(for: clientPrefix).first { $0.id == projectID }
    }

    private var selectedClientHasProjects: Bool {
        guard let client = selectedClient else { return false }
        return !browse.projects(for: client.prefix).isEmpty
    }

    /// The project column with no client picked. With no clients at all it
    /// stays blank while the client list is on screen to say so, and stands
    /// in with that list's "No clients yet" prompt when it isn't.
    @ViewBuilder private var noClientSelected: some View {
        if !browse.clients.isEmpty {
            ContentUnavailableView("No client selected", systemImage: "person.2",
                                   description: Text("Select a client to see its projects"))
        } else if clientColumnCarriesFooter {
            // i.e. the client list is on screen beside this column.
            Color.clear
        } else if browse.isLoading {
            ProgressView()
        } else {
            NoClientsYetView(browse: browse)
        }
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
    /// Off while the sidebar is collapsed; see `BrowseRootView.sidebarOnScreen`.
    var showsNewClientButton = true

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
            ServerNameHeader(name: session.profile.name)
            BrowseStatusHeader(browse: browse)
            list
            // Pinned below the list, Mail-style: present only while the queue
            // has something to report, and the way into the queue screen.
            if let summary = UploadActivity.summary(for: session.intake.active) {
                UploadActivityFooter(summary: summary) {
                    showingUploadQueue = true
                }
            }
        }
        .navigationTitle("Clients")
        .toolbar {
            if let onShowServers {
                ToolbarItem(placement: .navigation) {
                    Button("Servers", systemImage: "chevron.backward", action: onShowServers)
                }
            }
            if showsNewClientButton {
                ToolbarItem {
                    Button("New Client", systemImage: "rectangle.stack.badge.plus") {
                        newClientName = ""
                        showingNewClient = true
                    }
                    .disabled(browse.isMutating)
                }
            }
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
        .modifier(NewClientAlert(browse: browse, isPresented: $showingNewClient,
                                 name: $newClientName))
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
                NoClientsYetView(browse: browse)
            }
        } else {
            List(selection: $selection) {
                ForEach(browse.visibleClients) { client in
                    BrowseRow(title: client.displayName, subtitle: nil,
                              isBusy: previewingID == client.id,
                              uploadActivity: UploadActivity.rowActivity(session.intake.active,
                                                                         under: client.prefix))
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
    /// Shared with the client column: both can raise the one queue sheet
    /// `BrowseRootView` owns.
    @Binding var showingUploadQueue: Bool
    /// Set when the client column isn't on screen to carry its own footer —
    /// a collapsed sidebar on macOS/iPad, or a drilled-in stack on iPhone.
    var showsUploadFooter: Bool

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
            if showsUploadFooter,
               let summary = UploadActivity.summary(for: session.intake.active) {
                UploadActivityFooter(summary: summary) {
                    showingUploadQueue = true
                }
            }
        }
        // Matches the macOS window title; on iPad/iPhone this is the column's
        // own navigation bar title.
        .navigationTitle(BrowseTitle.clientAndServer(client: client.displayName,
                                                     serverName: session.profile.name))
        .toolbar {
            Button("New Project", systemImage: "folder.badge.plus") {
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
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "folder")
                    } actions: {
                        Button("Add Project") {
                            newProjectName = ""
                            showingNewProject = true
                        }
                        .disabled(browse.isMutating)
                    }
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
                              isBusy: previewingID == project.id,
                              uploadActivity: UploadActivity.rowActivity(session.intake.active,
                                                                         under: project.prefix))
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

/// The "New Client" name prompt, shared by the client column's toolbar button
/// and every "Add Client" empty state.
private struct NewClientAlert: ViewModifier {
    @Environment(ServerSession.self) private var session
    var browse: BrowseModel
    @Binding var isPresented: Bool
    @Binding var name: String

    func body(content: Content) -> some View {
        content.alert("New Client", isPresented: $isPresented) {
            TextField("Client name", text: $name)
            Button("Create") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { await browse.createClient(name: trimmed, writer: session.writer, reader: session.reader) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The empty-bucket prompt: shown by the client column, and by the project
/// column in its place when the sidebar is collapsed.
struct NoClientsYetView: View {
    @Environment(ServerSession.self) private var session
    var browse: BrowseModel

    @State private var showingNewClient = false
    @State private var newClientName = ""

    var body: some View {
        // In a ScrollView so pull-to-refresh is available from the empty
        // state — exactly where a failed or stale load needs a retry; a bare
        // ContentUnavailableView has no scroll surface.
        ScrollView {
            ContentUnavailableView {
                Label("No clients yet", systemImage: "person.2")
            } actions: {
                Button("Add Client") {
                    newClientName = ""
                    showingNewClient = true
                }
                .disabled(browse.isMutating)
            }
                .containerRelativeFrame([.horizontal, .vertical])
        }
        .refreshable { await browse.refreshClients(reader: session.reader) }
        .modifier(NewClientAlert(browse: browse, isPresented: $showingNewClient,
                                 name: $newClientName))
    }
}

/// Composes the browsing context title — "Client – Server" — used for the
/// macOS window title and the projects column. Either part can be missing
/// (no client picked yet, an unnamed server), so it degrades to whichever
/// half it has rather than leaving a stray dash.
nonisolated enum BrowseTitle {
    static func clientAndServer(client: String?, serverName: String?) -> String {
        [client, serverName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " – ")
    }
}

/// The open server's name, pinned above the client list, so the clients are
/// visibly *this* server's. The title says it too, but only in the titlebar
/// and only once a client is selected.
private struct ServerNameHeader: View {
    var name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server \(name)")
    }
}

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

/// Upload status pinned to the foot of the client list, shaped like Mail's
/// sync indicator: a thin bar over an action line and a detail line, the whole
/// block a button that opens the queue.
///
/// It exists only while `UploadActivity.summary` has something to report, so
/// the one moment the queue screen can't be reached from here is when it's
/// empty. When the sidebar is collapsed, View ▸ Uploads (⌘U) and the per-row
/// indicators take over.
private struct UploadActivityFooter: View {
    var summary: UploadActivity.Summary
    var action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                VStack(spacing: 3) {
                    bar
                    Text(summary.title)
                        .font(.footnote)
                        .foregroundStyle(summary.isStalled ? AnyShapeStyle(.red)
                                                           : AnyShapeStyle(.primary))
                    if let detail = summary.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([summary.title, summary.detail].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Opens the upload queue")
        .accessibilityAddTraits(.isButton)
    }

    /// Determinate while a clip is on the wire, indeterminate while the queue
    /// is only waiting, and absent when nothing will move without the user —
    /// an animating bar over a parked failure would be a lie.
    @ViewBuilder private var bar: some View {
        if let progress = summary.progress {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        } else if !summary.isStalled {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }
}

/// One browse row: title, optional secondary line, and (on iOS) a trailing
/// chevron. macOS sidebar/list rows conventionally have no chevron.
/// `isBusy` shows a small trailing spinner (deletion-preview fetch);
/// `uploadActivity` shows the upload-in-progress ring for this row's subtree.
private struct BrowseRow: View {
    var title: String
    var subtitle: String?
    var isBusy: Bool = false
    var uploadActivity: UploadActivity.RowActivity? = nil

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
            if isBusy || uploadActivity != nil {
                Spacer()
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            if let uploadActivity {
                UploadActivityRing(activity: uploadActivity)
            }
            #if os(iOS)
            if !isBusy, uploadActivity == nil { Spacer() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)   // purely decorative
            #endif
        }
        .contentShape(Rectangle())
    }
}

/// "Uploads are landing under here": the trailing accessory on a client or
/// project row whose subtree has work in flight. This is what keeps upload
/// activity visible when the sidebar — and with it the footer — is collapsed.
///
/// Drawn by hand rather than with `ProgressView(value:).progressViewStyle(.circular)`
/// so the determinate ring renders identically on macOS and iOS; the queued
/// case (no clip on the wire yet) falls back to the system spinner, since
/// there is no fraction to draw.
private struct UploadActivityRing: View {
    var activity: UploadActivity.RowActivity

    var body: some View {
        Group {
            if let fraction = activity.fraction {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 2)
                    Circle()
                        // A floor of 2% so a just-started upload still reads
                        // as a ring rather than an empty circle.
                        .trim(from: 0, to: max(0.02, min(fraction, 1)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))   // start at 12 o'clock
                }
                .frame(width: 14, height: 14)
                .animation(.easeInOut(duration: 0.2), value: fraction)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityLabel(activity.accessibilityLabel)
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
