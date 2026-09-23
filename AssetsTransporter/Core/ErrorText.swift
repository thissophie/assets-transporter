import Foundation

/// Single source of user-facing error text (BrowseModel, ServerEditorView,
/// ProjectDetailView, IntakeModel, …).
///
/// Never includes credentials or HTTP response bodies: a body can echo
/// request details (signed headers, canonical requests) that don't belong in
/// the UI.
nonisolated enum ErrorText {
    static func describe(_ error: any Error) -> String {
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
