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

    var body: some View {
        NavigationStack {
            Form {
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
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
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
