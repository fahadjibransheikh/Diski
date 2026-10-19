import Foundation

/// App-wide cache of directory listings.
///
/// * Listings are read in the background with `DirectoryReader` and cached,
///   so going back to a folder is instant.
/// * Directories in use are watched with FSEvents and re-read on change.
/// * Refreshes are merged into the existing listing: unchanged entries keep
///   their identity and changed ones are updated in place, so views can
///   animate inserts/removals and keep selection and expansion.
final class DirectoryStore {
    static let shared = DirectoryStore()
    /// Posted on the main thread. `object` is the `Listing`; userInfo["changes"] is `Changes`.
    static let didUpdate = Notification.Name("DiskiDirectoryDidUpdate")
    /// Posted on the main thread when something changed deeper inside folders
    /// listed in a watched directory, so views can refresh those folders' sizes.
    /// userInfo["paths"] is a `Set<String>` of the affected folders.
    static let folderContentsDidChange = Notification.Name("DiskiFolderContentsDidChange")

    struct Changes {
        var inserted: [FileItem] = []
        var removed: [FileItem] = []
        var updated: [FileItem] = []
        var isInitialLoad = false
        var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && updated.isEmpty && !isInitialLoad }
    }

    final class Listing {
        let path: String
        fileprivate(set) var items: [FileItem] = []
        fileprivate(set) var isLoaded = false
        fileprivate(set) var isLoading = false
        fileprivate(set) var error: DirectoryReader.ReadError?
        fileprivate(set) var lastRead = Date.distantPast
        fileprivate var reloadQueued = false
        fileprivate var reloadQoS: DispatchQoS.QoSClass = .utility
        fileprivate var completions: [(Listing) -> Void] = []
        fileprivate var lastUsed = Date()
        /// Nobody watched the folder for a while: changes may have been missed.
        fileprivate var watchLapsed = false
        /// A watcher refresh is already scheduled.
        fileprivate var refreshScheduled = false
        /// How long the last update kept the main thread busy (merge plus observers).
        fileprivate var lastUpdateCost: TimeInterval = 0

        init(path: String) { self.path = path }
    }

    private var listings: [String: Listing] = [:]
    private var watchCounts: [String: Int] = [:]
    let watcher = DirectoryWatcher()
    private var watcherNeedsUpdate = false
    private let readQueue = DispatchQueue(label: "app.diski.read", qos: .userInitiated, attributes: .concurrent)
    private let refreshQueue = DispatchQueue(label: "app.diski.refresh", qos: .utility, attributes: .concurrent)
    private let maxCachedListings = 96

    private init() {
        watcher.onChange = { [weak self] directories, folders, subtrees in
            FolderSizer.shared.invalidate(changedPaths: folders)
            FolderSizer.shared.invalidate(subtrees: subtrees)
            self?.refreshFromWatcher(directories)
            self?.noteNestedChanges(folders, minimumDepth: 0)
            self?.rescan(subtrees)
        }
    }

    /// After dropped or coalesced events under `roots`: re-reads every watched
    /// listing at or under them and re-requests the size of the folders they list.
    private func rescan(_ roots: [String]) {
        guard !roots.isEmpty else { return }
        let paths = Set(watchCounts.keys.filter { path in roots.contains { DirectoryReader.isPath(path, atOrUnder: $0) } })
        guard !paths.isEmpty else { return }
        refreshFromWatcher(paths)
        var folders = Set<String>()
        for path in paths {
            for item in listings[path]?.items ?? [] where item.type == .directory || item.type == .package {
                folders.insert(item.path)
            }
        }
        guard !folders.isEmpty else { return }
        NotificationCenter.default.post(name: Self.folderContentsDidChange, object: self, userInfo: ["paths": folders])
    }

    /// Finds the folders, listed in watched directories, that contain a changed
    /// path below their own level (a file written inside them changes their
    /// size without touching their own attributes). With `minimumDepth` 0 the
    /// changed paths count as changed folders themselves.
    func noteNestedChanges(_ rawPaths: [String], minimumDepth: Int = 1) {
        guard !watchCounts.isEmpty else { return }
        var folders = Set<String>()
        for raw in rawPaths {
            var child = DirectoryReader.normalized(raw)
            var depth = 0
            while let slash = child.lastIndex(of: "/") {
                let parent = slash == child.startIndex ? "/" : String(child[..<slash])
                if depth >= minimumDepth && watchCounts[parent] != nil { folders.insert(child) }
                if parent == "/" || parent == child { break }
                child = parent
                depth += 1
            }
        }
        guard !folders.isEmpty else { return }
        NotificationCenter.default.post(name: Self.folderContentsDidChange, object: self, userInfo: ["paths": folders])
    }

    /// The (possibly not yet loaded) listing for `path`.
    func listing(for rawPath: String) -> Listing {
        let path = DirectoryReader.normalized(rawPath)
        if let listing = listings[path] {
            listing.lastUsed = Date()
            return listing
        }
        let listing = Listing(path: path)
        listings[path] = listing
        evictIfNeeded()
        return listing
    }

    /// Loads `path` if needed. `completion` runs on the main thread once the
    /// listing has content (immediately when it is already cached). A folder
    /// that reads within a frame (16 ms) is applied before this returns, so
    /// the new folder replaces the old one without an empty frame.
    func load(_ path: String, completion: ((Listing) -> Void)? = nil) {
        let listing = self.listing(for: path)
        if listing.isLoaded {
            completion?(listing)
            // Cached listings that went unwatched may be stale: refresh quietly.
            if listing.watchLapsed || (watchCounts[listing.path] == nil && Date().timeIntervalSince(listing.lastRead) > 2) {
                read(listing)
            }
            return
        }
        if let completion { listing.completions.append(completion) }
        read(listing, waitingUpTo: 0.016)
    }

    /// The listing for `path`, read now if it reads within `timeout`; a slower
    /// folder arrives later through `didUpdate` (the listing is empty until then).
    @discardableResult
    func load(_ path: String, waitingUpTo timeout: TimeInterval) -> Listing {
        let listing = self.listing(for: path)
        if !listing.isLoaded {
            if !listing.isLoading { read(listing, waitingUpTo: timeout) }
        } else if listing.watchLapsed {
            read(listing)
        }
        return listing
    }

    /// Reads `path` synchronously on the calling thread (for small, local folders
    /// where waiting a frame would be visible). Returns the listing.
    @discardableResult
    func loadNow(_ path: String) -> Listing {
        let listing = self.listing(for: path)
        if listing.isLoaded {
            // Went unwatched: shown as cached now, refreshed through didUpdate.
            if listing.watchLapsed { read(listing) }
            return listing
        }
        flushWatcher()
        listing.watchLapsed = false
        do {
            let items = try DirectoryReader.read(path: listing.path)
            apply(items: items, error: nil, to: listing)
        } catch let error as DirectoryReader.ReadError {
            apply(items: [], error: error, to: listing)
        } catch {
            apply(items: [], error: DirectoryReader.ReadError(path: listing.path, code: EIO), to: listing)
        }
        return listing
    }

    func reload(_ path: String, completion: ((Listing) -> Void)? = nil) {
        let listing = self.listing(for: path)
        if let completion { listing.completions.append(completion) }
        read(listing)
    }

    /// Re-reads the given directories if Diski has them cached.
    func reload(paths: Set<String>) {
        for path in paths {
            if let listing = listings[DirectoryReader.normalized(path)], listing.isLoaded || listing.isLoading {
                read(listing)
            }
        }
    }

    // MARK: Watching

    func beginWatching(_ rawPath: String) {
        let path = DirectoryReader.normalized(rawPath)
        watchCounts[path, default: 0] += 1
        if watchCounts[path] == 1 { updateWatcher() }
    }

    func endWatching(_ rawPath: String) {
        let path = DirectoryReader.normalized(rawPath)
        guard let count = watchCounts[path] else { return }
        if count <= 1 {
            watchCounts.removeValue(forKey: path)
            // Changes from now on go unseen: the next load re-reads it.
            listings[path]?.watchLapsed = true
            updateWatcher()
        } else {
            watchCounts[path] = count - 1
        }
    }

    /// Restarting the FSEvents stream is a synchronous round trip to fseventsd:
    /// a navigation's end and begin, or a column rebuild's 2N changes, restart
    /// it once per run-loop turn.
    private func updateWatcher() {
        guard !watcherNeedsUpdate else { return }
        watcherNeedsUpdate = true
        DispatchQueue.main.async { [weak self] in self?.flushWatcher() }
    }

    /// Applies a pending watch-set change now. Reads call it first, so the
    /// stream always runs before a folder is read and no change falls in between.
    private func flushWatcher() {
        guard watcherNeedsUpdate else { return }
        watcherNeedsUpdate = false
        watcher.watch(Set(watchCounts.keys))
    }

    /// Re-reads listings the watcher reported, each at most every 8× what its
    /// last update cost the main thread (at most 1 s): small folders stay
    /// instant, a 10k-item folder under a copy refreshes about 5 times a second
    /// and leaves the main thread mostly free.
    private func refreshFromWatcher(_ paths: Set<String>) {
        for path in paths {
            guard let listing = listings[path], listing.isLoaded || listing.isLoading, !listing.refreshScheduled else { continue }
            let wait = listing.lastRead.addingTimeInterval(min(1, listing.lastUpdateCost * 8)).timeIntervalSinceNow
            guard wait > 0.01 else {
                read(listing, qos: .utility)
                continue
            }
            listing.refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                listing.refreshScheduled = false
                self?.read(listing, qos: .utility)
            }
        }
    }

    // MARK: Reading

    /// A read's result, applied exactly once: by the caller that waited for it
    /// or by the main-queue hand-off, whichever comes first.
    private final class PendingRead {
        var items: [FileItem] = []
        var error: DirectoryReader.ReadError?
        var isApplied = false
    }

    /// Reads `listing` in the background. With a `timeout`, the main thread
    /// waits that long for the result and applies it at once when it arrives in
    /// time; otherwise it is applied on a later turn.
    private func read(_ listing: Listing, waitingUpTo timeout: TimeInterval = 0, qos: DispatchQoS.QoSClass = .userInitiated) {
        if listing.isLoading {
            if !listing.reloadQueued || qos == .userInitiated { listing.reloadQoS = qos }
            listing.reloadQueued = true
            return
        }
        flushWatcher()
        listing.isLoading = true
        listing.watchLapsed = false
        let path = listing.path
        let pending = PendingRead()
        let arrived = timeout > 0 ? DispatchSemaphore(value: 0) : nil
        let queue = qos == .utility ? refreshQueue : readQueue
        queue.async { [weak self] in
            do {
                pending.items = try DirectoryReader.read(path: path)
                DirectoryStore.prepare(pending.items)
            } catch let error as DirectoryReader.ReadError {
                pending.error = error
            } catch {
                pending.error = DirectoryReader.ReadError(path: path, code: EIO)
            }
            arrived?.signal()
            DispatchQueue.main.async { self?.finish(pending, for: listing) }
        }
        if let arrived, arrived.wait(timeout: .now() + timeout) == .success {
            finish(pending, for: listing)
        }
    }

    private func finish(_ pending: PendingRead, for listing: Listing) {
        guard !pending.isApplied else { return }
        pending.isApplied = true
        listing.isLoading = false
        apply(items: pending.items, error: pending.error, to: listing)
        if listing.reloadQueued {
            listing.reloadQueued = false
            read(listing, qos: listing.reloadQoS)
        }
    }

    /// Work the views would otherwise do on the main thread the first time
    /// they show fresh items: sort keys, and the kind and thumbnail checks once
    /// per file key. Runs on the read thread, before the items are shared.
    private static func prepare(_ items: [FileItem]) {
        var seen = Set<String>()
        for item in items {
            _ = item.sortKey
            guard item.type == .file || item.type == .package else { continue }
            let key = FileKinds.preparationKey(for: item)
            if seen.insert(key).inserted {
                FileKinds.prepare(for: item)
            }
        }
    }

    private func apply(items newItems: [FileItem], error: DirectoryReader.ReadError?, to listing: Listing) {
        let started = CFAbsoluteTimeGetCurrent()
        var changes = Changes()
        let wasLoaded = listing.isLoaded
        listing.error = error
        listing.lastRead = Date()

        if !wasLoaded {
            listing.items = newItems
            changes.isInitialLoad = true
        } else {
            var old: [String: FileItem] = [:]
            old.reserveCapacity(listing.items.count)
            for item in listing.items { old[item.name] = item }
            var merged: [FileItem] = []
            merged.reserveCapacity(newItems.count)
            for item in newItems {
                if let existing = old.removeValue(forKey: item.name) {
                    // Only a replaced item, a type change, new Finder flags or a re-saved
                    // custom icon change the artwork (not a new size, date or item count).
                    let artworkChanged = existing.fileID != item.fileID || existing.type != item.type
                        || existing.finderFlags != item.finderFlags
                        || (existing.hasCustomIcon && existing.modified != item.modified)
                    if existing.update(from: item) {
                        changes.updated.append(existing)
                        if artworkChanged { IconCache.shared.invalidate(path: existing.path) }
                    }
                    merged.append(existing)
                } else {
                    merged.append(item)
                    changes.inserted.append(item)
                }
            }
            changes.removed = Array(old.values)
            listing.items = merged
        }
        listing.isLoaded = true

        let completions = listing.completions
        listing.completions = []
        for completion in completions { completion(listing) }
        if !changes.isEmpty {
            NotificationCenter.default.post(name: Self.didUpdate, object: listing, userInfo: ["changes": changes])
        }
        // The post is synchronous: this includes every observer's arrange, diff and reload.
        listing.lastUpdateCost = CFAbsoluteTimeGetCurrent() - started
    }

    private func evictIfNeeded() {
        guard listings.count > maxCachedListings else { return }
        let removable = listings.values
            .filter { watchCounts[$0.path] == nil && !$0.isLoading && $0.completions.isEmpty }
            .sorted { $0.lastUsed < $1.lastUsed }
        for listing in removable.prefix(listings.count - maxCachedListings) {
            listings.removeValue(forKey: listing.path)
        }
    }
}
