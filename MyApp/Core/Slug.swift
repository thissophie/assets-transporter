import Foundation

nonisolated enum Slug {
    /// Lowercased ASCII letters/digits separated by single dashes. Never empty.
    static func make(from name: String) -> String {
        let lowered = (name.applyingTransform(.stripDiacritics, reverse: false) ?? name).lowercased()
        var out = ""
        var pendingDash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "untitled" : out
    }

    /// Ambiguity-free alphabet (no 0/o/1/l/i).
    private static let shortIDAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// 4 chars from an ambiguity-free alphabet (no 0/o/1/l/i).
    static func shortID(using rng: inout some RandomNumberGenerator) -> String {
        String((0..<4).map { _ in shortIDAlphabet.randomElement(using: &rng)! })
    }

    /// "acme-corp" + id -> "acme-corp-x7f2"
    static func slugWithID(_ name: String, id: String) -> String {
        "\(make(from: name))-\(id)"
    }
}
