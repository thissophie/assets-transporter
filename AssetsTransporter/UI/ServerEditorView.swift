import SwiftUI

/// Validates the raw server-form strings. Returns nil when valid, otherwise
/// a user-facing message describing the first problem found. Inputs are
/// whitespace-trimmed before checking, matching how the form saves them.
nonisolated enum SettingsValidation {
    /// Full server form: the name is checked first, then the connection.
    static func validate(name: String, endpoint: String, bucket: String,
                         accessKey: String, secretKey: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Server name is required."
        }
        return validate(endpoint: endpoint, bucket: bucket,
                        accessKey: accessKey, secretKey: secretKey)
    }

    static func validate(endpoint: String, bucket: String,
                         accessKey: String, secretKey: String) -> String? {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            return "Endpoint URL is required."
        }
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "Endpoint must be an http:// or https:// URL."
        }
        guard let host = url.host(), !host.isEmpty else {
            return "Endpoint URL must include a host."
        }
        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Bucket name is required."
        }
        if accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Access key is required."
        }
        if secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Secret key is required."
        }
        return nil
    }
}

/// Create-or-edit form for one server profile, presented as a sheet. Edits,
/// validates, saves through `AppModel` (Keychain), and can test the
/// connection against the *current form values* (not the saved state).
/// Pass `existing` to edit; nil creates a new server.
struct ServerEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var existing: ServerProfile?
    /// Called with the persisted profile after a successful save.
    var onSaved: ((ServerProfile) -> Void)? = nil

    @State private var name = ""
    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var pathStyle = true
    @State private var region = "us-east-1"

    @State private var validationError: String?
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var populated = false

    // Quick setup from a configure link (new servers only).
    @State private var showingScanner = false
    @State private var showingPasteField = false
    @State private var pastedLink = ""
    @State private var linkStatus: LinkStatus = .idle
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil {
                    quickSetupSection
                }

                Section("Name") {
                    TextField("Server name", text: $name, prompt: Text("Production"))
                }

                Section("Server") {
                    TextField("Endpoint URL", text: $endpoint,
                              prompt: Text("https://s3.example.com:9000"))
                    TextField("Bucket", text: $bucket, prompt: Text("Bucket"))
                    TextField("Region", text: $region, prompt: Text("us-east-1"))
                    Toggle("Path-style addressing", isOn: $pathStyle)
                }

                Section("Credentials") {
                    TextField("Access Key", text: $accessKey, prompt: Text("Access Key"))
                    SecureField("Secret Key", text: $secretKey, prompt: Text("Secret Key"))
                }

                Section {
                    HStack {
                        Button("Test Connection", action: testConnection)
                            .disabled(isTesting)
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if let validationError {
                        Text(validationError)
                            .foregroundStyle(.red)
                    }
                    if let testResult {
                        Text(testResult)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(existing == nil ? "New Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onAppear(perform: populateOnce)
            .onDisappear { fetchTask?.cancel() }
            .sheet(isPresented: $showingScanner) {
                QRScannerView(
                    onFound: { link in
                        showingScanner = false
                        fetch(link)
                    },
                    onPasteInstead: {
                        showingScanner = false
                        showingPasteField = true
                    })
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: existing == nil ? 560 : 440)
        #endif
    }

    // MARK: - Quick setup

    /// Where a configure-link fetch stands.
    private enum LinkStatus: Equatable {
        case idle
        case fetching
        case failed(String)
        case filled(host: String)
    }

    /// "Scan QR Code" / "Paste Link", above the fields so they're seen
    /// before any typing. Either one only fills the form; Save is still the
    /// user's.
    private var quickSetupSection: some View {
        Section {
            HStack(spacing: 12) {
                Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                    showingScanner = true
                }
                .frame(maxWidth: .infinity)
                Button("Paste Link", systemImage: "link") {
                    showingPasteField.toggle()
                }
                .frame(maxWidth: .infinity)
            }
            // Bordered buttons keep each one its own tap target inside a
            // Form row on iOS (a plain row fires every button in it).
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(linkStatus == .fetching)

            if showingPasteField {
                HStack {
                    TextField("Configure link", text: $pastedLink,
                              prompt: Text("https://…/configure/…?sig=…"))
                        .labelsHidden()
                        .onSubmit(fetchPastedLink)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        #endif
                    // Reads the clipboard only when pressed, so iOS never
                    // shows its paste prompt unasked.
                    PasteButton(payloadType: String.self) { strings in
                        guard let first = strings.first else { return }
                        Task { @MainActor in
                            pastedLink = first
                            fetchPastedLink()
                        }
                    }
                    .labelStyle(.iconOnly)
                    Button("Fetch", action: fetchPastedLink)
                        .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || linkStatus == .fetching)
                }
            }

            switch linkStatus {
            case .idle:
                EmptyView()
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching server settings…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            case .filled(let host):
                Label("Filled in from \(host). Check the details, then Save.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Quick Setup")
        } footer: {
            Text("Scan the server's QR code or paste its configure link to fill in this form.")
        }
    }

    private func fetchPastedLink() {
        guard let link = ConfigureLink(scanned: pastedLink) else {
            linkStatus = .failed(ConfigureError.notALink.message)
            return
        }
        fetch(link)
    }

    /// Fetches the link's settings and fills the form. Nothing is saved.
    private func fetch(_ link: ConfigureLink) {
        fetchTask?.cancel()
        linkStatus = .fetching
        fetchTask = Task {
            let outcome: Result<ConfigurePayload, ConfigureError>
            do {
                outcome = .success(try await ConfigureClient().fetch(link))
            } catch let error as ConfigureError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(detail: ErrorText.describe(error)))
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let payload):
                apply(ServerFormValues(payload))
                linkStatus = .filled(host: link.host)
                showingPasteField = false
                pastedLink = ""
            case .failure(let error):
                linkStatus = .failed(error.message)
            }
        }
    }

    private func apply(_ values: ServerFormValues) {
        name = values.name
        endpoint = values.endpoint
        bucket = values.bucket
        region = values.region
        pathStyle = values.pathStyle
        accessKey = values.accessKey
        secretKey = values.secretKey
        validationError = nil
        testResult = nil
    }

    // MARK: - Actions

    private func populateOnce() {
        guard !populated, let existing else { return }
        populated = true
        name = existing.name
        endpoint = existing.settings.endpoint.absoluteString
        bucket = existing.settings.bucket
        accessKey = existing.settings.accessKey
        secretKey = existing.settings.secretKey
        pathStyle = existing.settings.pathStyle
        region = existing.settings.region
    }

    /// Trimmed settings built from the current form values, or nil (with
    /// `validationError` set) when the connection fields do not validate.
    private func validatedSettings(checkName: Bool) -> StoredS3Settings? {
        let message = checkName
            ? SettingsValidation.validate(name: name, endpoint: endpoint, bucket: bucket,
                                          accessKey: accessKey, secretKey: secretKey)
            : SettingsValidation.validate(endpoint: endpoint, bucket: bucket,
                                          accessKey: accessKey, secretKey: secretKey)
        if let message {
            validationError = message
            return nil
        }
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedEndpoint) else {
            validationError = "Endpoint must be an http:// or https:// URL."
            return nil
        }
        validationError = nil
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        return StoredS3Settings(
            endpoint: url,
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKey: accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            pathStyle: pathStyle,
            region: trimmedRegion.isEmpty ? "us-east-1" : trimmedRegion)
    }

    private func save() {
        testResult = nil
        guard let settings = validatedSettings(checkName: true) else { return }
        let profile = ServerProfile(id: existing?.id ?? UUID(),
                                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    settings: settings)
        do {
            if existing == nil {
                try app.add(profile)
            } else {
                try app.update(profile)
            }
            onSaved?(profile)
            dismiss()
        } catch {
            validationError = "Could not save the server: \(ErrorText.describe(error))"
        }
    }

    /// Builds a throwaway client from the current form values and lists the
    /// bucket root. Never touches saved state.
    private func testConnection() {
        testResult = nil
        guard let settings = validatedSettings(checkName: false) else { return }
        let client = S3Client(config: settings.makeS3Config(),
                              transport: URLSessionTransport())
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                let listing = try await client.listObjects(prefix: "", delimiter: "/")
                let count = listing.commonPrefixes.count + listing.objects.count
                testResult = "✓ Connected — \(count) top-level entries"
            } catch {
                testResult = "Connection failed: \(ErrorText.describe(error))"
            }
        }
    }
}

#Preview {
    ServerEditorView(existing: nil)
        .environment(AppModel())
}
