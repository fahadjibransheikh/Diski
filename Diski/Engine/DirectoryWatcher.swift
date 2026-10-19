import CoreServices
import Foundation

/// Watches a set of directories with FSEvents and reports which of them
/// changed. Events for nested paths are mapped to the closest watched
/// directory so a folder refreshes when its children change.
final class DirectoryWatcher {
    /// Called on the main thread with the watched directories that changed and
    /// the folders whose contents changed (the parent of every changed item,
    /// plus folders that changed themselves), used to invalidate folder sizes.
    /// A batch of thousands of file events reports each folder once.
    var onChange: ((_ directories: Set<String>, _ folders: [String]) -> Void)?

    private var stream: FSEventStreamRef?
    /// Written on the main thread, read on the event queue.
    private var watched: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.diski.fsevents", qos: .utility)

    deinit {
        if let stream { DirectoryWatcher.release(stream) }
    }

    /// Replaces the set of watched directories (no-op when unchanged).
    func watch(_ paths: Set<String>) {
        let normalized = Set(paths.map { DirectoryReader.normalized($0) })
        lock.lock()
        let unchanged = normalized == watched
        if !unchanged { watched = normalized }
        lock.unlock()
        guard !unchanged else { return }
        // The new stream runs before the old one stops, so no change falls in
        // between. Stopping on the event queue also waits out a callback in flight.
        let old = stream
        stream = normalized.isEmpty ? nil : makeStream(for: normalized)
        if let old { queue.async { DirectoryWatcher.release(old) } }
    }

    private func makeStream(for paths: Set<String>) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            var events: [(path: String, isFile: Bool)] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, array.count) {
                guard let path = array[index] as? String else { continue }
                let itemFlags = eventFlags[index]
                events.append((path: path, isFile: (itemFlags & fileFlag) != 0 && (itemFlags & dirFlag) == 0))
            }
            watcher.handle(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               Array(paths) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.08, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return stream
    }

    private static func release(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// Runs on the event queue: reduces a batch of item events to the folders
    /// involved, so the main thread sees each folder once.
    private func handle(_ events: [(path: String, isFile: Bool)]) {
        lock.lock()
        let watched = self.watched
        lock.unlock()
        var parents = Set<String>()
        var changedFolders = Set<String>()
        for event in events {
            var path = event.path
            if path != "/" && path.utf8.last == UInt8(ascii: "/") { path.removeLast() }
            // Folders that changed themselves (created, renamed, attributes),
            // and watched items. Events without item flags count as folders.
            if !event.isFile || watched.contains(path) { changedFolders.insert(path) }
            let parent = Self.parent(of: path)
            if !parent.isEmpty { parents.insert(parent) }
        }
        var hit = Set<String>()
        // The changed item itself may be a watched directory (renamed, attributes changed).
        for folder in changedFolders where watched.contains(folder) { hit.insert(folder) }
        // A direct child changed, or something inside a direct child folder
        // (which changes that folder's date and item count).
        for parent in parents {
            if watched.contains(parent) {
                hit.insert(parent)
            } else {
                let grandparent = Self.parent(of: parent)
                if watched.contains(grandparent) { hit.insert(grandparent) }
            }
        }
        let folders = parents.union(changedFolders)
        guard !folders.isEmpty else { return }
        let changed = Array(folders)
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(hit, changed)
        }
    }
}
