import Foundation

struct Note {
    let id: String
    var created: Date
    var modified: Date
    private(set) var title: String
    private(set) var preview: String
    var text: String {
        didSet {
            let s = Note.summarize(text)
            title = s.title
            preview = s.preview
        }
    }

    init(id: String, text: String, created: Date, modified: Date) {
        self.id = id
        self.text = text
        self.created = created
        self.modified = modified
        let s = Note.summarize(text)
        title = s.title
        preview = s.preview
    }

    var isBlank: Bool { text.allSatisfy(\.isWhitespace) }

    static func summarize(_ text: String) -> (title: String, preview: String) {
        var found: [String] = []
        for raw in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            let clean = strip(line)
            if clean.isEmpty || clean.allSatisfy({ "-*_= ".contains($0) }) { continue }
            found.append(clean)
            if found.count == 2 { break }
        }
        return (found.first.map { String($0.prefix(100)) } ?? "Untitled",
                found.count > 1 ? String(found[1].prefix(140)) : "")
    }

    private static func strip(_ s: String) -> String {
        var r = s.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s*)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(\*\*|__|~~|==|`|(?<!\w)[*_]|[*_](?!\w))"#, with: "", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespaces)
    }
}

extension Notification.Name {
    /// Posted when notes changed on disk (another device via iCloud, or another editor).
    /// `userInfo["ids"]` holds the affected note ids.
    static let notesChangedOnDisk = Notification.Name("MiniNotes.notesChangedOnDisk")
}

/// Notes are plain `.md` files in a folder. Writes are debounced and blank notes never hit disk.
/// The folder is watched, so edits arriving from iCloud Drive (or any other app) show up live.
@MainActor
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [String: Note] = [:]
    private(set) var folder: URL
    private var dirty = Set<String>()
    /// File modification date last seen (or written) per note; used to detect external changes.
    private var diskDates: [String: Date] = [:]
    private var saveWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private let fm = FileManager.default
    private let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]

    private init() {
        folder = Prefs.notesFolder
        load()
    }

    // MARK: - iCloud Drive

    static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var iCloudFolder: URL { iCloudDriveRoot.appendingPathComponent("Mini Notes", isDirectory: true) }

    static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDriveRoot.path) }

    var isInICloud: Bool {
        folder.resolvingSymlinksInPath().path.hasPrefix(Self.iCloudDriveRoot.resolvingSymlinksInPath().path)
    }

    /// Copies every note into `dest` (keeping the newer version when a file already exists there),
    /// optionally removes the old files, and switches to `dest`.
    func migrate(to dest: URL, removeSources: Bool) throws {
        flush()
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for note in notes.values where !note.isBlank {
            let target = dest.appendingPathComponent(note.id).appendingPathExtension("md")
            if fm.fileExists(atPath: target.path),
               let date = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date >= note.modified {
                continue
            }
            try note.text.write(to: target, atomically: false, encoding: .utf8)
            try? fm.setAttributes([.creationDate: note.created, .modificationDate: note.modified], ofItemAtPath: target.path)
        }
        if removeSources {
            for note in notes.values { try? fm.removeItem(at: fileURL(note.id)) }
        }
        setFolder(dest)
    }

    func setFolder(_ url: URL) {
        flush()
        folder = url
        Prefs.notesFolder = url
        load()
    }

    // MARK: - Loading

    func load() {
        notes = [:]
        diskDates = [:]
        dirty = []
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in noteFiles() {
            guard let (note, date) = read(url) else { continue }
            notes[note.id] = note
            diskDates[note.id] = date
        }
        watch()
    }

    /// Re-reads the folder and merges changes made elsewhere. Unsaved local edits always win.
    func refreshFromDisk() {
        var changed = Set<String>()
        var seen = Set<String>()
        for url in noteFiles() {
            let id = Self.id(of: url)
            seen.insert(id)
            guard !dirty.contains(id) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date == diskDates[id] { continue }
            guard let (note, diskDate) = read(url) else { continue }
            diskDates[id] = diskDate
            if notes[id]?.text != note.text {
                notes[id] = note
                changed.insert(id)
            }
        }
        // Files that were on disk before and are gone now were deleted elsewhere.
        for id in notes.keys where !seen.contains(id) && !dirty.contains(id) && diskDates[id] != nil {
            notes[id] = nil
            diskDates[id] = nil
            changed.insert(id)
        }
        if !changed.isEmpty {
            NotificationCenter.default.post(name: .notesChangedOnDisk, object: self, userInfo: ["ids": changed])
        }
    }

    private func noteFiles() -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        var files: [URL] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                // Legacy iCloud placeholder for an evicted file (".Note.md.icloud"): ask for it.
                if name.hasSuffix(".md.icloud") {
                    let real = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    try? fm.startDownloadingUbiquitousItem(at: real)
                }
                continue
            }
            if url.pathExtension.lowercased() == "md" { files.append(url) }
        }
        return files
    }

    private func read(_ url: URL) -> (Note, Date)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = try? url.resourceValues(forKeys: Set(keys))
        let modified = values?.contentModificationDate ?? Date()
        return (Note(id: Self.id(of: url), text: text, created: values?.creationDate ?? modified, modified: modified), modified)
    }

    private static func id(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private func watch() {
        watcher?.cancel()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .delete, .rename, .link, .attrib],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFromDisk() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Editing

    var byModified: [Note] { notes.values.sorted { $0.modified > $1.modified } }
    var byCreated: [Note] { notes.values.sorted { $0.created < $1.created } }

    func note(_ id: String) -> Note? { notes[id] }

    @discardableResult
    func create(text: String = "") -> Note {
        let id = Self.makeID()
        let now = Date()
        let note = Note(id: id, text: text, created: now, modified: now)
        notes[id] = note
        if !note.isBlank { markDirty(id) }
        return note
    }

    func update(_ id: String, text: String) {
        guard var note = notes[id], note.text != text else { return }
        note.text = text
        note.modified = Date()
        notes[id] = note
        markDirty(id)
    }

    func delete(_ id: String) {
        notes[id] = nil
        dirty.remove(id)
        diskDates[id] = nil
        let url = fileURL(id)
        if fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func discardIfBlank(_ id: String) {
        if let n = notes[id], n.isBlank { delete(id) }
    }

    func flush() {
        saveWork?.cancel()
        saveWork = nil
        for id in dirty {
            guard let note = notes[id] else { continue }
            let url = fileURL(id)
            if note.isBlank {
                try? fm.removeItem(at: url)
                diskDates[id] = nil
            } else {
                // Non-atomic on purpose: keeps the file's creation date stable.
                try? note.text.write(to: url, atomically: false, encoding: .utf8)
                diskDates[id] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        dirty.removeAll()
    }

    private func markDirty(_ id: String) {
        dirty.insert(id)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func fileURL(_ id: String) -> URL { folder.appendingPathComponent(id).appendingPathExtension("md") }

    private static func makeID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(f.string(from: Date()))-\(suffix)"
    }
}
