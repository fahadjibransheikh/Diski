import Darwin
import Foundation

enum ConflictResolution {
    case keepBoth, replace, merge, skip, stop
}

/// Asks the user what to do when an item already exists at the destination.
/// Called on a worker thread; implementations block until the user decides.
protocol ConflictResolving: AnyObject {
    func resolveConflict(source: URL, existing: URL, operation: FileOperation) -> (ConflictResolution, applyToAll: Bool)
}

/// The copy/move engine.
///
/// * Same-volume moves are a single `rename(2)` per item.
/// * Same-volume copies on APFS are `clonefile(2)` calls: whole folder trees are
///   cloned copy-on-write in one system call, instantly, using no extra space.
/// * Everything else streams through a pool of parallel workers: folders are
///   scanned first (so totals are known almost immediately), files are copied
///   concurrently with `fcopyfile`, large files bypass the page cache, and
///   folder metadata is applied last.
final class CopyEngine {
    enum Mode { case copy, move, duplicate }

    let operation: FileOperation
    let mode: Mode
    weak var resolver: ConflictResolving?
    var useClones = true
    var streams = 6

    private(set) var created: [URL] = []
    /// (original location, new location) for moved items.
    private(set) var moved: [(from: URL, to: URL)] = []
    private(set) var replaced: [(original: URL, trashed: URL)] = []
    private(set) var errors: [String] = []
    /// Entries undo may trash: only what this run created.
    private(set) var undoCreated: [URL] = []

    private var rememberedResolution: ConflictResolution?
    private let stateLock = NSLock()

    init(operation: FileOperation, mode: Mode) {
        self.operation = operation
        self.mode = mode
    }

    // MARK: - Entry point (worker thread)

    func run() {
        operation.update {
            $0.totalItems = operation.sources.count
            $0.scanning = true
        }
        for source in operation.sources {
            guard operation.waitIfPaused() else { break }
            process(source)
        }
        operation.update { $0.scanning = false }
    }

    private func recordError(_ message: String) {
        stateLock.lock()
        if errors.count < 50 { errors.append(message) }
        stateLock.unlock()
    }

    /// Puts a trashed original back after the copy that replaced it failed or was cancelled.
    private func restoreReplaced(at path: String) {
        let url = URL(fileURLWithPath: path)
        stateLock.lock()
        let index = replaced.firstIndex { $0.original == url }
        let entry = index.map { replaced.remove(at: $0) }
        stateLock.unlock()
        guard let entry else { return }
        if renamex_np(entry.trashed.path, path, Self.renameExcl) != 0 {
            // Keep the entry so the ledger still records it and Put Back can restore it later.
            stateLock.lock(); replaced.append(entry); stateLock.unlock()
            recordError("“\(url.lastPathComponent)” couldn’t be put back; it is in the Trash.")
        }
    }

    /// Moves an existing file to the Trash so a merge can replace it; recorded so it can be restored or put back.
    private func trashForReplace(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil, let trashedURL = trashed as URL? else {
            recordError("“\(url.lastPathComponent)” couldn’t be replaced.")
            return false
        }
        stateLock.lock(); replaced.append((url, trashedURL)); stateLock.unlock()
        return true
    }

    private func recordUndoCreated(_ path: String) {
        stateLock.lock()
        undoCreated.append(URL(fileURLWithPath: path))
        stateLock.unlock()
    }

    // MARK: - Top-level items

    private func process(_ source: URL) {
        let srcPath = DirectoryReader.normalized(source.path)
        let name = (srcPath as NSString).lastPathComponent
        let srcParent = (srcPath as NSString).deletingLastPathComponent
        operation.update { $0.currentName = name }

        var st = stat()
        guard lstat(srcPath, &st) == 0 else {
            recordError("“\(name)” couldn’t be found.")
            finishTopLevelItem()
            return
        }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        let destDir: String
        switch mode {
        case .duplicate:
            destDir = srcParent
        case .copy, .move:
            destDir = DirectoryReader.normalized(operation.destination?.path ?? srcParent)
        }

        if isDirectory && (destDir == srcPath || destDir.hasPrefix(srcPath + "/")) {
            recordError("“\(name)” can’t be \(mode == .move ? "moved" : "copied") into itself.")
            finishTopLevelItem()
            return
        }

        var dstPath = join(destDir, name)
        let isPackageOrFile = !isDirectory || FileKinds.isPackage(name: name, finderFlags: 0)
        if mode == .duplicate || (mode == .copy && srcParent == destDir) {
            dstPath = join(destDir, Self.uniqueName(for: name, in: destDir, style: .copy, splitExtension: isPackageOrFile))
        } else if mode == .move && srcParent == destDir {
            finishTopLevelItem()
            return
        }

        var merge = false
        var existing = stat()
        if lstat(dstPath, &existing) == 0 {
            var resolution = rememberedResolution
            if resolution == nil {
                let answer = resolver?.resolveConflict(source: URL(fileURLWithPath: srcPath),
                                                       existing: URL(fileURLWithPath: dstPath),
                                                       operation: operation) ?? (.keepBoth, false)
                resolution = answer.0
                if answer.applyToAll { rememberedResolution = answer.0 }
            }
            switch resolution ?? .keepBoth {
            case .stop:
                operation.cancel()
                return
            case .skip:
                finishTopLevelItem()
                return
            case .keepBoth:
                dstPath = join(destDir, Self.uniqueName(for: name, in: destDir, style: .number, splitExtension: isPackageOrFile))
            case .replace:
                let existingURL = URL(fileURLWithPath: dstPath)
                do {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: existingURL, resultingItemURL: &trashed)
                    if let trashed = trashed as URL? {
                        stateLock.lock(); replaced.append((existingURL, trashed)); stateLock.unlock()
                    }
                } catch {
                    recordError("“\(name)” couldn’t be replaced: \(error.localizedDescription)")
                    finishTopLevelItem()
                    return
                }
            case .merge:
                if isDirectory && (existing.st_mode & S_IFMT) == S_IFDIR {
                    merge = true
                } else {
                    dstPath = join(destDir, Self.uniqueName(for: name, in: destDir, style: .number, splitExtension: isPackageOrFile))
                }
            }
        }

        let sameDevice = deviceID(destDir) == st.st_dev

        // 1. Same-volume move: one rename.
        if mode == .move && sameDevice && !merge {
            if renamex_np(srcPath, dstPath, Self.renameExcl) == 0 {
                moved.append((URL(fileURLWithPath: srcPath), URL(fileURLWithPath: dstPath)))
                created.append(URL(fileURLWithPath: dstPath))
                undoCreated.append(URL(fileURLWithPath: dstPath))
                finishTopLevelItem()
                return
            }
            if errno != EXDEV {
                recordError("“\(name)” couldn’t be moved: \(String(cString: strerror(errno)))")
                restoreReplaced(at: dstPath)
                finishTopLevelItem()
                return
            }
        }

        // 2. Same-volume copy: APFS clone (instant, copy-on-write, whole trees at once).
        if mode != .move && sameDevice && useClones && !merge {
            if clonefile(srcPath, dstPath, Self.cloneNoFollow) == 0 {
                created.append(URL(fileURLWithPath: dstPath))
                undoCreated.append(URL(fileURLWithPath: dstPath))
                finishTopLevelItem()
                return
            }
            // ENOTSUP (not APFS) and friends fall through to a real copy.
        }

        // 3. Real copy (cross-volume, or the file system can't clone).
        operation.update { $0.instant = false }
        let ok: Bool
        if isDirectory {
            ok = copyTree(from: srcPath, to: dstPath, merge: merge, sameDevice: sameDevice)
        } else {
            let size = Int64(st.st_size)
            operation.update { $0.totalBytes += size }
            ok = copyFile(from: srcPath, to: dstPath, size: size,
                          isSymlink: (st.st_mode & S_IFMT) == S_IFLNK, sameDevice: sameDevice)
        }

        if ok && !operation.isCancelled {
            created.append(URL(fileURLWithPath: dstPath))
            // A merge reuses the existing folder: undo must not trash or move it back (only the entries recorded in copyTree).
            if !merge { undoCreated.append(URL(fileURLWithPath: dstPath)) }
            if mode == .move {
                do {
                    try FileManager.default.removeItem(atPath: srcPath)
                    if !merge { moved.append((URL(fileURLWithPath: srcPath), URL(fileURLWithPath: dstPath))) }
                } catch {
                    recordError("“\(name)” was copied but the original couldn’t be removed: \(error.localizedDescription)")
                }
            }
        } else if !merge {
            // Never leave a half-copied item behind.
            try? FileManager.default.removeItem(atPath: dstPath)
            restoreReplaced(at: dstPath)
        }
        finishTopLevelItem()
    }

    private func finishTopLevelItem() {
        operation.update { $0.completedItems += 1 }
    }

    // MARK: - Single files

    private final class ProgressContext {
        let operation: FileOperation
        var reported: Int64 = 0
        private var lastReport = DispatchTime.now().uptimeNanoseconds
        init(operation: FileOperation) { self.operation = operation }

        /// Returns false to abort the copy.
        func report(_ copied: Int64) -> Bool {
            let delta = copied - reported
            let now = DispatchTime.now().uptimeNanoseconds
            if delta > 0 && now - lastReport >= 100_000_000 {
                lastReport = now
                reported = copied
                operation.update { $0.completedBytes += delta }
            }
            return operation.waitIfPaused()
        }
    }

    private static let progressCallback: copyfile_callback_t = { what, stage, state, _, _, context in
        guard what == 4 /* COPYFILE_COPY_DATA */, stage == 4 /* COPYFILE_PROGRESS */, let context else {
            return 0 // COPYFILE_CONTINUE
        }
        var copied: off_t = 0
        copyfile_state_get(state, 8 /* COPYFILE_STATE_COPIED */, &copied)
        let progress = Unmanaged<ProgressContext>.fromOpaque(context).takeUnretainedValue()
        return progress.report(Int64(copied)) ? 0 : 2 // COPYFILE_QUIT
    }

    /// Copies one file or symlink. Progress bytes for `size` are accounted here.
    private func copyFile(from src: String, to dst: String, size: Int64, isSymlink: Bool, sameDevice: Bool) -> Bool {
        if isSymlink {
            let ok = copyfile(src, dst, nil, Self.flagsAll | Self.flagNoFollow | Self.flagExcl) == 0
            if !ok { recordError("“\((src as NSString).lastPathComponent)”: \(String(cString: strerror(errno)))") }
            operation.update { $0.completedBytes += size }
            return ok
        }
        if sameDevice && useClones && clonefile(src, dst, Self.cloneNoFollow) == 0 {
            operation.update { $0.completedBytes += size }
            return true
        }

        let sfd = open(src, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sfd >= 0 else {
            recordError("“\((src as NSString).lastPathComponent)” couldn’t be read: \(String(cString: strerror(errno)))")
            operation.update { $0.completedBytes += size }
            return false
        }
        defer { close(sfd) }
        let dfd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard dfd >= 0 else {
            recordError("“\((dst as NSString).lastPathComponent)” couldn’t be written: \(String(cString: strerror(errno)))")
            operation.update { $0.completedBytes += size }
            return false
        }

        if size >= 8 * 1024 * 1024 {
            // Stream big files around the buffer cache: steadier throughput, no memory pressure.
            _ = fcntl(sfd, F_NOCACHE, 1)
            _ = fcntl(dfd, F_NOCACHE, 1)
        }

        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let context = ProgressContext(operation: operation)
        if size >= 2 * 1024 * 1024 {
            copyfile_state_set(state, 6 /* COPYFILE_STATE_STATUS_CB */,
                               unsafeBitCast(Self.progressCallback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, 7 /* COPYFILE_STATE_STATUS_CTX */,
                               Unmanaged.passUnretained(context).toOpaque())
        }
        let result = withExtendedLifetime(context) {
            fcopyfile(sfd, dfd, state, Self.flagsAll | Self.flagDataSparse)
        }
        let failure = errno
        close(dfd)

        // Account for whatever the progress callback didn't report.
        let remaining = size - context.reported
        if remaining > 0 { operation.update { $0.completedBytes += remaining } }

        if result != 0 {
            if !operation.isCancelled {
                recordError("“\((src as NSString).lastPathComponent)” couldn’t be copied: \(String(cString: strerror(failure)))")
            }
            unlink(dst)
            return false
        }
        return true
    }

    // MARK: - Folder trees

    private enum Task {
        case directory(src: String, dst: String, exists: Bool)
        case file(src: String, dst: String, size: Int64, symlink: Bool, merging: Bool)
    }

    /// Work queue shared by the copy workers. Folder tasks are served first so
    /// the whole tree is discovered (and the total size known) quickly.
    private final class TaskQueue {
        let condition = NSCondition()
        var directories: [Task] = []
        var files: [Task?] = []
        var fileHead = 0
        var inFlight = 0
        var directoriesInFlight = 0
        var finalize: [(String, String)] = []
        var failed = false

        func push(_ task: Task) {
            condition.lock()
            if case .directory = task { directories.append(task) } else { files.append(task) }
            condition.signal()
            condition.unlock()
        }

        func push(contentsOf tasks: [Task]) {
            guard !tasks.isEmpty else { return }
            condition.lock()
            for task in tasks {
                if case .directory = task { directories.append(task) } else { files.append(task) }
            }
            condition.broadcast()
            condition.unlock()
        }

        func next(cancelled: () -> Bool) -> Task? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if cancelled() { condition.broadcast(); return nil }
                if let task = directories.popLast() {
                    inFlight += 1
                    directoriesInFlight += 1
                    return task
                }
                if fileHead < files.count {
                    let task = files[fileHead]
                    files[fileHead] = nil
                    fileHead += 1
                    if fileHead >= 1024 && fileHead * 2 >= files.count {
                        files.removeFirst(fileHead)
                        fileHead = 0
                    }
                    inFlight += 1
                    return task
                }
                if inFlight == 0 { condition.broadcast(); return nil }
                condition.wait()
            }
        }

        /// Marks a task finished. Returns true when folder scanning just completed.
        func done(_ task: Task) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            inFlight -= 1
            var scanFinished = false
            if case .directory = task {
                directoriesInFlight -= 1
                scanFinished = directoriesInFlight == 0 && directories.isEmpty
            }
            condition.broadcast()
            return scanFinished
        }
    }

    private func copyTree(from src: String, to dst: String, merge: Bool, sameDevice: Bool) -> Bool {
        let queue = TaskQueue()
        queue.push(.directory(src: src, dst: dst, exists: merge))
        let workers = max(1, streams)

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            // One read buffer per worker thread, reused for every folder it scans; never shared.
            let buffer = DirectoryReader.Buffer()
            while let task = queue.next(cancelled: { self.operation.isCancelled }) {
                guard operation.waitIfPaused() else {
                    _ = queue.done(task)
                    break
                }
                switch task {
                case let .directory(s, d, exists):
                    if !copyDirectoryEntries(src: s, dst: d, exists: exists, queue: queue, buffer: buffer) {
                        queue.condition.lock(); queue.failed = true; queue.condition.unlock()
                    }
                case let .file(s, d, size, symlink, merging):
                    operation.update { $0.currentName = (s as NSString).lastPathComponent }
                    var existing = stat()
                    var didReplace = false
                    var proceed = true
                    // Merging: a file that already exists is replaced (the old one goes to the Trash).
                    if merging && lstat(d, &existing) == 0 {
                        didReplace = trashForReplace(d)
                        proceed = didReplace
                        if !proceed { operation.update { $0.completedBytes += size } }
                    }
                    if proceed && copyFile(from: s, to: d, size: size, isSymlink: symlink, sameDevice: sameDevice) {
                        // Files inside a folder this run created are covered by that folder.
                        if merging { recordUndoCreated(d) }
                    } else {
                        if proceed && didReplace { restoreReplaced(at: d) }
                        queue.condition.lock(); queue.failed = true; queue.condition.unlock()
                    }
                    operation.update { $0.completedItems += 1 }
                }
                if queue.done(task) {
                    operation.update { $0.scanning = false }
                }
            }
        }

        // Apply folder metadata deepest-first, after their contents are written.
        for (s, d) in queue.finalize.reversed() {
            applyDirectoryMetadata(from: s, to: d)
        }
        return !queue.failed && !operation.isCancelled
    }

    /// Creates `dst` and queues the children of `src`.
    private func copyDirectoryEntries(src: String, dst: String, exists: Bool, queue: TaskQueue,
                                      buffer: DirectoryReader.Buffer) -> Bool {
        if !exists {
            if mkdir(dst, 0o700) != 0 && errno != EEXIST {
                recordError("Folder “\((dst as NSString).lastPathComponent)” couldn’t be created: \(String(cString: strerror(errno)))")
                return false
            }
        }
        queue.condition.lock()
        queue.finalize.append((src, dst))
        queue.condition.unlock()

        var pendingTasks: [Task] = []
        pendingTasks.reserveCapacity(256)
        var cancellationChecks = 0
        var continuing = true
        var discoveredBytes: Int64 = 0
        var discoveredFiles = 0
        var ok = true
        do {
            try DirectoryReader.forEachRawEntry(inDirectory: src, buffer: buffer,
                                                 shouldContinue: {
                                                     if cancellationChecks == 0 {
                                                         continuing = self.operation.waitIfPaused()
                                                         cancellationChecks = 256
                                                     }
                                                     cancellationChecks -= 1
                                                     return continuing
                                                 }) { entry in
                let name = entry.nameString
                let s = join(src, name)
                let d = join(dst, name)
                if entry.isDirectory {
                    var existing = stat()
                    let dstExists = exists && lstat(d, &existing) == 0
                    if dstExists && (existing.st_mode & S_IFMT) != S_IFDIR {
                        recordError("“\(name)” already exists and isn’t a folder.")
                        ok = false
                        return
                    }
                    if exists && !dstExists { recordUndoCreated(d) }
                    pendingTasks.append(.directory(src: s, dst: d, exists: dstExists))
                } else {
                    discoveredBytes += entry.size
                    discoveredFiles += 1
                    pendingTasks.append(.file(src: s, dst: d, size: entry.size, symlink: entry.isSymlink, merging: exists))
                }
                if pendingTasks.count >= 256 {
                    queue.push(contentsOf: pendingTasks)
                    pendingTasks.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            recordError("Folder “\((src as NSString).lastPathComponent)” couldn’t be read: \(error.localizedDescription)")
            ok = false
        }
        queue.push(contentsOf: pendingTasks)
        if discoveredBytes > 0 || discoveredFiles > 0 {
            operation.update {
                $0.totalBytes += discoveredBytes
                $0.totalItems += discoveredFiles
            }
        }
        return ok
    }

    /// Copies a folder's permissions, dates, flags, extended attributes and ACLs.
    private func applyDirectoryMetadata(from src: String, to dst: String) {
        var st = stat()
        guard lstat(src, &st) == 0 else { return }
        let sfd = open(src, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let dfd = open(dst, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if sfd >= 0 && dfd >= 0 {
            _ = fcopyfile(sfd, dfd, nil, (1 << 0) | (1 << 2)) // ACL | XATTR
        }
        if sfd >= 0 { close(sfd) }
        if dfd >= 0 { close(dfd) }
        _ = chmod(dst, st.st_mode & 0o7777)
        var times = [st.st_atimespec, st.st_mtimespec]
        _ = utimensat(AT_FDCWD, dst, &times, 0)
        if st.st_flags != 0 { _ = chflags(dst, st.st_flags) }
    }

    // MARK: - Helpers

    private func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    private func deviceID(_ path: String) -> dev_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : -1
    }

    enum NameStyle { case copy, number }

    /// Finder-style unique names: "Report copy.pdf", "Report copy 2.pdf" or "Report 2.pdf".
    static func uniqueName(for name: String, in directory: String, style: NameStyle, splitExtension: Bool = true) -> String {
        var base = name
        var ext = ""
        if splitExtension, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[dot...])
        }
        // "Report copy 2" -> keep counting from the existing suffix.
        for i in 1...100_000 {
            let candidate: String
            switch style {
            case .copy: candidate = i == 1 ? "\(base) copy\(ext)" : "\(base) copy \(i)\(ext)"
            case .number: candidate = "\(base) \(i + 1)\(ext)"
            }
            let path = directory == "/" ? "/" + candidate : directory + "/" + candidate
            var st = stat()
            if lstat(path, &st) != 0 { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))\(ext)"
    }

    // copyfile / clonefile / renamex flags, spelled out (see <copyfile.h>, <sys/clonefile.h>, <stdio.h>).
    static let flagsMetadata: copyfile_flags_t = (1 << 0) | (1 << 1) | (1 << 2) // ACL | STAT | XATTR
    static let flagsAll: copyfile_flags_t = flagsMetadata | (1 << 3)          // + DATA
    static let flagExcl: copyfile_flags_t = 1 << 17
    static let flagNoFollow: copyfile_flags_t = (1 << 18) | (1 << 19)
    static let flagDataSparse: copyfile_flags_t = 1 << 27
    static let cloneNoFollow: UInt32 = 0x0001
    static let renameExcl: UInt32 = 0x0000_0004
}
