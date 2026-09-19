import SwiftUI

/// Validates the raw settings-form strings. Returns nil when valid, otherwise
/// a user-facing message describing the first problem found. Inputs are
/// whitespace-trimmed before checking, matching how the form saves them.
nonisolated enum SettingsValidation {
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

/// S3 connection settings form: edits, validates, saves to the Keychain via
/// AppModel, and can test the connection against the *current form values*
/// (not the saved state).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var pathStyle = true
    @State private var region = "us-east-1"

    @State private var validationError: String?
    @State private var saveConfirmation: String?
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        Form {
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

            if let configError = model.configError {
                Section {
                    Text(configError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Save", action: save)

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
                if let saveConfirmation {
                    Text(saveConfirmation)
                        .foregroundStyle(.secondary)
                }
                if let testResult {
                    Text(testResult)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isConfigured {
                Section {
                    Button("Remove Settings", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                }
            }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .confirmationDialog("Remove the saved S3 settings from the Keychain?",
                            isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("Remove Settings", role: .destructive) {
                model.clearSettings()
                saveConfirmation = nil
                testResult = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: populateFromModel)
    }

    // MARK: - Actions

    private func populateFromModel() {
        guard let settings = model.settings else { return }
        endpoint = settings.endpoint.absoluteString
        bucket = settings.bucket
        accessKey = settings.accessKey
        secretKey = settings.secretKey
        pathStyle = settings.pathStyle
        region = settings.region
    }

    /// Trimmed settings built from the current form values, or nil (with
    /// `validationError` set) when the form does not validate.
    private func validatedSettings() -> StoredS3Settings? {
        if let message = SettingsValidation.validate(endpoint: endpoint, bucket: bucket,
                                                     accessKey: accessKey, secretKey: secretKey) {
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
        saveConfirmation = nil
        testResult = nil
        guard let settings = validatedSettings() else { return }
        do {
            try model.apply(settings)
            saveConfirmation = "Settings saved."
        } catch {
            validationError = "Could not save settings: \(Self.describe(error))"
        }
    }

    /// Builds a throwaway client from the current form values and lists the
    /// bucket root. Never touches saved state.
    private func testConnection() {
        saveConfirmation = nil
        testResult = nil
        guard let settings = validatedSettings() else { return }
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
                testResult = "Connection failed: \(Self.describe(error))"
            }
        }
    }

    /// User-facing error text. Never includes credentials.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case S3Error.http(let status, _):
            return "server returned HTTP \(status)"
        case let urlError as URLError:
            return urlError.localizedDescription
        default:
            return String(describing: error)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
