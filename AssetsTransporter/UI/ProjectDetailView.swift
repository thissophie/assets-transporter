import AVFoundation
import AVKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Project detail (Task 5.3): the project's clip list plus clip intake.
///
/// Thumbnails: active uploads still have a local staged copy, so their rows
/// generate a frame from it. Stored clips show the `.thumb.jpg` poster frame
/// the upload wrote alongside the clip (see `ClipThumbnailer`); clips without
/// one (pre-feature uploads, generation failures) fall back to a static icon.
///
/// Intake sources: iOS PhotosPicker + Files (fileImporter); macOS fileImporter
/// + drag-and-drop of files/folders (folders expand one level to video files).
/// Every source funnels into a small camera-label sheet, then
/// `IntakeModel.enqueue`.
struct ProjectDetailView: View {
    @Environment(ServerSession.self) private var session
    var project: ProjectRef
    /// Bumped by View ▸ Refresh (macOS); each change reloads the clip list.
    var refreshTrigger = 0

    /// The server's intake/upload coordinator: shared so the upload queue
    /// screen and this view observe (and guard) the same sequential loop.
    private var intake: IntakeModel { session.intake }
    @State private var clips: [Clip] = []
    @State private var selection = Set<Clip.ID>()
    @State private var isLoading = false
    /// Bumped by every `refresh()`; a fetch only publishes if it is still the
    /// newest one (its own fetch task is deliberately never cancelled).
    @State private var refreshGeneration = 0
    @State private var loadError: String?
    @State private var editingClip: Clip?
    @State private var playingClip: Clip?
    @State private var clipsToDelete: [Clip]?
    @State private var isDeletingClip = false
    /// Keys queued for the download folder picker: a set downloads just those
    /// clips; nil downloads the whole project (and writes the project.json
    /// copy). Always set right before the picker is presented.
    @State private var pendingDownloadKeys: Set<String>?

    @State private var showingFileImporter = false
    @State private var showingDownloadFolderPicker = false
    @State private var download: DownloadController?
    @State private var pendingIntakeURLs: [URL] = []
    @State private var showingCameraLabelPrompt = false
    /// True while a folder drop is being copied into the temp intake dir
    /// (macOS): shows a busy line and disables the intake controls.
    @State private var isExpandingDrop = false
    /// Remembered for the rest of the session so multi-batch ingests from the
    /// same camera don't retype the label.
    @State private var sessionCameraLabel = ""

    #if os(iOS)
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    #endif

    #if os(macOS)
    @State private var showingWatchFolderPicker = false
    #endif

    var body: some View {
        platformContent
            // macOS deliberately sets no title here: the detail column's
            // title is what lands in the titlebar, and `BrowseRootView` uses
            // it for the client/server context, with this project's name as
            // the window subtitle.
            #if os(iOS)
            .navigationTitle(project.manifest.displayName)
            #endif
            .toolbar { toolbarContent }
            .task(id: project.prefix) {
                // Clear the previous project's rows/error immediately so a
                // slow refresh doesn't flash stale content after switching.
                clips = []
                selection = []
                loadError = nil
                intake.onClipsChanged = { Task { await refresh() } }
                await refresh()
            }
            .onChange(of: refreshTrigger) {
                Task { await refresh() }
            }
            .sheet(item: $editingClip) { clip in
                ClipEditSheet(clip: clip) { await refresh() }
            }
            .sheet(item: $playingClip) { clip in
                // Presigning is pure (no network), so the URL is built right
                // at presentation time and the grant clock starts here.
                ClipPlayerSheet(clip: clip,
                                url: session.client.presignedGetURL(key: clip.key))
            }
            .sheet(isPresented: $showingCameraLabelPrompt) {
                cameraLabelSheet
            }
            .fileImporter(isPresented: $showingFileImporter,
                          allowedContentTypes: [.movie, .video, .item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    queueIntake(urls)
                }
            }
            .sheet(item: $download) { controller in
                DownloadProgressSheet(controller: controller) { download = nil }
            }
    }

    // MARK: - Content

    /// `content` plus the platform-specific intake hook: drag-and-drop on
    /// macOS, PhotosPicker selection handling on iOS.
    private var platformContent: some View {
        #if os(macOS)
        content.dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
        #else
        content.onChange(of: photoSelection) { _, items in
            handlePhotoSelection(items)
        }
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The folder picker for the watched-folder feature lives on the
            // header so it doesn't collide with the other two fileImporters
            // (which must each sit on their own view).
            statusHeader
                .fileImporter(isPresented: $showingWatchFolderPicker,
                              allowedContentTypes: [.folder],
                              allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let folder = urls.first {
                        session.watch.enable(folderURL: folder,
                                             projectPrefix: project.prefix,
                                             cameraLabel: sessionCameraLabelOrNil,
                                             session: session)
                    }
                }
            #else
            statusHeader
            #endif
            listOrEmpty
        }
        // Attached here (not next to the intake fileImporter in `body`) so the
        // two importers live on different views.
        .fileImporter(isPresented: $showingDownloadFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let directory = urls.first {
                startDownload(into: directory)
            }
            pendingDownloadKeys = nil
        }
    }

    private var activeUploads: [IntakeModel.ActiveUpload] {
        intake.active.filter { $0.clipKey.hasPrefix(project.prefix) }
    }

    @ViewBuilder private var listOrEmpty: some View {
        if clips.isEmpty && activeUploads.isEmpty {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // In a ScrollView so pull-to-refresh is available from the
                // empty state — exactly where a failed or stale load needs a
                // retry; a bare ContentUnavailableView has no scroll surface.
                ScrollView {
                    Group {
                        #if os(macOS)
                        ContentUnavailableView("No clips yet", systemImage: "film.stack",
                                               description: Text("Drop video files or folders here, or click + to add"))
                        #else
                        ContentUnavailableView("No clips yet", systemImage: "film.stack",
                                               description: Text("Add videos from Photos or Files"))
                        #endif
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await refresh() }
            }
        } else {
            List(selection: $selection) {
                if !activeUploads.isEmpty {
                    Section("Uploading") {
                        ForEach(activeUploads) { upload in
                            ActiveUploadRow(upload: upload) {
                                intake.retry(jobID: upload.id, session: session)
                            }
                            .selectionDisabled()
                        }
                    }
                }
                Section {
                    ForEach(clips) { clip in
                        // Click/tap selects; playback runs through the list's
                        // primaryAction (double-click on macOS, tap on iOS).
                        // The ⓘ button opens the edit sheet.
                        HStack(spacing: 8) {
                            ClipRow(clip: clip)
                            Spacer()
                            Button("Edit", systemImage: "info.circle") { editingClip = clip }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { clipsToDelete = [clip] }
                                .disabled(clipDeletionDisabled)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: Clip.ID.self) { ids in
                selectionMenu(for: selectedClips(ids))
            } primaryAction: { ids in
                // Playback is single-clip only; a multi-selection double-click
                // (or tap) does nothing.
                if ids.count == 1, let clip = clips.first(where: { ids.contains($0.id) }) {
                    playingClip = clip
                }
            }
            #if os(macOS)
            .onDeleteCommand {
                let selected = selectedClips(selection)
                if !selected.isEmpty && !clipDeletionDisabled {
                    clipsToDelete = selected
                }
            }
            #endif
            .refreshable { await refresh() }
            .confirmationDialog(deleteConfirmationTitle,
                                isPresented: clipDeletePresented,
                                titleVisibility: .visible,
                                presenting: clipsToDelete) { toDelete in
                Button("Delete", role: .destructive) { deleteClips(toDelete) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This cannot be undone.")
            }
        }
    }

    private var clipDeletePresented: Binding<Bool> {
        Binding(get: { clipsToDelete != nil },
                set: { if !$0 { clipsToDelete = nil } })
    }

    private var clipDeletionDisabled: Bool {
        isDeletingClip
    }

    /// The given selection resolved to clips, in list order.
    private func selectedClips(_ ids: Set<Clip.ID>) -> [Clip] {
        clips.filter { ids.contains($0.id) }
    }

    private var deleteConfirmationTitle: String {
        guard let clipsToDelete else { return "" }
        return clipsToDelete.count == 1
            ? "Delete “\(clipsToDelete[0].sidecar.displayName)”?"
            : "Delete \(clipsToDelete.count) clips?"
    }

    /// Context menu for the right-clicked (or long-pressed) rows: single-clip
    /// actions when one row is targeted, bulk download/delete otherwise.
    @ViewBuilder private func selectionMenu(for selected: [Clip]) -> some View {
        if selected.count == 1, let clip = selected.first {
            Button("Play") { playingClip = clip }
            Button("Edit") { editingClip = clip }
        }
        if !selected.isEmpty {
            Button(selected.count == 1 ? "Download…" : "Download \(selected.count) Clips…") {
                pendingDownloadKeys = Set(selected.map(\.key))
                showingDownloadFolderPicker = true
            }
            .disabled(download != nil)
            Button(selected.count == 1 ? "Delete" : "Delete \(selected.count) Clips",
                   role: .destructive) {
                clipsToDelete = selected
            }
            .disabled(clipDeletionDisabled)
        }
    }

    /// Deletes the clips (objects + sidecars) sequentially, halting on the
    /// first failure, then refreshes either way so partial progress shows.
    /// Failures land in the existing `loadError` line.
    private func deleteClips(_ toDelete: [Clip]) {
        guard !isDeletingClip, !toDelete.isEmpty else { return }
        let writer = session.writer
        isDeletingClip = true
        Task {
            do {
                try await writer.deleteClips(toDelete)
                selection.subtract(toDelete.map(\.id))
            } catch {
                let what = toDelete.count == 1
                    ? "“\(toDelete[0].sidecar.displayName)”"
                    : "\(toDelete.count) clips"
                loadError = "Could not delete \(what): \(ErrorText.describe(error))"
            }
            await refresh()
            isDeletingClip = false
        }
    }

    /// Dismissible error lines for clip loading and intake failures, plus the
    /// folder-drop busy line.
    @ViewBuilder private var statusHeader: some View {
        VStack(spacing: 0) {
            if isExpandingDrop {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing dropped files…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            if let loadError {
                errorLine(loadError) { self.loadError = nil }
            }
            if let intakeError = intake.lastError {
                errorLine(intakeError) { intake.lastError = nil }
            }
            #if os(macOS)
            // Watch status is shown here when it concerns THIS project, or
            // when nothing is actively watched (enable/restore failures).
            if let watchStatus = session.watch.status,
               isWatchingThisProject || session.watch.activeConfig == nil {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(watchStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            #endif
        }
    }

    private func errorLine(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer()
            Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Downloads the selection when one exists, the whole project otherwise.
        ToolbarItem {
            Button(selection.isEmpty ? "Download…" : "Download Selected…",
                   systemImage: "arrow.down.circle") {
                pendingDownloadKeys = selection.isEmpty ? nil : selection
                showingDownloadFolderPicker = true
            }
            .disabled(clips.isEmpty || download != nil)
        }
        if !selection.isEmpty {
            ToolbarItem {
                Button("Delete Selected", systemImage: "trash") {
                    clipsToDelete = selectedClips(selection)
                }
                .disabled(clipDeletionDisabled)
            }
        }
        #if os(macOS)
        ToolbarItem {
            Button("Add Clips", systemImage: "plus") {
                showingFileImporter = true
            }
            .disabled(isExpandingDrop)
        }
        ToolbarItem {
            watchMenu
        }
        #else
        ToolbarItem {
            PhotosPicker(selection: $photoSelection, matching: .videos,
                         photoLibrary: .shared()) {
                Label("Add from Photos", systemImage: "photo.badge.plus")
            }
            .disabled(isImportingPhotos)
        }
        ToolbarItem {
            Button("Files", systemImage: "folder.badge.plus") {
                showingFileImporter = true
            }
        }
        // Edit mode provides the standard multi-select checkmarks on iOS.
        ToolbarItem {
            EditButton()
        }
        #endif
    }

    // MARK: - Intake plumbing

    /// All intake sources funnel here: stash the URLs and ask for a camera
    /// label before enqueueing.
    private func queueIntake(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingIntakeURLs += urls
        showingCameraLabelPrompt = true
    }

    private var cameraLabelSheet: some View {
        NavigationStack {
            Form {
                TextField("Camera label (optional)", text: $sessionCameraLabel)
                Text("^[\(pendingIntakeURLs.count) file](inflect: true) will upload to “\(project.manifest.displayName)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Add Clips")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pendingIntakeURLs = []
                        showingCameraLabelPrompt = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") {
                        let label = sessionCameraLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                        intake.enqueue(fileURLs: pendingIntakeURLs,
                                       projectPrefix: project.prefix,
                                       cameraLabel: label.isEmpty ? nil : label,
                                       session: session)
                        pendingIntakeURLs = []
                        showingCameraLabelPrompt = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 180)
        #endif
    }

    // MARK: - Watched folder (macOS)

    #if os(macOS)
    private var isWatchingThisProject: Bool {
        session.watch.activeConfig?.projectPrefix == project.prefix
    }

    /// The session camera label (kept by the intake sheet), trimmed; nil when
    /// empty. Watch enable/move uses it WITHOUT prompting — the watch runs
    /// unattended, so there is no good moment to ask, and the label is
    /// whatever the user last typed for this session's manual intakes.
    private var sessionCameraLabelOrNil: String? {
        let label = sessionCameraLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// Watch Folder menu: eye icon (filled while THIS project is watched).
    /// Not watching → pick a folder; watching this project → show the folder
    /// + Stop; watching another project → offer to move the watch here.
    private var watchMenu: some View {
        Menu {
            if let config = session.watch.activeConfig {
                if let path = session.watch.watchedFolderDisplayPath {
                    Text(path)
                }
                if config.projectPrefix != project.prefix {
                    Button("Move Watch Here") {
                        session.watch.move(projectPrefix: project.prefix,
                                           cameraLabel: sessionCameraLabelOrNil,
                                           session: session)
                    }
                }
                Button("Stop Watching") {
                    session.watch.disable()
                }
            } else {
                Button("Watch a Folder…") {
                    showingWatchFolderPicker = true
                }
            }
        } label: {
            Label("Watch Folder", systemImage: isWatchingThisProject ? "eye.fill" : "eye")
        }
    }

    private func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isExpandingDrop = true
        Task {
            // Detached: expanding a dropped folder copies its children (a
            // multi-GB SD card, potentially) and must not block the main
            // actor. The dropped URLs' security scopes are redeemable off the
            // callback from any thread — expandDropped starts/stops them
            // itself, exactly as stage() does for picker URLs.
            let expanded = await Task.detached { Self.expandDropped(urls) }.value
            isExpandingDrop = false
            queueIntake(expanded)
        }
    }
    #endif

    /// Dropped files pass through as-is (their own security scope is resolved
    /// again at staging time). Dropped folders expand one level to video files
    /// (MediaTypes-known extension, sorted by name) — but a child of a
    /// security-scoped folder is only readable while the FOLDER's scope is
    /// held, and staging runs later (after the camera-label sheet). So each
    /// child is copied NOW, while the scope is held, into
    /// `IntakeModel.photoIntakeDirectory/<UUID>/<originalName>` — the same
    /// temp-copy mechanism PhotosPicker imports use; staging consumes and
    /// deletes those copies. Unreadable/uncopyable children are skipped
    /// (best effort).
    nonisolated static func expandDropped(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let children = ((try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? [])
                    .filter { isKnownVideoFile($0) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    let folder = IntakeModel.photoIntakeDirectory
                        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    do {
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                        let destination = folder.appending(path: child.lastPathComponent)
                        try fm.copyItem(at: child, to: destination)
                        out.append(destination)
                    } catch {
                        try? fm.removeItem(at: folder)
                    }
                }
            } else {
                out.append(url)
            }
        }
        return out
    }

    /// True when MediaTypes recognizes the extension as a video type.
    nonisolated private static func isKnownVideoFile(_ url: URL) -> Bool {
        MediaTypes.contentType(forExtension: url.pathExtension) != "application/octet-stream"
    }

    #if os(iOS)
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoSelection = []
        isImportingPhotos = true
        Task {
            var urls: [URL] = []
            for item in items {
                do {
                    if let movie = try await item.loadTransferable(type: IntakeMovie.self) {
                        urls.append(movie.url)
                    }
                } catch {
                    intake.lastError = "Could not import a video from Photos: \(ErrorText.describe(error))"
                }
            }
            isImportingPhotos = false
            queueIntake(urls)
        }
    }
    #endif

    // MARK: - Download

    /// Downloads the pending selection — or the whole project when none — into
    /// the picked directory. Filenames always come from the FULL list order
    /// (`DownloadNaming`), so a partial download keeps each clip's project
    /// position; only whole-project downloads write the project.json copy.
    private func startDownload(into directory: URL) {
        let items: [DownloadEngine.Item]
        let manifest: ProjectManifest?
        if let pendingDownloadKeys {
            items = DownloadNaming.selectedFilenames(forOrdered: clips,
                                                     selectedKeys: pendingDownloadKeys)
                .map { DownloadEngine.Item(clip: $0.clip, filename: $0.filename) }
            manifest = nil
        } else {
            let filenames = DownloadNaming.filenames(forOrdered: clips)
            items = zip(clips, filenames).map { DownloadEngine.Item(clip: $0, filename: $1) }
            manifest = project.manifest
        }
        guard !items.isEmpty else { return }
        let controller = DownloadController(client: session.client)
        controller.start(items: items, manifest: manifest, directory: directory)
        download = controller
    }

    private func refresh() async {
        let reader = session.reader
        let prefix = project.prefix
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { isLoading = false }
        do {
            // The fetch runs as an unstructured task because on iPhone the
            // collapsed NavigationSplitView sends a re-pushed detail view a
            // spurious onDisappear mid-transition (with no matching reappear),
            // cancelling the surrounding .task. A structured fetch dies with
            // it and nothing ever retries, so the visible view sits on
            // "No clips yet". The unstructured fetch survives that bogus
            // cancellation; the generation guard drops any result a newer
            // refresh (project switch, reload) has superseded.
            let fetched = try await Task { try await reader.listClips(projectPrefix: prefix) }.value
            guard generation == refreshGeneration else { return }
            clips = fetched
            // Drop selected ids that no longer exist (deleted here or elsewhere).
            selection.formIntersection(Set(clips.map(\.id)))
            loadError = nil
        } catch {
            guard generation == refreshGeneration else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            loadError = "Could not load clips: \(ErrorText.describe(error))"
        }
    }
}

// MARK: - Download flow

/// Owns one project download: builds the ordered `DownloadEngine.Item` list,
/// holds security-scoped access to the destination directory for the whole
/// download, and republishes engine progress for the sheet.
@Observable
private final class DownloadController: Identifiable {
    enum Phase {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    let id = UUID()
    private(set) var phase: Phase = .running
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var clipCount = 0

    private let engine: DownloadEngine
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    init(client: S3Client) {
        engine = DownloadEngine(client: client)
    }

    /// `items` must already be in list order with `DownloadNaming` filenames
    /// (so downloads carry the order prefixes). `manifest` is written
    /// alongside the clips only for whole-project downloads.
    func start(items: [DownloadEngine.Item], manifest: ProjectManifest?, directory: URL) {
        guard task == nil else { return }
        clipCount = items.count
        let engine = engine
        task = Task {
            // Security-scoped access is the caller's job: hold it across the
            // whole await, including the engine's final project.json write.
            let accessing = directory.startAccessingSecurityScopedResource()
            defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
            do {
                try await engine.download(items: items, into: directory,
                                          projectManifest: manifest) { completed, total in
                    // The outer task already keeps `self` alive for the whole
                    // download, so a strong capture here adds nothing to worry
                    // about; hop to the main actor to publish.
                    Task { @MainActor in
                        self.completedBytes = completed
                        self.totalBytes = total
                    }
                }
                phase = .finished
            } catch is CancellationError {
                phase = .cancelled
            } catch {
                phase = .failed(ErrorText.describe(error))
            }
        }
    }

    /// Cooperative: the engine stops at the next chunk boundary; partial
    /// files stay on disk for a later resume.
    func cancel() {
        engine.cancel()
    }
}

/// Progress sheet for a running download: byte-count progress bar with a
/// Cancel button, then a success / cancelled / failed end state.
private struct DownloadProgressSheet: View {
    var controller: DownloadController
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch controller.phase {
            case .running:
                Text("Downloading ^[\(controller.clipCount) clip](inflect: true)…")
                    .font(.headline)
                ProgressView(value: fractionCompleted)
                Text("\(Text(controller.completedBytes, format: .byteCount(style: .file))) of \(Text(controller.totalBytes, format: .byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .cancel) { controller.cancel() }
            case .finished:
                Label("Downloaded ^[\(controller.clipCount) clip](inflect: true)",
                      systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            case .cancelled:
                Label("Download cancelled", systemImage: "xmark.circle")
                    .font(.headline)
                Text("Partial files were kept — downloading again resumes where they left off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Close", action: onClose)
            case .failed(let message):
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("Close", action: onClose)
            }
        }
        .padding(24)
        .frame(minWidth: 300)
        .interactiveDismissDisabled(controller.isRunning)
        .presentationDetents([.medium])
    }

    /// nil totals (not yet known) render as indeterminate progress.
    private var fractionCompleted: Double? {
        guard controller.totalBytes > 0 else { return nil }
        return Double(controller.completedBytes) / Double(controller.totalBytes)
    }
}

// MARK: - PhotosPicker payload

/// PhotosPicker delivers placeholders; loading this transferable copies the
/// video into `IntakeModel.photoIntakeDirectory/<UUID>/` *preserving the
/// original filename* (so the sidecar keeps a meaningful displayName).
/// `IntakeModel` deletes the temp copy after staging it.
nonisolated private struct IntakeMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = IntakeModel.photoIntakeDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

// MARK: - Rows

/// One stored (remote) clip: the stored poster frame when the upload wrote
/// one (`clip.hasThumbnail`), a static video icon otherwise.
/// Internal (not file-private) so tests can pin `formatDuration`.
struct ClipRow: View {
    var clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnail(stagedURL: nil,
                          remoteKey: clip.hasThumbnail
                              ? BucketKeys.thumbnailKey(forClipKey: clip.key)
                              : nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(clip.sidecar.displayName)
                        .lineLimit(1)
                    if let camera = clip.sidecar.cameraLabel {
                        CameraBadge(label: camera)
                    }
                }
                HStack(spacing: 8) {
                    if let duration = clip.sidecar.duration {
                        Text(Self.formatDuration(duration))
                    }
                    Text(clip.sidecar.fileSize, format: .byteCount(style: .file))
                    Text(clip.effectiveTime, format: .dateTime)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 83.4 -> "1:23"; hours deliberately roll into minutes (3661 -> "61:01")
    /// — clip rows use one compact m:ss format per spec. Pinned by tests.
    nonisolated static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct CameraBadge: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
            .lineLimit(1)
    }
}

/// One in-flight upload: real thumbnail (local staged file exists), name, and
/// a state badge — progress % while uploading, retry button on failure.
private struct ActiveUploadRow: View {
    var upload: IntakeModel.ActiveUpload
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnail(stagedURL: upload.stagedURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(upload.displayName)
                    .lineLimit(1)
                switch upload.state {
                case .waiting:
                    Text("Waiting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .uploading:
                    ProgressView(value: upload.progress)
                    Text("\(Int((upload.progress * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    if let retry = upload.nextAutoRetry {
                        // Text(_, style: .timer) live-updates the countdown.
                        Text("Retrying in \(Text(retry.at, style: .timer)) (attempt \(retry.attempt)/\(IntakeModel.maxAutoRetries))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                case .done:
                    Label("Uploaded", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if case .failed = upload.state {
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Leading row image. With a local staged file, generates a real frame via
/// AVAssetImageGenerator's async API; with a remote key, fetches the stored
/// `.thumb.jpg` poster frame (cached for the session); otherwise a static
/// placeholder icon.
private struct ClipThumbnail: View {
    var stagedURL: URL?
    var remoteKey: String? = nil
    @Environment(ServerSession.self) private var session
    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: stagedURL?.absoluteString ?? remoteKey) {
            guard thumbnail == nil else { return }
            if let stagedURL {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: stagedURL))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 240)
                thumbnail = try? await generator.image(at: .zero).image
            } else if let remoteKey {
                thumbnail = await RemoteThumbnailCache.image(key: remoteKey,
                                                             client: session.client)
            }
        }
    }
}

/// Session-wide cache of fetched clip thumbnails so refreshes (after every
/// upload) and scrolling don't refetch the same small JPEGs. Keyed by
/// endpoint + bucket + object key, since sessions for different servers share
/// this cache. Best effort: fetch or decode failures cache nothing and the
/// row keeps its placeholder icon.
@MainActor private enum RemoteThumbnailCache {
    private static var images: [String: CGImage] = [:]

    static func image(key: String, client: S3Client) async -> CGImage? {
        let cacheKey = "\(client.config.endpoint)|\(client.config.bucket)|\(key)"
        if let cached = images[cacheKey] { return cached }
        guard let data = try? await client.getObject(key: key),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Thumbnails are ~320 px, so entries are small; the crude cap just
        // keeps a very large library from growing the cache without bound.
        if images.count >= 512 { images.removeAll() }
        images[cacheKey] = image
        return image
    }
}

// MARK: - Player sheet

/// Streams one clip through AVPlayer from a short-lived presigned URL. The
/// URL carries the whole grant (AVPlayer cannot attach Authorization headers
/// to its media requests), and AVPlayer's own ranged GETs make scrubbing work
/// without downloading the clip. Unplayable formats and network failures
/// surface as the player's built-in error state.
private struct ClipPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var clip: Clip
    var url: URL

    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle(clip.sidecar.displayName)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
        .presentationDetents([.large])
    }
}

// MARK: - Edit sheet

/// Edits the mutable sidecar fields. Fields are populated from the clip on
/// first appearance (not in init, to stay friendly with the @State macro).
private struct ClipEditSheet: View {
    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var clip: Clip
    var onSaved: () async -> Void

    @State private var displayName = ""
    @State private var cameraLabel = ""
    @State private var notes = ""
    @State private var useCaptureTime = true
    @State private var orderOverride = Date()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var populated = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $displayName, prompt: Text("Clip name"))
                    TextField("Camera", text: $cameraLabel, prompt: Text("Optional"))
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 140)
                }
                Section {
                    Toggle("Use capture time for ordering", isOn: $useCaptureTime)
                    if !useCaptureTime {
                        DatePicker("Effective time", selection: $orderOverride)
                    }
                } header: {
                    Text("Order")
                } footer: {
                    Text("Clips sort by capture time unless you set an effective time here.")
                }
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Edit Clip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving
                                  || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { populateOnce() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 400)
        #endif
    }

    private func populateOnce() {
        guard !populated else { return }
        populated = true
        displayName = clip.sidecar.displayName
        cameraLabel = clip.sidecar.cameraLabel ?? ""
        notes = clip.sidecar.notes ?? ""
        useCaptureTime = clip.sidecar.orderOverride == nil
        orderOverride = clip.sidecar.orderOverride ?? clip.effectiveTime
    }

    private func save() {
        guard !isSaving else { return }
        let writer = session.writer
        isSaving = true
        var sidecar = clip.sidecar
        sidecar.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = cameraLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        sidecar.cameraLabel = camera.isEmpty ? nil : camera
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        sidecar.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        sidecar.orderOverride = useCaptureTime ? nil : orderOverride
        Task {
            do {
                try await writer.updateClipSidecar(clipKey: clip.key, sidecar: sidecar)
                await onSaved()
                dismiss()
            } catch {
                saveError = "Could not save: \(ErrorText.describe(error))"
            }
            isSaving = false
        }
    }
}

#Preview("Project detail (placeholder server, unreachable endpoint)") {
    NavigationStack {
        ProjectDetailView(project: ProjectRef(
            prefix: "acme-x1/gala-k9/",
            manifest: ProjectManifest(displayName: "Spring Gala",
                                      sortIndex: nil,
                                      createdAt: Date(timeIntervalSince1970: 1_700_000_000))))
    }
    .environment(ServerSession.preview())
}
