import Foundation

/// Labelled copies made for Save to Photos and Share, kept while the app runs so doing the same
/// clip again is instant (decision 0021). The files live in the temporary exports folder:
/// `StorageManager` removes them when their clip or game is deleted, and at the next launch.
///
/// A copy is reused only for the same clip, source file (unchanged since), format, label text,
/// quality and Vertical zoom and aim (decisions 0024 and 0028). Anything else replaces it, and the old file is removed.
@MainActor
final class LabelledExportCache {
    static let shared = LabelledExportCache()

    /// Copies kept at once; the oldest goes first. 4K full-quality copies are ~60 MB each.
    static let limit = 4

    struct Key: Hashable {
        let clipID: UUID
        let source: SourceStamp
        let format: ExportFormat
        let label: LabelStep.LabelText
        let quality: LabelledExportQuality
        /// Vertical zoom and aim, rounded so the same look reuses its copy; nil for Original and zoom 0 layouts.
        let framing: VerticalFraming?
        /// Aim points when the aim moves (decision 0028), rounded the same way; nil for one aim.
        let aim: AimPath?

        init(
            clipID: UUID, source: SourceStamp, format: ExportFormat, label: LabelStep.LabelText,
            quality: LabelledExportQuality, framing: VerticalFraming? = nil, aim: AimPath? = nil
        ) {
            self.clipID = clipID
            self.source = source
            self.format = format
            self.label = label
            self.quality = quality
            self.framing = framing?.rounded
            self.aim = aim?.rounded
        }

        /// One copy per clip, source file and format; a new key for the same slot replaces it.
        var slot: Slot { Slot(clipID: clipID, sourceName: source.name, format: format) }
    }

    struct Slot: Hashable {
        let clipID: UUID
        let sourceName: String
        let format: ExportFormat
    }

    /// The source file as it is now: a trim or new slow mo rewrites it, which changes this.
    struct SourceStamp: Hashable {
        let name: String
        let size: Int64
        let modified: Date?

        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            name = url.lastPathComponent
            size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            modified = attributes?[.modificationDate] as? Date
        }
    }

    private struct Entry {
        let key: Key
        let url: URL
    }

    /// Oldest first.
    private var entries: [Entry] = []

    /// The cached copy for `key`, if there is one and its file is still there. A copy for the same
    /// clip and format made with anything different is stale: it's removed.
    func file(for key: Key) -> URL? {
        for entry in entries where entry.key.slot == key.slot && (entry.key != key || !StorageManager.fileExists(at: entry.url)) {
            remove(entry)
        }
        return entries.first { $0.key == key }?.url
    }

    /// Takes ownership of a finished export at `url`.
    func store(_ url: URL, for key: Key) {
        for entry in entries where entry.key.slot == key.slot {
            remove(entry)
        }
        entries.append(Entry(key: key, url: url))
        while entries.count > Self.limit {
            remove(entries[0])
        }
    }

    /// Removes every cached copy (tests, and the timing check).
    func removeAll() {
        entries.forEach(remove)
    }

    private func remove(_ entry: Entry) {
        StorageManager.removeExport(at: entry.url)
        entries.removeAll { $0.url == entry.url }
    }
}
