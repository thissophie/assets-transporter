import SwiftUI

/// Client/project browsing (Task 5.2).
///
/// Layout: a three-column `NavigationSplitView` (clients → projects → detail
/// placeholder) on all platforms. On iPhone the split view automatically
/// collapses into a navigation-stack presentation, so no size-class branching
/// is needed — one hierarchy serves macOS, iPad, and iPhone.
struct BrowseRootView: View {
    @Environment(AppModel.self) private var app
    @Binding var showingSettings: Bool

    @State private var browse = BrowseModel()
    @State private var selectedClientID: ClientRef.ID?
    @State private var selectedProjectID: ProjectRef.ID?

    var body: some View {
        NavigationSplitView {
            ClientListView(browse: browse,
                           selection: $selectedClientID,
                           showingSettings: $showingSettings)
        } content: {
            if let client = selectedClient {
                ProjectListView(browse: browse, client: client,
                                selection: $selectedProjectID)
            } else {
                Text("Select a client")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            if let project = selectedProject {
                ProjectPlaceholderView(project: project)
            } else {
                Text("Select a project — clips arrive in Task 5.3")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .task {
            guard let reader = app.reader else { return }
            await browse.refreshClients(reader: reader)
        }
        .onChange(of: selectedClientID) {
            selectedProjectID = nil
        }
    }

    private var selectedClient: ClientRef? {
        selectedClientID.flatMap { id in browse.clients.first { $0.id == id } }
    }

    private var selectedProject: ProjectRef? {
        guard let clientPrefix = selectedClientID, let projectID = selectedProjectID else { return nil }
        return browse.projects(for: clientPrefix).first { $0.id == projectID }
    }
}

// MARK: - Clients column

struct ClientListView: View {
    @Environment(AppModel.self) private var app
    var browse: BrowseModel
    @Binding var selection: ClientRef.ID?
    @Binding var showingSettings: Bool

    @State private var showingNewClient = false
    @State private var newClientName = ""
    @State private var renameTarget: ClientRef?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            BrowseStatusHeader(browse: browse)
            list
        }
        .navigationTitle("Clients")
        .toolbar {
            #if os(macOS)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .disabled(browse.isLoading)
            #endif
            Button("New Client", systemImage: "plus") {
                newClientName = ""
                showingNewClient = true
            }
            .disabled(browse.isMutating || app.writer == nil)
            Button("Settings", systemImage: "gearshape") {
                showingSettings = true
            }
        }
        .alert("New Client", isPresented: $showingNewClient) {
            TextField("Client name", text: $newClientName)
            Button("Create") {
                let name = newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let writer = app.writer, let reader = app.reader else { return }
                Task { await browse.createClient(name: name, writer: writer, reader: reader) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Client", isPresented: renameAlertPresented, presenting: renameTarget) { client in
            TextField("Client name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let writer = app.writer, let reader = app.reader else { return }
                Task { await browse.renameClient(client, to: name, writer: writer, reader: reader) }
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
                ContentUnavailableView("No clients yet",
                                       systemImage: "person.2",
                                       description: Text("Tap + to create one"))
            }
        } else {
            List(selection: $selection) {
                ForEach(browse.clients) { client in
                    BrowseRow(title: client.displayName, subtitle: nil)
                        .tag(client.id)
                        .contextMenu {
                            Button("Rename") { beginRename(client) }
                                .disabled(browse.isMutating)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Rename") { beginRename(client) }
                                .disabled(browse.isMutating)
                        }
                }
            }
            .refreshable { await refresh() }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private func beginRename(_ client: ClientRef) {
        renameText = client.displayName
        renameTarget = client
    }

    private func refresh() async {
        guard let reader = app.reader else { return }
        await browse.refreshClients(reader: reader)
    }
}

// MARK: - Projects column

struct ProjectListView: View {
    @Environment(AppModel.self) private var app
    var browse: BrowseModel
    var client: ClientRef
    @Binding var selection: ProjectRef.ID?

    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var renameTarget: ProjectRef?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            BrowseStatusHeader(browse: browse)
            list
        }
        .navigationTitle(client.displayName)
        .toolbar {
            #if os(macOS)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .disabled(browse.isLoading)
            #endif
            Button("New Project", systemImage: "plus") {
                newProjectName = ""
                showingNewProject = true
            }
            .disabled(browse.isMutating || app.writer == nil)
        }
        .task(id: client.prefix) {
            await refresh()
        }
        .alert("New Project", isPresented: $showingNewProject) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let writer = app.writer, let reader = app.reader else { return }
                Task {
                    await browse.createProject(name: name, in: client.prefix,
                                               writer: writer, reader: reader)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Project", isPresented: renameAlertPresented, presenting: renameTarget) { project in
            TextField("Project name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let writer = app.writer, let reader = app.reader else { return }
                Task {
                    await browse.renameProject(project, to: name, in: client.prefix,
                                               writer: writer, reader: reader)
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
                ContentUnavailableView("No projects yet",
                                       systemImage: "folder",
                                       description: Text("Tap + to create one"))
            }
        } else {
            List(selection: $selection) {
                ForEach(projects) { project in
                    BrowseRow(title: project.manifest.displayName,
                              subtitle: project.manifest.createdAt
                                  .formatted(.dateTime.year().month().day()))
                        .tag(project.id)
                        .contextMenu {
                            Button("Rename") { beginRename(project) }
                                .disabled(browse.isMutating)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Rename") { beginRename(project) }
                                .disabled(browse.isMutating)
                        }
                }
                .reorderable()
            }
            .reorderContainer(for: ProjectRef.self, isEnabled: !browse.isMutating) { difference in
                applyReorder(difference)
            }
            .refreshable { await refresh() }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private func beginRename(_ project: ProjectRef) {
        renameText = project.manifest.displayName
        renameTarget = project
    }

    private func refresh() async {
        guard let reader = app.reader else { return }
        await browse.refreshProjects(reader: reader, clientPrefix: client.prefix)
    }

    /// Translates the reorder difference into `move(fromOffsets:toOffset:)`
    /// coordinates (offsets in the pre-removal array) and hands it to the model.
    private func applyReorder(
        _ difference: ReorderDifference<ProjectRef.ID, ReorderableSingleCollectionIdentifier>
    ) {
        let current = projects
        var from = IndexSet()
        for id in difference.sources {
            if let index = current.firstIndex(where: { $0.id == id }) {
                from.insert(index)
            }
        }
        guard !from.isEmpty else { return }
        let to: Int
        switch difference.destination.position {
        case .before(let targetID):
            to = current.firstIndex(where: { $0.id == targetID }) ?? current.count
        case .end:
            to = current.count
        @unknown default:
            return
        }
        guard let writer = app.writer, let reader = app.reader else { return }
        Task {
            await browse.moveProjects(in: client.prefix, from: from, to: to,
                                      writer: writer, reader: reader)
        }
    }
}

// MARK: - Shared pieces

/// One browse row: title, optional secondary line, and (on iOS) a trailing
/// chevron. macOS sidebar/list rows conventionally have no chevron.
private struct BrowseRow: View {
    var title: String
    var subtitle: String?

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
            #if os(iOS)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
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

/// Detail placeholder until Task 5.3 brings the clip list.
struct ProjectPlaceholderView: View {
    var project: ProjectRef

    var body: some View {
        VStack(spacing: 8) {
            Text(project.manifest.displayName)
                .font(.title2)
            Text("Clips arrive in Task 5.3")
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle(project.manifest.displayName)
    }
}

#Preview("Browse (unconfigured model, no network)") {
    // AppModel() without saved settings has no reader/writer, so the browse
    // views render their empty states without touching the network.
    BrowseRootView(showingSettings: .constant(false))
        .environment(AppModel())
}
