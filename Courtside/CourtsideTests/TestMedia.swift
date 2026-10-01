import AVFoundation
import XCTest

/// Generates small test videos: solid frames at a given frame rate, an optional rotation,
/// and an optional continuous 440 Hz tone on the audio track.
enum TestMedia {
    static let audioSampleRate: Double = 44_100

    static func makeVideo(
        at url: URL,
        seconds: Int,
        fps: Int,
        transform: CGAffineTransform = .identity,
        withTone: Bool
    ) async throws {
        let videoURL = withTone ? url.deletingLastPathComponent().appending(path: "video-\(UUID()).mov") : url
        try await writeFrames(to: videoURL, seconds: seconds, fps: fps, transform: transform)
        guard withTone else { return }

        let audioURL = url.deletingLastPathComponent().appending(path: "tone-\(UUID()).m4a")
        try writeTone(to: audioURL, seconds: Double(seconds))

        // Mux video + audio with a passthrough export.
        let video = AVURLAsset(url: videoURL), audio = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let sourceVideo = try await video.loadTracks(withMediaType: .video)[0]
        let sourceAudio = try await audio.loadTracks(withMediaType: .audio)[0]
        let duration = try await video.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(range, of: sourceVideo, at: .zero)
        v.preferredTransform = transform
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try a.insertTimeRange(range, of: sourceAudio, at: .zero)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        session.outputURL = url
        session.outputFileType = .mov
        await session.export()
        if let error = session.error { throw error }
    }

    private static func writeFrames(to url: URL, seconds: Int, fps: Int, transform: CGAffineTransform) async throws {
        let size = CGSize(width: 320, height: 180)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 4 % 256), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: audioSampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(seconds * audioSampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(audioSampleRate))
        }
        try file.write(from: buffer)
    }

    /// RMS loudness of the audio track between `start` and `end` seconds.
    static func audioLevel(of url: URL, from start: Double, to end: Double) async throws -> Float {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var sum: Double = 0, count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for value in data { sum += Double(value * value) }
            count += data.count
        }
        return count == 0 ? 0 : Float((sum / Double(count)).squareRoot())
    }
}
