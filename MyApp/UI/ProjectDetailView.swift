import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Project detail (Task 5.3): the project's clip list plus clip intake.
///
/// Clips are *remote* objects — there is no local file to thumbnail, and a
/// real remote thumbnail would need ranged GETs against the object (out of
/// scope here), so stored clips show a static video icon. Only active uploads,
/// which still have a local staged copy, get a real thumbnail frame.
///
/// Intake sources: iOS PhotosPicker + Files (fileImporter); macOS fileImporter
/// + drag-and-drop of files/folders (folders expand one level to video files).
/// Every source funnels into a small camera-label sheet, then
/// `IntakeModel.enqueue`.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var app
    var project: ProjectRef

    @State private var intake = IntakeModel()
    @State private var clips: [Clip] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var editingClip: Clip?

    @State private var showingFileImporter = false
    @State private var showingDownloadFolderPicker = false
    @State private var download: DownloadController?
    @State private var pendingIntakeURLs: [URL] = []
    @State private var showingCameraLabelPrompt = false
    /// Remembered for the rest of the session so multi-batch ingests from the
    /// same camera don't retype the label.
    @State private var sessionCameraLabel = ""

    #if os(iOS)
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    #endif

    var body: some View {
        platformContent
            .navigationTitle(project.manifest.displayName)
            .toolbar { toolbarContent }
            .task(id: project.prefix) {
                intake.onClipsChanged = { Task { await refresh() } }
                await refresh()
            }
            .sheet(item: $editingClip) { clip in
                ClipEditSheet(clip: clip) { await refresh() }
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
            statusHeader
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
                #if os(macOS)
                ContentUnavailableView("No clips yet", systemImage: "film.stack",
                                       description: Text("Drop video files or folders here, or click + to add"))
                #else
                ContentUnavailableView("No clips yet", systemImage: "film.stack",
                                       description: Text("Add videos from Photos or Files"))
                #endif
            }
        } else {
            List {
                if !activeUploads.isEmpty {
                    Section("Uploading") {
                        ForEach(activeUploads) { upload in
                            ActiveUploadRow(upload: upload) {
                                intake.retry(jobID: upload.id, app: app)
                            }
                        }
                    }
                }
                Section {
                    ForEach(clips) { clip in
                        ClipRow(clip: clip)
                            .contentShape(Rectangle())
                            .onTapGesture { editingClip = clip }
                            .contextMenu {
                                Button("Edit") { editingClip = clip }
                            }
                    }
                }
            }
            .refreshable { await refresh() }
        }
    }

    /// Dismissible error lines for clip loading and intake failures.
    @ViewBuilder private var statusHeader: some View {
        VStack(spacing: 0) {
            if let loadError {
                errorLine(loadError) { self.loadError = nil }
            }
            if let intakeError = intake.lastError {
                errorLine(intakeError) { intake.lastError = nil }
            }
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
        // Whole-project download (per-clip selection deferred).
        ToolbarItem {
            Button("Download…", systemImage: "arrow.down.circle") {
                showingDownloadFolderPicker = true
            }
            .disabled(app.client == nil || clips.isEmpty || download != nil)
        }
        #if os(macOS)
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
        ToolbarItem {
            Button("Add Clips", systemImage: "plus") {
                showingFileImporter = true
            }
            .disabled(app.engine == nil)
        }
        #else
        ToolbarItem {
            PhotosPicker(selection: $photoSelection, matching: .videos,
                         photoLibrary: .shared()) {
                Label("Add from Photos", systemImage: "photo.badge.plus")
            }
            .disabled(app.engine == nil || isImportingPhotos)
        }
        ToolbarItem {
            Button("Files", systemImage: "folder.badge.plus") {
                showingFileImporter = true
            }
            .disabled(app.engine == nil)
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
                                       app: app)
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

    #if os(macOS)
    private func handleDrop(_ urls: [URL]) {
        queueIntake(Self.expandDropped(urls))
    }
    #endif

    /// Dropped files pass through as-is; dropped folders expand one level to
    /// files with a MediaTypes-known video extension (sorted by name).
    nonisolated static func expandDropped(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let children = (try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                out += children
                    .filter { isKnownVideoFile($0) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
                    intake.lastError = "Could not import a video from Photos: \(String(describing: error))"
                }
            }
            isImportingPhotos = false
            queueIntake(urls)
        }
    }
    #endif

    // MARK: - Download

    /// Downloads the whole project into the picked directory, using the SAME
    /// ordering the list shows: `clips` is already sorted by `listClips`, and
    /// `DownloadNaming` prefixes filenames from that order.
    private func startDownload(into directory: URL) {
        guard let client = app.client, !clips.isEmpty else { return }
        let controller = DownloadController(client: client)
        controller.start(clips: clips, manifest: project.manifest, directory: directory)
        download = controller
    }

    private func refresh() async {
        guard let reader = app.reader else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            clips = try await reader.listClips(projectPrefix: project.prefix)
            loadError = nil
        } catch {
            // A refresh cancelled by view teardown / project switch is not a failure.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            loadError = "Could not load clips: \(String(describing: error))"
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

    /// `clips` must already be in list order; filenames come from
    /// `DownloadNaming` so downloads carry the same order prefixes.
    func start(clips: [Clip], manifest: ProjectManifest, directory: URL) {
        guard task == nil else { return }
        clipCount = clips.count
        let filenames = DownloadNaming.filenames(forOrdered: clips)
        let items = zip(clips, filenames).map { DownloadEngine.Item(clip: $0, filename: $1) }
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
                phase = .failed(String(describing: error))
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

/// One stored (remote) clip. Static video icon — see `ProjectDetailView` doc
/// comment for why remote clips don't get real thumbnails in this task.
private struct ClipRow: View {
    var clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnail(stagedURL: nil)
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

    /// 83.4 -> "1:23"; hours roll into minutes (m:ss per spec).
    static func formatDuration(_ seconds: Double) -> String {
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
/// AVAssetImageGenerator's async API; otherwise a static placeholder icon.
private struct ClipThumbnail: View {
    var stagedURL: URL?
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
        .task(id: stagedURL) {
            guard thumbnail == nil, let stagedURL else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: stagedURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            thumbnail = try? await generator.image(at: .zero).image
        }
    }
}

// MARK: - Edit sheet

/// Edits the mutable sidecar fields. Fields are populated from the clip on
/// first appearance (not in init, to stay friendly with the @State macro).
private struct ClipEditSheet: View {
    @Environment(AppModel.self) private var app
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
                Section("Name") {
                    TextField("Display name", text: $displayName)
                }
                Section("Camera") {
                    TextField("Camera label", text: $cameraLabel)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
                Section("Order") {
                    Toggle("Use capture time", isOn: $useCaptureTime)
                    if !useCaptureTime {
                        DatePicker("Effective time", selection: $orderOverride)
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Clip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || app.writer == nil
                                  || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { populateOnce() }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
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
        guard let writer = app.writer, !isSaving else { return }
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
                saveError = "Could not save: \(String(describing: error))"
            }
            isSaving = false
        }
    }
}

#Preview("Project detail (unconfigured model, no network)") {
    // AppModel() without saved settings has no reader/engine, so the view
    // renders its empty state without touching the network.
    NavigationStack {
        ProjectDetailView(project: ProjectRef(
            prefix: "acme-x1/gala-k9/",
            manifest: ProjectManifest(displayName: "Spring Gala",
                                      sortIndex: nil,
                                      createdAt: Date(timeIntervalSince1970: 1_700_000_000))))
    }
    .environment(AppModel())
}
