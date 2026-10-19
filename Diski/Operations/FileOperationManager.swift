import AppKit

/// Main-thread façade over all file operations. Long operations run on
/// background workers; quick ones (rename, new folder, put back) run inline.
/// Every operation registers its inverse with one app-wide undo manager.
final class FileOperationManager: NSObject, ConflictResolving {
    static let shared = FileOperationManager()
    static let didChange = Notification.Name("DiskiOperationsDidChange")
    /// Posted with the finished `FileOperation` as the object.
    static let didFinish = Notification.Name("DiskiOperationDidFinish")

    let undoManager = UndoManager()
    private(set) var operations: [FileOperation] = []
    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "app.diski.operations", qos: .userInitiated, attributes: .concurrent)

    /// Presents the conflict dialog; set by the UI layer.
    var conflictPresenter: ((_ source: URL, _ existing: URL, _ operation: FileOperation,
                             _ completion: @escaping (ConflictResolution, Bool) -> Void) -> Void)?

    /// Replaces the error alert; tests set it because `NSAlert.runModal()` would hang them.
    var errorPresenter: ((_ errors: [String], _ title: String) -> Void)?

    var activeOperations: [FileOperation] { operations.filter { !$0.state.isDone } }

    struct OperationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Copy / move / duplicate

    @discardableResult
    func copy(_ urls: [URL], to destination: URL) -> FileOperation? {
        guard !urls.isEmpty else { return nil }
        return runCopyEngine(kind: .copy, mode: .copy, urls: urls, destination: destination)
    }

    @discardableResult
    func move(_ urls: [URL], to destination: URL) -> FileOperation? {
        let target = destination.standardizedFileURL
        let urls = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != target }
        guard !urls.isEmpty else { return nil }
        return runCopyEngine(kind: .move, mode: .move, urls: urls, destination: destination)
    }

    @discardableResult
    func duplicate(_ urls: [URL]) -> FileOperation? {
        guard !urls.isEmpty else { return nil }
        return runCopyEngine(kind: .duplicate, mode: .duplicate, urls: urls, destination: nil)
    }

    private func runCopyEngine(kind: FileOperation.Kind, mode: CopyEngine.Mode, urls: [URL], destination: URL?) -> FileOperation {
        let operation = FileOperation(kind: kind, sources: urls, destination: destination)
        let engine = CopyEngine(operation: operation, mode: mode)
        engine.resolver = self
        engine.useClones = Prefs.useClones
        engine.streams = Prefs.copyStreams
        begin(operation)
        workQueue.async {
            engine.run()
            let created = engine.created
            let undoCreated = engine.undoCreated
            let moved = engine.moved
            let replaced = engine.replaced
            let errors = engine.errors
            DispatchQueue.main.async {
                TrashLedger.shared.record(replaced)
                self.finish(operation, results: created, errors: errors)
                self.registerUndo(for: operation, created: undoCreated, moved: moved, replaced: replaced)
            }
        }
        return operation
    }

    // MARK: - Trash / delete

    /// Moves items to the Trash in the background (fast renames on the same volume).
    @discardableResult
    func trash(_ urls: [URL]) -> FileOperation? {
        guard !urls.isEmpty else { return nil }
        let operation = FileOperation(kind: .trash, sources: urls, destination: nil)
        operation.update { $0.totalItems = urls.count; $0.scanning = false }
        begin(operation)
        workQueue.async {
            var pairs: [(original: URL, trashed: URL)] = []
            var errors: [String] = []
            for url in urls {
                if operation.isCancelled { break }
                operation.update { $0.currentName = url.lastPathComponent }
                do {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                    if let trashed = trashed as URL? { pairs.append((url, trashed)) }
                } catch {
                    errors.append("“\(url.lastPathComponent)” couldn’t be moved to the Trash: \(error.localizedDescription)")
                }
                operation.update { $0.completedItems += 1 }
            }
            DispatchQueue.main.async {
                TrashLedger.shared.record(pairs)
                self.finish(operation, results: pairs.map { $0.trashed }, errors: errors)
                if !pairs.isEmpty {
                    self.undoManager.registerUndo(withTarget: self) { manager in
                        manager.putBackNow(pairs)
                    }
                    self.undoManager.setActionName(pairs.count == 1 ? "Move to Trash" : "Move \(pairs.count) Items to Trash")
                }
            }
        }
        return operation
    }

    /// Synchronous trash used by undo/redo.
    @discardableResult
    func trashNow(_ urls: [URL]) -> [(original: URL, trashed: URL)] {
        var pairs: [(original: URL, trashed: URL)] = []
        for url in urls {
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil, let t = trashed as URL? {
                pairs.append((url, t))
            }
        }
        TrashLedger.shared.record(pairs)
        if !pairs.isEmpty {
            undoManager.registerUndo(withTarget: self) { manager in manager.putBackNow(pairs) }
            undoManager.setActionName("Move to Trash")
        }
        refresh(pairs.map { $0.original.deletingLastPathComponent() })
        return pairs
    }

    /// Moves trashed items back where they came from (undo of trash, or "Put Back").
    @discardableResult
    func putBackNow(_ pairs: [(original: URL, trashed: URL)]) -> [URL] {
        var restored: [(original: URL, trashed: URL)] = []
        for pair in pairs {
            let parent = pair.original.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var target = pair.original
            var st = stat()
            if lstat(target.path, &st) == 0 {
                target = parent.appendingPathComponent(CopyEngine.uniqueName(for: pair.original.lastPathComponent,
                                                                             in: parent.path, style: .number))
            }
            if renamex_np(pair.trashed.path, target.path, CopyEngine.renameExcl) == 0 {
                restored.append((target, pair.trashed))
            } else if (try? FileManager.default.moveItem(at: pair.trashed, to: target)) != nil {
                restored.append((target, pair.trashed))
            }
        }
        TrashLedger.shared.forget(restored.map { $0.trashed })
        if !restored.isEmpty {
            let urls = restored.map { $0.original }
            undoManager.registerUndo(withTarget: self) { manager in manager.trashNow(urls) }
            undoManager.setActionName("Put Back")
        }
        refresh(restored.map { $0.original.deletingLastPathComponent() })
        return restored.map { $0.original }
    }

    /// "Put Back" for items in the Trash that Diski trashed.
    func putBack(_ trashedURLs: [URL]) {
        let pairs = trashedURLs.compactMap { url -> (original: URL, trashed: URL)? in
            guard let original = TrashLedger.shared.originalLocation(of: url) else { return nil }
            return (original, url)
        }
        guard !pairs.isEmpty else {
            NSSound.beep()
            return
        }
        putBackNow(pairs)
    }

    func canPutBack(_ url: URL) -> Bool {
        TrashLedger.shared.originalLocation(of: url) != nil
    }

    /// Permanently deletes items (after the caller confirmed).
    @discardableResult
    func deleteImmediately(_ urls: [URL]) -> FileOperation? {
        guard !urls.isEmpty else { return nil }
        let operation = FileOperation(kind: .delete, sources: urls, destination: nil)
        operation.update { $0.totalItems = urls.count; $0.scanning = false }
        begin(operation)
        workQueue.async {
            var errors: [String] = []
            for url in urls {
                if operation.isCancelled { break }
                operation.update { $0.currentName = url.lastPathComponent }
                do { try FileManager.default.removeItem(at: url) } catch {
                    errors.append("“\(url.lastPathComponent)” couldn’t be deleted: \(error.localizedDescription)")
                }
                operation.update { $0.completedItems += 1 }
            }
            DispatchQueue.main.async {
                TrashLedger.shared.forget(urls)
                self.finish(operation, results: [], errors: errors)
            }
        }
        return operation
    }

    static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    func emptyTrash() {
        let operation = FileOperation(kind: .emptyTrash, sources: [Self.trashURL], destination: nil)
        operation.update { $0.scanning = false }
        begin(operation)
        workQueue.async {
            var errors: [String] = []
            var trashDirs = [Self.trashURL.path]
            let uid = getuid()
            for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
                trashDirs.append("/Volumes/\(volume)/.Trashes/\(uid)")
            }
            var denied = false
            for dir in trashDirs {
                var names: [String] = []
                do {
                    try DirectoryReader.forEachRawEntry(inDirectory: dir) { names.append($0.nameString) }
                } catch let error as DirectoryReader.ReadError {
                    if error.isPermissionDenied && dir == Self.trashURL.path { denied = true }
                    continue
                } catch { continue }
                operation.update { $0.totalItems += names.count }
                for name in names where name != ".DS_Store" {
                    if operation.isCancelled { break }
                    operation.update { $0.currentName = name }
                    do { try FileManager.default.removeItem(atPath: dir + "/" + name) } catch {
                        errors.append("“\(name)” couldn’t be deleted.")
                    }
                    operation.update { $0.completedItems += 1 }
                }
            }
            if denied {
                // Without Full Disk Access the Trash can't be listed; let Finder empty it.
                let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
                var info: NSDictionary?
                DispatchQueue.main.sync { _ = script?.executeAndReturnError(&info) }
                if info != nil {
                    errors.append("Diski needs Full Disk Access to empty the Trash. Enable it in System Settings › Privacy & Security.")
                }
            }
            DispatchQueue.main.async {
                TrashLedger.shared.forgetAll()
                self.finish(operation, results: [], errors: errors)
            }
        }
    }

    // MARK: - Quick, inline operations

    @discardableResult
    func rename(_ url: URL, to rawName: String) throws -> URL {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { throw OperationError(message: "Please enter a name.") }
        guard !newName.contains("/") else { throw OperationError(message: "Names can’t contain “/”.") }
        guard newName.utf8.count <= 255 else { throw OperationError(message: "That name is too long.") }
        guard newName != "." && newName != ".." else { throw OperationError(message: "That name is reserved.") }
        let oldName = url.lastPathComponent
        if newName == oldName { return url }
        let parent = url.deletingLastPathComponent()
        let target = parent.appendingPathComponent(newName)
        // Case-only renames refer to the same file on case-insensitive volumes.
        let caseOnly = newName.lowercased() == oldName.lowercased()
        // rename(2) silently replaces: on a case-sensitive volume "foo" -> "Foo" would clobber a separate "Foo".
        if caseOnly {
            var from = stat(), to = stat()
            if lstat(url.path, &from) == 0, lstat(target.path, &to) == 0, (from.st_dev, from.st_ino) != (to.st_dev, to.st_ino) {
                throw OperationError(message: "The name “\(newName)” is already taken. Please choose a different name.")
            }
        }
        let result = caseOnly ? Darwin.rename(url.path, target.path) : renamex_np(url.path, target.path, CopyEngine.renameExcl)
        if result != 0 {
            if errno == EEXIST {
                throw OperationError(message: "The name “\(newName)” is already taken. Please choose a different name.")
            }
            throw OperationError(message: "“\(oldName)” couldn’t be renamed: \(String(cString: strerror(errno))).")
        }
        IconCache.shared.invalidate(path: url.path)
        undoManager.registerUndo(withTarget: self) { manager in
            _ = try? manager.rename(target, to: oldName)
        }
        undoManager.setActionName("Rename")
        refresh([parent])
        return target
    }

    /// Creates "untitled folder" (or "New Folder With Items" containing `items`).
    @discardableResult
    func newFolder(in directory: URL, containing items: [URL] = []) throws -> URL {
        let base = items.isEmpty ? "untitled folder" : "New Folder With Items"
        var name = base
        var st = stat()
        if lstat(directory.appendingPathComponent(name).path, &st) == 0 {
            name = CopyEngine.uniqueName(for: base, in: directory.path, style: .number, splitExtension: false)
        }
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        if mkdir(folder.path, 0o755) != 0 {
            throw OperationError(message: "The folder couldn’t be created: \(String(cString: strerror(errno))).")
        }
        var movedPairs: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for item in items {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            if renamex_np(item.path, target.path, CopyEngine.renameExcl) == 0 {
                movedPairs.append((item, target))
            } else {
                failures.append("“\(item.lastPathComponent)” couldn’t be moved: \(String(cString: strerror(errno))).")
            }
        }
        undoManager.registerUndo(withTarget: self) { manager in
            manager.moveBackNow(movedPairs)
            manager.trashNow([folder])
        }
        undoManager.setActionName("New Folder")
        refresh([directory])
        if !failures.isEmpty { presentErrors(failures, title: "Some items couldn’t be moved into the new folder.") }
        return folder
    }

    /// Creates an empty "Untitled.txt" (something Finder can't do).
    @discardableResult
    func newFile(in directory: URL, name base: String = "Untitled.txt") throws -> URL {
        var name = base
        var st = stat()
        if lstat(directory.appendingPathComponent(name).path, &st) == 0 {
            name = CopyEngine.uniqueName(for: base, in: directory.path, style: .number)
        }
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
            throw OperationError(message: "The file couldn’t be created.")
        }
        undoManager.registerUndo(withTarget: self) { manager in manager.trashNow([file]) }
        undoManager.setActionName("New File")
        refresh([directory])
        return file
    }

    /// Writes clipboard contents (an image or text) as a new file.
    @discardableResult
    func pasteData(from pasteboard: NSPasteboard, into directory: URL) throws -> URL? {
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let name = CopyEngine.uniqueName(for: "Pasted Image.png", in: directory.path, style: .number)
            let url = directory.appendingPathComponent(uniqueOrSame("Pasted Image.png", name, in: directory))
            try png.write(to: url, options: .withoutOverwriting)
            registerCreated(url, in: directory)
            return url
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let name = CopyEngine.uniqueName(for: "Pasted Text.txt", in: directory.path, style: .number)
            let url = directory.appendingPathComponent(uniqueOrSame("Pasted Text.txt", name, in: directory))
            try text.write(to: url, atomically: true, encoding: .utf8)
            registerCreated(url, in: directory)
            return url
        }
        return nil
    }

    private func uniqueOrSame(_ preferred: String, _ unique: String, in directory: URL) -> String {
        var st = stat()
        return lstat(directory.appendingPathComponent(preferred).path, &st) == 0 ? unique : preferred
    }

    private func registerCreated(_ url: URL, in directory: URL) {
        undoManager.registerUndo(withTarget: self) { manager in manager.trashNow([url]) }
        undoManager.setActionName("Paste")
        refresh([directory])
    }

    /// Finder aliases ("Report alias").
    @discardableResult
    func makeAliases(for urls: [URL], in destination: URL? = nil) -> [URL] {
        var created: [URL] = []
        for url in urls {
            let directory = destination ?? url.deletingLastPathComponent()
            let base = url.lastPathComponent + " alias"
            var name = base
            var st = stat()
            if lstat(directory.appendingPathComponent(name).path, &st) == 0 {
                name = CopyEngine.uniqueName(for: base, in: directory.path, style: .number, splitExtension: false)
            }
            let aliasURL = directory.appendingPathComponent(name)
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: aliasURL)
                created.append(aliasURL)
            } catch {
                presentError("“\(url.lastPathComponent)” couldn’t be aliased: \(error.localizedDescription)")
            }
        }
        if !created.isEmpty {
            undoManager.registerUndo(withTarget: self) { manager in manager.trashNow(created) }
            undoManager.setActionName("Make Alias")
            refresh(created.map { $0.deletingLastPathComponent() })
        }
        return created
    }

    func makeSymlinks(for urls: [URL]) {
        var created: [URL] = []
        var failures: [String] = []
        for url in urls {
            let directory = url.deletingLastPathComponent()
            let name = CopyEngine.uniqueName(for: url.lastPathComponent + " link", in: directory.path,
                                             style: .number, splitExtension: false)
            let link = directory.appendingPathComponent(name)
            if symlink(url.path, link.path) == 0 {
                created.append(link)
            } else {
                failures.append("“\(url.lastPathComponent)” couldn’t be linked: \(String(cString: strerror(errno))).")
            }
        }
        if !created.isEmpty {
            undoManager.registerUndo(withTarget: self) { manager in manager.trashNow(created) }
            undoManager.setActionName("Make Symbolic Link")
            refresh(created.map { $0.deletingLastPathComponent() })
        }
        if !failures.isEmpty { presentErrors(failures, title: "Some links couldn’t be created.") }
    }

    /// Moves items back to where they were (undo of a move). Same-volume pairs are renamed back right away;
    /// cross-volume pairs (EXDEV) go through the async `move` (conflicts, progress, errors); the rest are reported.
    func moveBackNow(_ pairs: [(from: URL, to: URL)]) {
        var reverted: [(from: URL, to: URL)] = []
        var crossVolume: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for pair in pairs {
            if renamex_np(pair.to.path, pair.from.path, CopyEngine.renameExcl) == 0 {
                reverted.append((pair.to, pair.from))
            } else if errno == EXDEV {
                crossVolume.append(pair)
            } else {
                failures.append("“\(pair.to.lastPathComponent)” couldn’t be moved back: \(String(cString: strerror(errno))).")
            }
        }
        if !reverted.isEmpty {
            undoManager.registerUndo(withTarget: self) { manager in manager.moveBackNow(reverted) }
            undoManager.setActionName("Move")
        }
        refresh(pairs.flatMap { [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()] })
        // shortcut: cross-volume move-back is async, so a replaced original is put back beside it as “name 2”;
        // chain putBack to the move's completion if users hit it.
        for (parent, group) in Dictionary(grouping: crossVolume, by: { $0.from.deletingLastPathComponent() }) {
            move(group.map { $0.to }, to: parent)
        }
        if !failures.isEmpty { presentErrors(failures, title: "Some items couldn’t be moved back.") }
    }

    // MARK: - Compress

    @discardableResult
    func compress(_ urls: [URL]) -> FileOperation? {
        guard let first = urls.first else { return nil }
        let directory = first.deletingLastPathComponent()
        let operation = FileOperation(kind: .compress, sources: urls, destination: directory)
        operation.update { $0.totalItems = 1; $0.scanning = false }
        begin(operation)
        let archiveBase = urls.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
        var archiveName = archiveBase
        var st = stat()
        if lstat(directory.appendingPathComponent(archiveName).path, &st) == 0 {
            archiveName = CopyEngine.uniqueName(for: archiveBase, in: directory.path, style: .number)
        }
        let archive = directory.appendingPathComponent(archiveName)
        workQueue.async {
            let process = Process()
            if urls.count == 1 {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, archive.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = directory
                process.arguments = ["-r", "-y", "-q", archive.path] + urls.map { $0.lastPathComponent }
            }
            var errors: [String] = []
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 { errors.append("The archive couldn’t be created.") }
            } catch {
                errors.append("The archive couldn’t be created: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.finish(operation, results: errors.isEmpty ? [archive] : [], errors: errors)
                if errors.isEmpty {
                    self.undoManager.registerUndo(withTarget: self) { manager in manager.trashNow([archive]) }
                    self.undoManager.setActionName("Compress")
                }
            }
        }
        return operation
    }

    // MARK: - Lifecycle

    private func begin(_ operation: FileOperation) {
        operation.state = .running
        operations.append(operation)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func tick() {
        var anyRunning = false
        for operation in operations where !operation.state.isDone {
            operation.sampleThroughput()
            anyRunning = true
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if !anyRunning {
            timer?.invalidate()
            timer = nil
        }
    }

    private func finish(_ operation: FileOperation, results: [URL], errors: [String]) {
        operation.resultURLs = results
        operation.errors = errors
        operation.finishedAt = Date()
        if operation.isCancelled {
            operation.state = .cancelled
        } else if !errors.isEmpty && results.isEmpty {
            operation.state = .failed(errors.first ?? "The operation couldn’t be completed.")
        } else {
            operation.state = .finished
        }
        operation.update { $0.completedBytes = max($0.completedBytes, $0.totalBytes) }
        var dirs = results.map { $0.deletingLastPathComponent() }
        dirs += operation.sources.map { $0.deletingLastPathComponent() }
        if let destination = operation.destination { dirs.append(destination) }
        refresh(dirs)
        // Folder sizes changed too: refresh them now instead of waiting for the
        // last file-system events (a size read mid-copy would otherwise stick).
        let touched = (results + operation.sources).map { DirectoryReader.normalized($0.path) }
        FolderSizer.shared.invalidate(changedPaths: touched)
        DirectoryStore.shared.noteNestedChanges(touched, minimumDepth: 0)
        NotificationCenter.default.post(name: Self.didFinish, object: operation)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if !errors.isEmpty && !operation.isCancelled {
            presentErrors(errors, title: operation.state == .finished
                          ? "Some items couldn’t be \(operation.kind.pastTense.lowercased())."
                          : "The operation couldn’t be completed.")
        }
        // Keep finished operations around briefly so the UI can show the result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.operations.removeAll { $0 === operation }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// `created`/`moved`/`replaced` only ever hold completed items, so this is also right for a cancelled operation.
    /// Not `private`: tests call it. A merged move registers no undo (its `moved` is empty by design).
    func registerUndo(for operation: FileOperation, created: [URL], moved: [(from: URL, to: URL)],
                      replaced: [(original: URL, trashed: URL)]) {
        switch operation.kind {
        case .copy, .duplicate:
            guard !created.isEmpty || !replaced.isEmpty else { return }
            undoManager.registerUndo(withTarget: self) { m in m.trashNow(created); m.putBackNow(replaced) }
            undoManager.setActionName(operation.kind == .copy ? "Copy" : "Duplicate")
        case .move:
            guard !moved.isEmpty else { return }
            undoManager.registerUndo(withTarget: self) { m in m.moveBackNow(moved); m.putBackNow(replaced) }
            undoManager.setActionName("Move")
        default:
            break
        }
    }

    /// Re-reads affected folders right away instead of waiting for FSEvents.
    private func refresh(_ directories: [URL]) {
        let paths = Set(directories.map { DirectoryReader.normalized($0.path) })
        DirectoryStore.shared.reload(paths: paths)
    }

    // MARK: - Conflicts (worker thread)

    func resolveConflict(source: URL, existing: URL, operation: FileOperation) -> (ConflictResolution, applyToAll: Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        var answer: (ConflictResolution, applyToAll: Bool) = (.stop, false)
        DispatchQueue.main.async {
            guard let presenter = self.conflictPresenter else {
                answer = (.keepBoth, false)
                semaphore.signal()
                return
            }
            presenter(source, existing, operation) { resolution, applyToAll in
                answer = (resolution, applyToAll)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return answer
    }

    // MARK: - Errors

    func presentError(_ message: String) {
        presentErrors([message], title: message)
    }

    private func presentErrors(_ errors: [String], title: String) {
        if let errorPresenter { errorPresenter(errors, title); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        if errors.count > 1 || errors.first != title {
            var text = errors.prefix(8).joined(separator: "\n")
            if errors.count > 8 { text += "\n…and \(errors.count - 8) more." }
            alert.informativeText = text
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Remembers where trashed items came from so they can be put back.
final class TrashLedger {
    static let shared = TrashLedger()

    private var entries: [String: String] = [:] // trashed path -> original path
    private let fileURL: URL
    private let saveQueue = DispatchQueue(label: "app.diski.trashledger", qos: .utility)

    private init() {
        // Tests must not write the real ledger (or race a running Diski over it); one file per test process.
        let underTest = NSClassFromString("XCTestCase") != nil
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = underTest ? FileManager.default.temporaryDirectory : support.appendingPathComponent("Diski", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent(underTest ? "DiskiTests-TrashLedger-\(ProcessInfo.processInfo.processIdentifier).json"
                                                          : "TrashLedger.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.saveQueue.sync {}
        }
    }

    func record(_ pairs: [(original: URL, trashed: URL)]) {
        guard !pairs.isEmpty else { return }
        for pair in pairs { entries[pair.trashed.path] = pair.original.path }
        save()
    }

    func forget(_ trashed: [URL]) {
        guard !trashed.isEmpty else { return }
        for url in trashed { entries.removeValue(forKey: url.path) }
        save()
    }

    func forgetAll() {
        entries.removeAll()
        save()
    }

    func originalLocation(of trashed: URL) -> URL? {
        entries[trashed.path].map { URL(fileURLWithPath: $0) }
    }

    private func save() {
        // Drop entries whose item is no longer in the Trash.
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        let snapshot = entries
        let destination = fileURL
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: destination, options: .atomic)
            }
        }
    }
}
