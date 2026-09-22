import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a small JPEG poster frame from a local video file, uploaded
/// alongside the clip at `BucketKeys.thumbnailKey`. Best effort by design:
/// any failure returns nil — a clip without a thumbnail is still a valid clip.
nonisolated enum ClipThumbnailer {
    /// Longest edge of the generated frame, in pixels. Big enough for a retina
    /// list row, small enough that the object stays a few tens of KB.
    static let maxDimension: CGFloat = 320

    /// First frame of the video as JPEG data, or nil if the file can't be
    /// read as a video or the frame can't be rendered/encoded.
    static func jpegData(for url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return encodeJPEG(frame)
    }

    /// CGImage -> JPEG via ImageIO (no UIKit/AppKit, so it works from Core on
    /// both platforms).
    static func encodeJPEG(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
