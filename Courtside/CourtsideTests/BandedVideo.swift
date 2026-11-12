import AVFoundation
import XCTest

/// A test video of 8 vertical gray bands, darkest on the left, so a frame's columns show which
/// part of the source they came from (Vertical zoom and aim tests).
enum BandedVideo {
    static let bands = 8
    /// Gray level of band `index`, far enough apart to tell after compression.
    static func level(_ index: Int) -> Double { Double(16 + index * 30) }

    static func make(at url: URL, size: CGSize, seconds: Int = 2, fps: Int = 10) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let width = Int(size.width), height = Int(size.height)
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            var row = [UInt8](repeating: 255, count: width * 4)
            for x in 0..<width {
                let value = UInt8(level(min(bands - 1, x * bands / width)))
                row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value
            }
            for y in 0..<height {
                row.withUnsafeBytes { (base + y * rowBytes).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: width * 4) }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

/// One decoded frame, readable as gray levels at top-left pixel coordinates.
struct DecodedFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(of url: URL, at seconds: Double) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    /// Average of R, G and B at (x, y), y from the top.
    func gray(x: Int, y: Int) -> Double {
        let i = (y * width + x) * 4
        return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
    }

    /// Mean gray across row `y`, every `step` pixels: a darker row shows bands further left.
    func meanGray(row y: Int, step: Int = 8) -> Double {
        let xs = Array(stride(from: 0, to: width, by: step))
        return xs.map { gray(x: $0, y: y) }.reduce(0, +) / Double(xs.count)
    }
}
