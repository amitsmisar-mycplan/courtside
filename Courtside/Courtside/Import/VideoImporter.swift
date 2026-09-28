import AVFoundation
import CoreTransferable
import OSLog
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A game video that has been copied into `Documents/Games/` and validated.
struct ImportedVideo: Sendable {
    let gameID: UUID
    let filename: String
    let durationSeconds: Double
    let createdAt: Date?
    let fileSize: Int64
}

enum ImportError: LocalizedError {
    case insufficientSpace(required: Int64, available: Int64)
    case noVideoTrack
    case unreadable

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(required, available):
            "This video needs \(Format.bytes(required)) free to import, but only \(Format.bytes(available)) is available. Free up some space and try again."
        case .noVideoTrack:
            "That file doesn't contain any video."
        case .unreadable:
            "Courtside can't read that video. Try a different file."
        }
    }
}

/// Copies picked videos into app storage. Picker URLs are temporary, so every path copies
/// first and never keeps a reference to the source.
enum VideoImporter {
    private static let log = Logger(subsystem: "Courtside", category: "Import")
    private static let copyChunkSize = 8 * 1024 * 1024

    // MARK: Photos

    static func importFromPhotos(
        _ item: PhotosPickerItem,
        progress report: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedVideo {
        let handle = PhotosLoadHandle()
        let staged: StagedPhotosVideo = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let loadProgress = item.loadTransferable(type: StagedPhotosVideo.self) { result in
                    handle.finish()
                    switch result {
                    case .success(let video?): continuation.resume(returning: video)
                    case .success(nil): continuation.resume(throwing: ImportError.unreadable)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                handle.track(loadProgress, report: report)
            }
        } onCancel: {
            handle.cancel()
        }
        return try await finalize(partialURL: staged.partialURL, gameID: staged.gameID, fileExtension: staged.fileExtension)
    }

    /// Runs inside the Photos transfer, while the received file still exists.
    fileprivate static func stage(receivedFile source: URL) throws -> StagedPhotosVideo {
        try requireSpace(forCopying: StorageManager.fileSize(at: source))
        let gameID = UUID()
        let fileExtension = normalizedExtension(of: source)
        let partialURL = partialURL(gameID: gameID, fileExtension: fileExtension)
        // Same volume, so on APFS this is a clone and effectively instant.
        try FileManager.default.copyItem(at: source, to: partialURL)
        return StagedPhotosVideo(partialURL: partialURL, gameID: gameID, fileExtension: fileExtension)
    }

    // MARK: Files

    static func importFromFile(
        at source: URL,
        progress report: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedVideo {
        let isAccessing = source.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { source.stopAccessingSecurityScopedResource() }
        }

        let size = StorageManager.fileSize(at: source)
        try requireSpace(forCopying: size)
        let gameID = UUID()
        let fileExtension = normalizedExtension(of: source)
        let partialURL = partialURL(gameID: gameID, fileExtension: fileExtension)
        do {
            try await copy(from: source, to: partialURL, totalBytes: size, report: report)
        } catch {
            StorageManager.removeFile(at: partialURL)
            throw error
        }
        return try await finalize(partialURL: partialURL, gameID: gameID, fileExtension: fileExtension)
    }

    private static func copy(
        from source: URL,
        to destination: URL,
        totalBytes: Int64,
        report: @Sendable (Double) -> Void
    ) async throws {
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var copied: Int64 = 0
        report(0)
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try input.read(upToCount: copyChunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            report(totalBytes > 0 ? min(1, Double(copied) / Double(totalBytes)) : 0)
        }
        try output.synchronize()
    }

    // MARK: Shared

    /// Validates the staged copy, then moves it to its final name. Deletes it on any failure.
    private static func finalize(partialURL: URL, gameID: UUID, fileExtension: String) async throws -> ImportedVideo {
        let filename = StorageManager.makeGameVideoFilename(id: gameID, fileExtension: fileExtension)
        let finalURL = StorageManager.gameVideoURL(filename: filename)
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: partialURL)
            let videoTracks: [AVAssetTrack]
            do {
                videoTracks = try await asset.loadTracks(withMediaType: .video)
            } catch {
                log.error("Could not read tracks: \(error.localizedDescription)")
                throw ImportError.unreadable
            }
            guard !videoTracks.isEmpty else { throw ImportError.noVideoTrack }

            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ImportError.unreadable }

            var createdAt: Date?
            if let item = try? await asset.load(.creationDate) {
                createdAt = try? await item.load(.dateValue)
            }

            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            return ImportedVideo(
                gameID: gameID,
                filename: filename,
                durationSeconds: duration,
                createdAt: createdAt,
                fileSize: StorageManager.fileSize(at: finalURL)
            )
        } catch {
            StorageManager.removeFile(at: partialURL)
            throw error
        }
    }

    /// Requires 2× the source size free: one copy, plus headroom for clip exports.
    private static func requireSpace(forCopying size: Int64) throws {
        let required = size * 2
        let available = StorageManager.availableCapacity()
        guard available >= required else {
            throw ImportError.insufficientSpace(required: required, available: available)
        }
    }

    /// Keeps the source container (.mov / .mp4) — no transcoding on import.
    private static func normalizedExtension(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "mov" : ext
    }

    private static func partialURL(gameID: UUID, fileExtension: String) -> URL {
        let filename = StorageManager.makeGameVideoFilename(id: gameID, fileExtension: fileExtension)
        return StorageManager.partialURL(for: StorageManager.gameVideoURL(filename: filename))
    }
}

/// Transfer type for `PhotosPickerItem`. The received file is only valid inside the
/// importing closure, so the copy into app storage happens there.
private struct StagedPhotosVideo: Transferable {
    let partialURL: URL
    let gameID: UUID
    let fileExtension: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try VideoImporter.stage(receivedFile: received.file)
        }
    }
}

/// Bridges the Photos load `Progress` to a progress callback and task cancellation.
private final class PhotosLoadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func track(_ progress: Progress, report: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.progress = progress
        observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            report(progress.fractionCompleted)
        }
        if isCancelled { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        progress?.cancel()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        observation?.invalidate()
        observation = nil
    }
}
