import AVFoundation
import UIKit

/// Clip thumbnails at the clip midpoint, cached to disk.
enum ThumbnailGenerator {
    static func thumbnail(clipID: UUID, clipURL: URL, clipDuration: Double) async -> UIImage? {
        let cacheURL = StorageManager.thumbnailURL(forClipID: clipID)
        if let data = try? Data(contentsOf: cacheURL), let image = UIImage(data: data) {
            return image
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clipURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // Default tolerance on purpose: zero tolerance is accurate but slow.
        let time = CMTime(seconds: max(0, clipDuration / 2), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }

        let image = UIImage(cgImage: cgImage)
        try? image.jpegData(compressionQuality: 0.8)?.write(to: cacheURL, options: .atomic)
        return image
    }
}
