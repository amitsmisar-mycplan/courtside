import AVFoundation
import UIKit

/// Clip thumbnails at the clip midpoint, cached to disk; uncached stills at any time.
enum ThumbnailGenerator {
    static func thumbnail(clipID: UUID, clipURL: URL, clipDuration: Double) async -> UIImage? {
        let cacheURL = StorageManager.thumbnailURL(forClipID: clipID)
        if let data = try? Data(contentsOf: cacheURL), let image = UIImage(data: data) {
            return image
        }

        guard let image = await frame(of: clipURL, at: clipDuration / 2, maxDimension: 480) else { return nil }
        try? image.jpegData(compressionQuality: 0.8)?.write(to: cacheURL, options: .atomic)
        return image
    }

    /// A still at `seconds`, upright (the track's rotation applied), no larger than `maxDimension`.
    static func frame(of url: URL, at seconds: Double, maxDimension: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Default tolerance on purpose: zero tolerance is accurate but slow.
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
