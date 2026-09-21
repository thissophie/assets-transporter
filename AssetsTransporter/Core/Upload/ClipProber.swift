import AVFoundation
import CoreMedia
import Foundation

/// Technical metadata extracted from a local video file before upload.
nonisolated struct ProbedClip: Equatable, Sendable {
    var capturedAt: Date?
    var duration: Double?
    var width: Int?
    var height: Int?
    var codec: String?    // fourCC, e.g. "hvc1"
}

/// Probes local video files with AVFoundation to fill in sidecar metadata.
nonisolated enum ClipProber {

    static func probe(url: URL) async throws -> ProbedClip {
        let asset = AVURLAsset(url: url)
        var probed = ProbedClip()

        probed.capturedAt = await capturedAt(of: asset, url: url)

        let duration = try await asset.load(.duration)
        if duration.isNumeric {
            probed.duration = duration.seconds
        }

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let displaySize = naturalSize.applying(transform)
            probed.width = Int(abs(displaySize.width).rounded())
            probed.height = Int(abs(displaySize.height).rounded())

            if let format = try await track.load(.formatDescriptions).first {
                probed.codec = fourCC(format.mediaSubType.rawValue)
            }
        }

        return probed
    }

    /// Container creation date when present, else the file's creation date.
    private static func capturedAt(of asset: AVURLAsset, url: URL) async -> Date? {
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate
    }

    /// Renders a FourCharCode as its 4-character ASCII string (e.g. "hvc1").
    private static func fourCC(_ code: FourCharCode) -> String? {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
