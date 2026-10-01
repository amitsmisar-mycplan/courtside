import AVFoundation

enum SlowMoError: LocalizedError {
    case noVideoTrack
    case couldNotBuild

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This clip has no video to slow down."
        case .couldNotBuild: "The slow-motion version couldn't be built from this clip."
        }
    }
}

/// Builds the three-part slow-motion composition: `[1×][slow][1×]`. The same composition
/// backs the instant preview and the final render.
enum SlowMoComposer {
    private static let timescale: CMTimeScale = 600

    /// Frame rate of the clip's video track (not the asset), which caps the available speeds.
    static func videoFrameRate(of url: URL) async throws -> Float {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else {
            throw SlowMoError.noVideoTrack
        }
        return try await track.load(.nominalFrameRate)
    }

    static func composition(clipURL: URL, segment: SlowMoSegment, speed: SlowMoSpeed) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: clipURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw SlowMoError.noVideoTrack
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let (assetDuration, transform) = (try await asset.load(.duration), try await sourceVideo.load(.preferredTransform))

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SlowMoError.couldNotBuild
        }
        let fullRange = CMTimeRange(start: .zero, duration: assetDuration)
        try video.insertTimeRange(fullRange, of: sourceVideo, at: .zero)
        // Without this, portrait and rotated footage renders sideways.
        video.preferredTransform = transform

        let slowStart = time(segment.start)
        let slowEnd = CMTimeMinimum(time(segment.end), assetDuration)
        let slowRange = CMTimeRange(start: slowStart, end: slowEnd)
        let stretched = CMTimeMultiplyByFloat64(slowRange.duration, multiplier: 1 / speed.rawValue)
        // The only scale operation: later time ranges shift after a scale, so never compose several.
        video.scaleTimeRange(slowRange, toDuration: stretched)

        if let sourceAudio {
            // Scaled audio sounds pitch-shifted and slurred, so it isn't scaled:
            // normal audio, silence for the stretched segment, normal audio.
            guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw SlowMoError.couldNotBuild
            }
            if slowStart > .zero {
                try audio.insertTimeRange(CMTimeRange(start: .zero, end: slowStart), of: sourceAudio, at: .zero)
            }
            audio.insertEmptyTimeRange(CMTimeRange(start: slowStart, duration: stretched))
            if slowEnd < assetDuration {
                try audio.insertTimeRange(
                    CMTimeRange(start: slowEnd, end: assetDuration),
                    of: sourceAudio,
                    at: slowStart + stretched
                )
            }
        }
        return composition
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }
}
