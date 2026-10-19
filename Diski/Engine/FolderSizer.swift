import AppKit

/// Computes recursive folder sizes in the background with a small pool of
/// single-threaded walks. Results are cached and invalidated by
/// file-system events.
final class FolderSizer {
    static let shared = FolderSizer()

    /// The last size of each folder from earlier walks and launches: shown and
    /// sorted by right away while a fresh walk runs, so a list sorted by size
    /// opens in (nearly) its final order instead of reshuffling.
    private var remembered: [String: Int64] = [:]
    private var rememberedLoaded = false
    private var rememberedSaveScheduled = false
    private let maxRemembered = 20_000
    private lazy var rememberedURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Diski/FolderSizes.plist")
    }()

    struct Result {
        let bytes: Int64
        let items: Int
        let computedAt: Date
    }

    /// Main-thread state.
    private var cache: [String: Result] = [:]
    private var jobs: [String: Walk] = [:]
    private var waiting: [String: [(Result) -> Void]] = [:]
    /// Callers that asked while their folder's walk was already stale: they get
    /// that walk's result and then the one of a fresh walk.
    private var rerunWaiters: [String: [(Result) -> Void]] = [:]
    /// Walks not started yet, newest last (started first: the rows on screen
    /// now matter more than the ones scrolled past).
    private var pending: [(path: String, walk: Walk)] = []
    /// Four single-threaded walks at a time, with no nested worker pool.
    private var running = 0
    private let workQueue = DispatchQueue(label: "app.diski.foldersize", qos: .utility, attributes: .concurrent)
    /// Folders whose next walk waits a little because they keep changing.
    private var deferred = Set<String>()
    /// When the last walk of a slow folder ended and how long it took.
    private var lastWalks: [String: (end: Date, duration: TimeInterval)] = [:]
    private let maxAge: TimeInterval = 180
    /// Bounds `cache`, `walked` and `lastWalks`, which otherwise grow with every folder ever walked.
    var maxCached = 20_000

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.saveRemembered(now: true, synchronously: true)
        }
    }

    /// Folders walked since launch; any other size shown is a remembered one.
    private var walked = Set<String>()

    /// Whether `path` has not been walked since launch, so a size it shows is
    /// only remembered from before and still needs a walk.
    func needsFirstWalk(_ path: String) -> Bool { !walked.contains(path) }

    /// A folder's size from an earlier walk (possibly out of date), if any.
    func rememberedSize(_ path: String) -> Int64? {
        loadRemembered()
        return remembered[path]
    }

    private func loadRemembered() {
        guard !rememberedLoaded else { return }
        rememberedLoaded = true
        guard let data = try? Data(contentsOf: rememberedURL),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: NSNumber] else { return }
        remembered = stored.mapValues { $0.int64Value }
    }

    private func remember(_ path: String, bytes: Int64) {
        loadRemembered()
        guard remembered[path] != bytes else { return }
        if remembered.count >= maxRemembered { remembered.removeAll(keepingCapacity: true) }
        remembered[path] = bytes
        saveRemembered(now: false)
    }

    private func saveRemembered(now: Bool, synchronously: Bool = false) {
        guard rememberedLoaded else { return }
        if !now {
            guard !rememberedSaveScheduled else { return }
            rememberedSaveScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.saveRemembered(now: true) }
            return
        }
        rememberedSaveScheduled = false
        let snapshot = remembered, url = rememberedURL
        let write = {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
        // At quit the write must finish before the process exits.
        if synchronously { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    func cached(_ path: String) -> Result? {
        guard let result = cache[path] else { return nil }
        if Date().timeIntervalSince(result.computedAt) > maxAge {
            cache.removeValue(forKey: path)
            return nil
        }
        return result
    }

    /// Whether an up-to-date walk of `path` is running or scheduled (a walk
    /// whose folder changed while it ran only counts once a rerun is queued).
    func isComputing(_ path: String) -> Bool {
        if deferred.contains(path) { return true }
        guard let walk = jobs[path] else { return false }
        return !walk.isStale || rerunWaiters[path] != nil
    }

    /// Computes (or returns the cached) size; `completion` runs on the main thread.
    func size(of path: String, progress: ((Int64) -> Void)? = nil, completion: @escaping (Result) -> Void) {
        if let result = cached(path) {
            completion(result)
            return
        }
        waiting[path, default: []].append(completion)
        if let running = jobs[path] {
            // A walk that went stale still finishes (a folder that keeps changing
            // would otherwise never get a size); a fresh walk follows it.
            if running.isStale { rerunWaiters[path, default: []].append(completion) }
            return
        }
        if deferred.contains(path) { return }
        schedule(path, progress: progress)
    }

    /// Starts a walk now, or after a pause of twice the last walk's duration
    /// (at most 10 s) for a slow folder that was just walked: a folder that
    /// keeps changing is walked about a third of the time instead of nonstop.
    private func schedule(_ path: String, progress: ((Int64) -> Void)?) {
        if let last = lastWalks[path] {
            let delay = last.end.addingTimeInterval(min(10, last.duration * 2)).timeIntervalSinceNow
            if delay > 0.02 {
                deferred.insert(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.deferred.remove(path) != nil, self.waiting[path] != nil else { return }
                    self.startWalk(path, progress: progress)
                }
                return
            }
        }
        startWalk(path, progress: progress)
    }

    private func startWalk(_ path: String, progress: ((Int64) -> Void)?) {
        let walk = Walk(root: path)
        jobs[path] = walk
        walk.onProgress = progress.map { callback in
            { bytes in DispatchQueue.main.async { callback(bytes) } }
        }
        pending.append((path: path, walk: walk))
        startPendingWalks()
    }

    private func startPendingWalks() {
        while running < 4, let next = pending.popLast() {
            // Cancelled or replaced walks are simply dropped here.
            guard jobs[next.path] === next.walk, !next.walk.isCancelled else { continue }
            running += 1
            let walk = next.walk, path = next.path, start = Date()
            workQueue.async { [weak self] in
                let (bytes, items) = walk.isCancelled ? (Int64(0), 0) : walk.run()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running -= 1
                    self.finish(path, walk: walk, bytes: bytes, items: items,
                                duration: Date().timeIntervalSince(start))
                    self.startPendingWalks()
                }
            }
        }
    }

    private func finish(_ path: String, walk: Walk, bytes: Int64, items: Int, duration: TimeInterval) {
        guard jobs[path] === walk else { return }
        jobs.removeValue(forKey: path)
        guard !walk.isCancelled else {
            waiting[path] = nil
            rerunWaiters[path] = nil
            return
        }
        // Only slow folders are remembered (and so ever deferred).
        if duration >= 0.01 {
            if lastWalks.count >= maxCached { lastWalks.removeAll(keepingCapacity: true) }
            lastWalks[path] = (end: Date(), duration: duration)
        } else {
            lastWalks.removeValue(forKey: path)
        }
        let result = Result(bytes: bytes, items: items, computedAt: Date())
        // A walk that raced with changes is still worth showing, but not caching.
        if cache.count >= maxCached { cache.removeAll(keepingCapacity: true) }
        if !walk.isStale { cache[path] = result }
        if walked.count >= maxCached { walked.removeAll(keepingCapacity: true) }
        walked.insert(path)
        remember(path, bytes: bytes)
        for callback in waiting.removeValue(forKey: path) ?? [] { callback(result) }
        if let again = rerunWaiters.removeValue(forKey: path), !again.isEmpty {
            waiting[path, default: []].append(contentsOf: again)
            if jobs[path] == nil && !deferred.contains(path) { schedule(path, progress: nil) }
        }
    }

    /// Cancels pending and running walks of the direct children of `parent`
    /// (called when the user leaves a folder).
    func cancelJobs(inside parent: String) {
        let prefix = parent == "/" ? "/" : parent + "/"
        let candidates = Set(jobs.keys).union(deferred)
        for path in candidates where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
            cancel(path)
        }
    }

    func cancel(_ path: String) {
        jobs[path]?.cancel()
        jobs.removeValue(forKey: path)
        deferred.remove(path)
        waiting.removeValue(forKey: path)
        rerunWaiters.removeValue(forKey: path)
    }

    /// Drops cached sizes of every folder containing one of `changedPaths`, and
    /// marks walks of those folders that are still running as stale.
    func invalidate(changedPaths: [String]) {
        guard !cache.isEmpty || !jobs.isEmpty else { return }
        var seen = Set<String>()
        for changed in changedPaths {
            var path = DirectoryReader.normalized(changed)
            // Walk up the ancestors: a few hash lookups per event instead of
            // comparing every event with every cached folder.
            while seen.insert(path).inserted {
                cache.removeValue(forKey: path)
                jobs[path]?.isStale = true
                guard let slash = path.lastIndex(of: "/") else { break }
                if slash == path.startIndex {
                    if path == "/" { break }
                    path = "/"
                } else {
                    path = String(path[..<slash])
                }
            }
        }
    }

    /// Drops cached sizes at or under each root and marks their running walks
    /// stale: after dropped FSEvents nothing inside the root can be trusted.
    /// The roots' ancestors are handled by `invalidate(changedPaths:)`.
    func invalidate(subtrees: [String]) {
        guard !subtrees.isEmpty, !cache.isEmpty || !jobs.isEmpty else { return }
        let roots = subtrees.map(DirectoryReader.normalized)
        cache = cache.filter { entry in !roots.contains { DirectoryReader.isPath(entry.key, atOrUnder: $0) } }
        for (path, walk) in jobs where roots.contains(where: { DirectoryReader.isPath(path, atOrUnder: $0) }) {
            walk.isStale = true
        }
    }

    // MARK: - Walk

    final class Walk {
        /// Set on the main thread when the folder changes while the walk runs.
        var isStale = false
        private let condition = NSLock()
        private var stack: [String]
        private var bytes: Int64 = 0
        private var items = 0
        /// Inodes of hard-linked files already counted: each is counted once per walk.
        /// The walk stays on one volume (mount points are skipped), so inode numbers are unique.
        private var seenLinks = Set<UInt64>()
        private var cancelled = false
        private var lastReport = Date.distantPast
        var onProgress: ((Int64) -> Void)?

        init(root: String) {
            stack = [root]
        }

        var isCancelled: Bool {
            condition.lock(); defer { condition.unlock() }
            return cancelled
        }

        func cancel() {
            condition.lock()
            cancelled = true
            condition.unlock()
        }

        func run() -> (Int64, Int) {
            guard let root = stack.first else { return (0, 0) }
            var ancestor = DirectoryReader.normalized(root)
            var ancestors = [ancestor]
            while ancestor != "/" {
                ancestor = (ancestor as NSString).deletingLastPathComponent
                ancestors.append(ancestor)
            }
            for path in ancestors.reversed() {
                guard !isCancelled, !DirectoryReader.isDataless(path) else { return (0, 0) }
            }
            work()
            return (bytes, items)
        }

        private func work() {
            var buffer: DirectoryReader.Buffer?
            // Dataless subfolders are skipped from their entry's flags; run() checked the root.
            while !isCancelled, let directory = stack.popLast() {
                var subdirectories: [String] = []
                var localBytes: Int64 = 0
                var localItems = 0
                let prefix = directory == "/" ? "/" : directory + "/"
                let reader = buffer ?? DirectoryReader.Buffer()
                buffer = reader
                var entriesUntilCancellationCheck = 0
                var continuing = true
                try? DirectoryReader.forEachRawEntry(inDirectory: directory, buffer: reader, linkInfo: true, shouldContinue: {
                    if entriesUntilCancellationCheck == 0 {
                        continuing = !self.isCancelled
                        entriesUntilCancellationCheck = 256
                    }
                    entriesUntilCancellationCheck -= 1
                    return continuing
                }) { entry in
                    localItems += 1
                    if entry.isDirectory {
                        if !entry.isMountPoint && !entry.isDataless { subdirectories.append(prefix + entry.nameString) }
                    } else if entry.size > 0, entry.linkCount <= 1 || self.seenLinks.insert(entry.fileID).inserted {
                        localBytes += entry.size
                    }
                }

                stack.append(contentsOf: subdirectories)
                bytes += localBytes
                items += localItems
                var report: Int64? = nil
                if onProgress != nil, Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    report = bytes
                }
                if let report { onProgress?(report) }
            }
        }
    }
}
