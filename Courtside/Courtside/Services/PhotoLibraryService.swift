import Photos
import UIKit

/// What Courtside may do with the photo library. Add-only: it never reads the parent's photos.
enum PhotoAccess: Equatable {
    case granted
    /// Denied, or restricted by Screen Time or a device profile. Only Settings can change it.
    case denied
}

enum PhotoSaveError: LocalizedError {
    case failed(Error?)

    var errorDescription: String? {
        "The video couldn't be saved to Photos. Check there's space on your phone and try again."
    }
}

/// Saving to the camera roll. Behind a protocol so the export flow can be tested without Photos.
protocol PhotoLibrarySaving: Sendable {
    /// Asks the first time; afterwards returns the parent's answer.
    func requestAddAccess() async -> PhotoAccess
    func saveVideo(at url: URL) async throws
}

struct PhotoLibraryService: PhotoLibrarySaving {
    func requestAddAccess() async -> PhotoAccess {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: .granted
        default: .denied
        }
    }

    func saveVideo(at url: URL) async throws {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }
        } catch {
            throw PhotoSaveError.failed(error)
        }
    }

    /// Where the parent can turn Photos access back on.
    @MainActor static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
}
