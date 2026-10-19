import XCTest
@testable import Diski

final class EngineTests: XCTestCase {
    private var root: URL!
    /// Unique per test; every file that can reach the real Trash carries it so tearDown can find and remove it.
    private var tok = ""
    private var createdNames = Set<String>()

    override func setUpWithError() throws {
        tok = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskiTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        // Undo/replace tests trash into the real ~/.Trash. The test host can't list it (TCC), so remove by exact name:
        // every name a test created carries `tok`, and a trashed item keeps its name (the token rules out collisions).
        for name in createdNames where name.contains(tok) {
            try? FileManager.default.removeItem(at: FileOperationManager.trashURL.appendingPathComponent(name))
        }
    }

    @discardableResult
    private func makeFile(_ relative: String, size: Int = 0, byte: UInt8 = 0x41) throws -> URL {
        let url = root.appendingPathComponent(relative)
        createdNames.formUnion(relative.split(separator: "/").map(String.init))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = byte &+ UInt8(truncatingIfNeeded: i % 251) }
        try Data(bytes).write(to: url)
        return url
    }

    private func makeTree(at base: String, files: Int, depth: Int) throws {
        for d in 0..<depth {
            for f in 0..<files {
                try makeFile("\(base)/level\(d)/sub\(f % 3)/file\(f).bin", size: 1000 + f * 37, byte: UInt8(d))
            }
        }
    }

    // MARK: DirectoryReader

    func testDirectoryReaderMatchesFileManager() throws {
        try makeFile("alpha.txt", size: 12)
        try makeFile("Beta.pdf", size: 4096)
        try makeFile(".hidden", size: 3)
        try makeFile("folder/inner.txt", size: 5)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("folder"))

        let items = try DirectoryReader.read(path: root.path)
        let names = Set(items.map { $0.name })
        let expected = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(names, expected)

        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["alpha.txt"]?.type, .file)
        XCTAssertEqual(byName["alpha.txt"]?.size, 12)
        XCTAssertEqual(byName["Beta.pdf"]?.size, 4096)
        XCTAssertEqual(byName["folder"]?.type, .directory)
        XCTAssertEqual(byName["folder"]?.childCount, 1)
        XCTAssertEqual(byName["App.app"]?.type, .package)
        XCTAssertEqual(byName["link"]?.type, .symlink)
        XCTAssertEqual(byName["link"]?.isNavigable, true)
        XCTAssertEqual(byName[".hidden"]?.isHidden, true)
        XCTAssertEqual(byName["alpha.txt"]?.isHidden, false)

        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Beta.pdf").path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        XCTAssertEqual(byName["Beta.pdf"]!.modified, modified, accuracy: 0.001)
    }

    func testRawScanCountsEverything() throws {
        for i in 0..<300 { try makeFile("many/f\(i)", size: i) }
        var count = 0
        var bytes: Int64 = 0
        try DirectoryReader.forEachRawEntry(inDirectory: root.appendingPathComponent("many").path) { entry in
            count += 1
            bytes += entry.size
        }
        XCTAssertEqual(count, 300)
        XCTAssertEqual(bytes, Int64((0..<300).reduce(0, +)))
    }

    func testReadingMissingFolderThrows() {
        XCTAssertThrowsError(try DirectoryReader.read(path: root.appendingPathComponent("nope").path))
    }

    // MARK: Sorting

    func testNaturalSortOrdersLikeFinder() {
        let names = ["File 10.txt", "file 2.txt", "File 1.txt", "alpha", "Zeta", "_under", "File 02.txt"]
        let sorted = names.map(NameSortKey.init).sorted { NameSortKey.compare($0, $1) == .orderedAscending }.map { $0.name }
        XCTAssertEqual(sorted, ["_under", "alpha", "File 1.txt", "file 2.txt", "File 02.txt", "File 10.txt", "Zeta"])
    }

    func testNaturalSortAgreesWithLocalizedStandardCompareOnPlainNames() {
        let names = (0..<200).map { "Report \($0 * 7 % 113) v\($0 % 9).pdf" } + ["a", "B", "c10", "c9", "C1"]
        let fast = names.map(NameSortKey.init).sorted { NameSortKey.compare($0, $1) == .orderedAscending }.map { $0.name }
        let slow = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(fast.map { $0.lowercased() }, slow.map { $0.lowercased() })
    }

    func testArrangerKeepsFoldersOnTopAndHidesHidden() throws {
        try makeFile("b.txt", size: 10)
        try makeFile("a folder/x", size: 1)
        try makeFile(".secret", size: 1)
        try makeFile("c.txt", size: 2000)
        let items = try DirectoryReader.read(path: root.path)
        var options = ArrangeOptions()
        let arranged = ItemArranger.arrange(items, options: options).map { $0.name }
        XCTAssertEqual(arranged, ["a folder", "b.txt", "c.txt"])

        options.sortKey = .size
        options.ascending = false
        options.foldersOnTop = false
        options.showHidden = true
        let bySize = ItemArranger.arrange(items, options: options).map { $0.name }
        XCTAssertEqual(bySize.first, "c.txt")
        XCTAssertTrue(bySize.contains(".secret"))

        options.filter = "TXT"
        XCTAssertEqual(Set(ItemArranger.arrange(items, options: options).map { $0.name }), ["b.txt", "c.txt"])
    }

    // MARK: Copy engine

    private func assertTreesEqual(_ a: URL, _ b: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let fm = FileManager.default
        let left = try fm.subpathsOfDirectory(atPath: a.path).sorted()
        let right = try fm.subpathsOfDirectory(atPath: b.path).sorted()
        XCTAssertEqual(left, right, file: file, line: line)
        for sub in left {
            let pa = a.appendingPathComponent(sub).path
            let pb = b.appendingPathComponent(sub).path
            var isDir: ObjCBool = false
            fm.fileExists(atPath: pa, isDirectory: &isDir)
            let attributesA = try fm.attributesOfItem(atPath: pa)
            let attributesB = try fm.attributesOfItem(atPath: pb)
            XCTAssertEqual(attributesA[.type] as? FileAttributeType, attributesB[.type] as? FileAttributeType, sub, file: file, line: line)
            XCTAssertEqual(attributesA[.posixPermissions] as? Int, attributesB[.posixPermissions] as? Int, sub, file: file, line: line)
            if !isDir.boolValue && attributesA[.type] as? FileAttributeType == .typeRegular {
                XCTAssertTrue(fm.contentsEqual(atPath: pa, andPath: pb), "content differs: \(sub)", file: file, line: line)
                let ma = (attributesA[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let mb = (attributesB[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                XCTAssertEqual(ma, mb, accuracy: 1, "mtime differs: \(sub)", file: file, line: line)
            }
        }
    }

    private func runEngine(_ mode: CopyEngine.Mode, _ sources: [URL], to destination: URL?, clones: Bool,
                           resolver: ConflictResolving? = nil) -> CopyEngine {
        let kind: FileOperation.Kind = mode == .move ? .move : (mode == .duplicate ? .duplicate : .copy)
        let operation = FileOperation(kind: kind, sources: sources, destination: destination)
        let engine = CopyEngine(operation: operation, mode: mode)
        engine.useClones = clones
        engine.streams = 6
        engine.resolver = resolver
        engine.run()
        return engine
    }

    func testParallelTreeCopyProducesIdenticalTree() throws {
        try makeTree(at: "src", files: 40, depth: 4)
        try makeFile("src/big.bin", size: 6 * 1024 * 1024)
        try makeFile("src/empty", size: 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("src/link").path, withDestinationPath: "big.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: root.appendingPathComponent("src/empty").path)
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let engine = runEngine(.copy, [root.appendingPathComponent("src")], to: destination, clones: false)
        XCTAssertTrue(engine.errors.isEmpty, "\(engine.errors)")
        XCTAssertEqual(engine.created.map { $0.lastPathComponent }, ["src"])
        try assertTreesEqual(root.appendingPathComponent("src"), destination.appendingPathComponent("src"))
        let snapshot = engine.operation.snapshot
        XCTAssertEqual(snapshot.completedBytes, snapshot.totalBytes)
        XCTAssertFalse(snapshot.instant)
    }

    func testCloneCopyIsIdentical() throws {
        try makeTree(at: "src", files: 12, depth: 2)
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = runEngine(.copy, [root.appendingPathComponent("src")], to: destination, clones: true)
        XCTAssertTrue(engine.errors.isEmpty, "\(engine.errors)")
        try assertTreesEqual(root.appendingPathComponent("src"), destination.appendingPathComponent("src"))
    }

    func testCopyIntoSameFolderMakesCopy() throws {
        let file = try makeFile("Report.pdf", size: 100)
        let engine = runEngine(.copy, [file], to: root, clones: true)
        XCTAssertEqual(engine.created.map { $0.lastPathComponent }, ["Report copy.pdf"])
        let again = runEngine(.duplicate, [file], to: nil, clones: false)
        XCTAssertEqual(again.created.map { $0.lastPathComponent }, ["Report copy 2.pdf"])
    }

    func testMoveRenamesWithinVolume() throws {
        let file = try makeFile("a/thing.txt", size: 64)
        let target = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = runEngine(.move, [file], to: target, clones: true)
        XCTAssertTrue(engine.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("thing.txt").path))
        XCTAssertEqual(engine.moved.count, 1)
    }

    func testCannotCopyFolderIntoItself() throws {
        try makeFile("outer/inner/x", size: 1)
        let outer = root.appendingPathComponent("outer")
        let engine = runEngine(.copy, [outer], to: outer.appendingPathComponent("inner"), clones: true)
        XCTAssertEqual(engine.created.count, 0)
        XCTAssertEqual(engine.errors.count, 1)
    }

    final class StubResolver: ConflictResolving {
        let answer: ConflictResolution
        var asked = 0
        init(_ answer: ConflictResolution) { self.answer = answer }
        func resolveConflict(source: URL, existing: URL, operation: FileOperation) -> (ConflictResolution, applyToAll: Bool) {
            asked += 1
            return (answer, false)
        }
    }

    func testConflictKeepBothAndSkip() throws {
        let source = try makeFile("in/doc.txt", size: 10, byte: 1)
        try makeFile("out/doc.txt", size: 20, byte: 2)
        let out = root.appendingPathComponent("out")

        let keep = StubResolver(.keepBoth)
        let engine = runEngine(.copy, [source], to: out, clones: false, resolver: keep)
        XCTAssertEqual(keep.asked, 1)
        XCTAssertEqual(engine.created.map { $0.lastPathComponent }, ["doc 2.txt"])

        let skip = StubResolver(.skip)
        let skipped = runEngine(.copy, [source], to: out, clones: false, resolver: skip)
        XCTAssertEqual(skipped.created.count, 0)
        let size = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("doc.txt").path)[.size] as? Int
        XCTAssertEqual(size, 20)
    }

    func testMergeCopiesNewFilesIntoExistingFolder() throws {
        try makeFile("src/Photos/a.jpg", size: 10)
        try makeFile("src/Photos/b.jpg", size: 10)
        try makeFile("dst/Photos/c.jpg", size: 10)
        let engine = runEngine(.copy, [root.appendingPathComponent("src/Photos")], to: root.appendingPathComponent("dst"),
                               clones: false, resolver: StubResolver(.merge))
        XCTAssertTrue(engine.errors.isEmpty, "\(engine.errors)")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("dst/Photos").path))
        XCTAssertEqual(names, ["a.jpg", "b.jpg", "c.jpg"])
    }

    func testUniqueNames() throws {
        try makeFile("Notes.txt")
        try makeFile("Notes copy.txt")
        XCTAssertEqual(CopyEngine.uniqueName(for: "Notes.txt", in: root.path, style: .copy), "Notes copy 2.txt")
        XCTAssertEqual(CopyEngine.uniqueName(for: "Notes.txt", in: root.path, style: .number), "Notes 2.txt")
        XCTAssertEqual(CopyEngine.uniqueName(for: "my.folder", in: root.path, style: .number, splitExtension: false), "my.folder 2")
    }

    // MARK: Folder sizes

    func testFolderSizeWalk() throws {
        try makeTree(at: "tree", files: 25, depth: 3)
        let walk = FolderSizer.Walk(root: root.appendingPathComponent("tree").path)
        let (bytes, items) = walk.run()
        var expectedBytes: Int64 = 0
        var expectedItems = 0
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("tree"),
                                                        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])!
        for case let url as URL in enumerator {
            expectedItems += 1
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { expectedBytes += Int64(values.fileSize ?? 0) }
        }
        XCTAssertEqual(bytes, expectedBytes)
        XCTAssertEqual(items, expectedItems)
    }

    func testListDatesGetLongerWithRoom() {
        let past: Double = 1_758_740_280 // September 24, 2025
        let texts = Formatters.DateLength.allCases.map { Formatters.listDate(past, length: $0) }
        for (shorter, longer) in zip(texts, texts.dropFirst()) {
            XCTAssertLessThanOrEqual(shorter.count, longer.count, "\(shorter) vs \(longer)")
        }
        XCTAssertLessThan(texts[0].count, texts[1].count)

        let now = Date().timeIntervalSince1970
        XCTAssertEqual(Formatters.listDate(now, length: .dateOnly), "Today")
        XCTAssertTrue(Formatters.listDate(now, length: .short).hasPrefix("Today, "))
        XCTAssertTrue(Formatters.listDate(now, length: .medium).hasPrefix("Today at "))
        XCTAssertEqual(Formatters.listDate(0), "--")
        XCTAssertEqual(Formatters.size(0), "Zero bytes")
    }

    func testFolderSizeThatRacesWithChangesIsNotCached() throws {
        try makeTree(at: "live", files: 12, depth: 2)
        let path = root.appendingPathComponent("live").path
        let sizer = FolderSizer.shared

        // The folder changes while the walk runs: its result is shown but not cached.
        let first = expectation(description: "stale walk delivered")
        sizer.size(of: path) { _ in first.fulfill() }
        sizer.invalidate(changedPaths: [path + "/level0/sub1/new.bin"])
        XCTAssertFalse(sizer.isComputing(path))
        wait(for: [first], timeout: 10)
        XCTAssertNil(sizer.cached(path))

        // Asking again walks the current contents and caches them.
        let before = FolderSizer.Walk(root: path).run().0
        try makeFile("live/level0/sub1/new.bin", size: 5000)
        let second = expectation(description: "fresh walk delivered")
        var bytes: Int64 = -1
        sizer.size(of: path) { result in
            bytes = result.bytes
            second.fulfill()
        }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(bytes, before + 5000)
        XCTAssertEqual(sizer.cached(path)?.bytes, before + 5000)

        // A change deep inside drops the cached size of every enclosing folder.
        sizer.invalidate(changedPaths: [path + "/level1/sub0/file0.bin"])
        XCTAssertNil(sizer.cached(path))
    }

    // MARK: Performance

    func testListingSpeedAgainstFileManager() throws {
        for i in 0..<3000 { try makeFile("big/item\(i).dat", size: i % 100) }
        let path = root.appendingPathComponent("big").path
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isHiddenKey]
        var diski = Double.infinity
        var foundation = Double.infinity
        for _ in 0..<5 {
            var start = CFAbsoluteTimeGetCurrent()
            let items = try DirectoryReader.read(path: path)
            diski = min(diski, CFAbsoluteTimeGetCurrent() - start)
            XCTAssertEqual(items.count, 3000)
            start = CFAbsoluteTimeGetCurrent()
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
            for url in urls { _ = try url.resourceValues(forKeys: Set(keys)) }
            foundation = min(foundation, CFAbsoluteTimeGetCurrent() - start)
        }
        print(String(format: "DISKI-BENCH listing 3000 files: Diski %.2f ms, FileManager %.2f ms (%.1fx)",
                     diski * 1000, foundation * 1000, foundation / diski))
        XCTAssertLessThan(diski, foundation)
    }

    // MARK: PR-A undo safety

    /// Registers the engine's undo the way `runCopyEngine` does, on a private manager (own UndoManager).
    private func registerUndo(_ engine: CopyEngine) -> FileOperationManager {
        let manager = FileOperationManager()
        manager.undoManager.groupsByEvent = false
        manager.undoManager.beginUndoGrouping()
        manager.registerUndo(for: engine.operation, created: engine.undoCreated, moved: engine.moved, replaced: engine.replaced)
        manager.undoManager.endUndoGrouping()
        return manager
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    func testUndoOfMergeCopyKeepsPreexistingFiles() throws {
        let p = "Photos-\(tok)"
        try makeFile("src/\(p)/a-\(tok)", size: 10)
        try makeFile("src/\(p)/b-\(tok)", size: 10)
        try makeFile("src/\(p)/sub/s-\(tok)", size: 10)
        try makeFile("src/\(p)/fresh-\(tok)/x-\(tok)", size: 10)
        try makeFile("dst/\(p)/c-\(tok)", size: 10)
        try makeFile("dst/\(p)/sub/old-\(tok)", size: 10)
        let dst = root.appendingPathComponent("dst/\(p)")
        let engine = runEngine(.copy, [root.appendingPathComponent("src/\(p)")], to: root.appendingPathComponent("dst"),
                               clones: false, resolver: StubResolver(.merge))
        XCTAssertTrue(engine.errors.isEmpty, "\(engine.errors)")
        XCTAssertEqual(Set(engine.undoCreated.map { $0.path }),
                       Set(["a-\(tok)", "b-\(tok)", "sub/s-\(tok)", "fresh-\(tok)"].map { dst.appendingPathComponent($0).path }))

        let manager = registerUndo(engine)
        XCTAssertTrue(manager.undoManager.canUndo)
        manager.undoManager.undo()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("c-\(tok)").path))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("sub/old-\(tok)").path))
        XCTAssertTrue(fm.fileExists(atPath: dst.path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("a-\(tok)").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("sub/s-\(tok)").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("fresh-\(tok)").path))
    }

    func testMergedMoveRegistersNoUndo() throws {
        let p = "Photos-\(tok)"
        try makeFile("src/\(p)/a-\(tok).jpg", size: 10)
        try makeFile("dst/\(p)/c-\(tok).jpg", size: 10)
        let engine = runEngine(.move, [root.appendingPathComponent("src/\(p)")], to: root.appendingPathComponent("dst"),
                               clones: false, resolver: StubResolver(.merge))
        XCTAssertTrue(engine.errors.isEmpty, "\(engine.errors)")
        XCTAssertTrue(engine.moved.isEmpty)
        let manager = registerUndo(engine)
        // An empty undo group still reports canUndo == true, so check that no action (and no action name) was registered.
        XCTAssertEqual(manager.undoManager.undoActionName, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dst/\(p)/c-\(tok).jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dst/\(p)/a-\(tok).jpg").path))
    }

    func testReplaceKeepsOriginalWhenCopyFails() throws {
        let name = "doc-\(tok).txt"
        let source = try makeFile("in/\(name)", size: 10, byte: 1)
        let existing = try makeFile("out/\(name)", size: 20, byte: 2)
        let original = try Data(contentsOf: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }
        let engine = runEngine(.copy, [source], to: root.appendingPathComponent("out"), clones: false, resolver: StubResolver(.replace))
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertTrue(engine.replaced.isEmpty)
        XCTAssertFalse(engine.errors.isEmpty)
    }

    func testMergeKeepsExistingFileWhenReplacementFails() throws {
        let p = "Photos-\(tok)"
        let source = try makeFile("src/\(p)/a-\(tok).jpg", size: 10, byte: 1)
        let existing = try makeFile("dst/\(p)/a-\(tok).jpg", size: 20, byte: 2)
        let original = try Data(contentsOf: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }
        let engine = runEngine(.copy, [root.appendingPathComponent("src/\(p)")], to: root.appendingPathComponent("dst"),
                               clones: false, resolver: StubResolver(.merge))
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertTrue(engine.replaced.isEmpty)
        XCTAssertFalse(engine.errors.isEmpty)
    }

    func testUndoOfReplaceCopyRestoresOriginal() throws {
        let name = "doc-\(tok).txt"
        let source = try makeFile("in/\(name)", size: 10, byte: 1)
        let target = try makeFile("out/\(name)", size: 20, byte: 2)
        let engine = runEngine(.copy, [source], to: root.appendingPathComponent("out"), clones: false, resolver: StubResolver(.replace))
        XCTAssertTrue(engine.errors.isEmpty, "\(engine.errors)")
        XCTAssertEqual(engine.replaced.count, 1)
        XCTAssertEqual(fileSize(target), 10)

        let manager = registerUndo(engine)
        manager.undoManager.undo()
        XCTAssertEqual(fileSize(target), 20)
        XCTAssertTrue(manager.undoManager.canRedo)
        manager.undoManager.redo()
        XCTAssertEqual(fileSize(target), 10)
    }

    func testCancelledCopyStillRegistersUndoForCompletedItems() throws {
        let a = try makeFile("in/a-\(tok).txt", size: 10)
        let b = try makeFile("in/b-\(tok).txt", size: 10)
        let out = root.appendingPathComponent("out")
        try makeFile("out/b-\(tok).txt", size: 20) // conflict on the second item -> Stop
        let engine = runEngine(.copy, [a, b], to: out, clones: false, resolver: StubResolver(.stop))
        XCTAssertEqual(engine.created.map { $0.lastPathComponent }, ["a-\(tok).txt"])
        engine.operation.state = .cancelled

        let manager = registerUndo(engine)
        XCTAssertTrue(manager.undoManager.canUndo)
        manager.undoManager.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("a-\(tok).txt").path))
        XCTAssertEqual(fileSize(out.appendingPathComponent("b-\(tok).txt")), 20)
    }

    // MARK: PR-G self-destination

    /// A UUID token for file names that may reach the Trash.
    private func trashToken() -> String { "diskiG-\(UUID().uuidString)" }

    /// Removes whatever the engine sent to the Trash once the test ends (the test host can't list ~/.Trash).
    private func removeTrashed(by engine: CopyEngine) {
        let trashed = engine.replaced.map { $0.trashed }
        addTeardownBlock { for url in trashed { try? FileManager.default.removeItem(at: url) } }
    }

    /// Copies or moves `real/<token>.txt` into `destination`, another path for `real`, answering Replace to
    /// any prompt. It must act like the same-folder case: no prompt, source untouched, copy makes "name copy".
    private func assertSelfDestinationIsSafe(_ mode: CopyEngine.Mode, to destination: URL, clones: Bool,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let token = trashToken()
        let source = try makeFile("real/\(token).txt", size: 10, byte: 7)
        let original = try Data(contentsOf: source)
        let resolver = StubResolver(.replace)
        let engine = runEngine(mode, [source], to: destination, clones: clones, resolver: resolver)
        removeTrashed(by: engine)
        let what = "\(mode) clones=\(clones) to \(destination.path): asked \(resolver.asked), errors \(engine.errors), "
            + "trashed \(engine.replaced.map { $0.trashed.path }), created \(engine.created.map { $0.lastPathComponent }), "
            + "source exists \(FileManager.default.fileExists(atPath: source.path))"
        XCTAssertEqual(resolver.asked, 0, what, file: file, line: line)
        XCTAssertTrue(engine.errors.isEmpty, what, file: file, line: line)
        XCTAssertTrue(engine.replaced.isEmpty, what, file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: source), original, what, file: file, line: line)
        if mode == .move {
            XCTAssertTrue(engine.moved.isEmpty, what, file: file, line: line)
        } else {
            XCTAssertEqual(engine.created.map { $0.lastPathComponent }, ["\(token) copy.txt"], what, file: file, line: line)
            XCTAssertEqual(try? Data(contentsOf: root.appendingPathComponent("real/\(token) copy.txt")), original, what,
                           file: file, line: line)
        }
    }

    func testCopyAndMoveIntoSymlinkToOwnFolderKeepSource() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "real")
        let link = root.appendingPathComponent("link")
        try assertSelfDestinationIsSafe(.copy, to: link, clones: true)
        try assertSelfDestinationIsSafe(.copy, to: link, clones: false)
        try assertSelfDestinationIsSafe(.move, to: link, clones: true)
    }

    func testCopyAndMoveIntoCaseVariantOfOwnFolderKeepSource() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        let upper = root.appendingPathComponent("REAL")
        guard FileManager.default.fileExists(atPath: upper.path) else { throw XCTSkip("temp volume is case-sensitive") }
        try assertSelfDestinationIsSafe(.copy, to: upper, clones: true)
        try assertSelfDestinationIsSafe(.copy, to: upper, clones: false)
        try assertSelfDestinationIsSafe(.move, to: upper, clones: true)
    }

    func testCopyAndMoveIntoPrivateAliasOfOwnFolderKeepSource() throws {
        guard root.path.hasPrefix("/var/") else { throw XCTSkip("temp folder is not under /var") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        let alias = URL(fileURLWithPath: "/private" + root.appendingPathComponent("real").path)
        try assertSelfDestinationIsSafe(.copy, to: alias, clones: true)
        try assertSelfDestinationIsSafe(.copy, to: alias, clones: false)
        try assertSelfDestinationIsSafe(.move, to: alias, clones: true)
    }

    /// `root` as reached through the Data-volume firmlink (/System/Volumes/Data/private/var/...), or nil if
    /// that path doesn't exist or isn't the same folder.
    private func firmlinkRoot() -> URL? {
        guard let resolved = realpath(root.path, nil) else { return nil }
        let path = "/System/Volumes/Data" + String(cString: resolved)
        free(resolved)
        var a = stat(), b = stat()
        guard stat(root.path, &a) == 0, stat(path, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return nil }
        return URL(fileURLWithPath: path)
    }

    func testCopyAndMoveIntoFirmlinkPathOfOwnFolderKeepSource() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        guard let firm = firmlinkRoot() else { throw XCTSkip("no /System/Volumes/Data path to the temp folder") }
        let alias = firm.appendingPathComponent("real")
        try assertSelfDestinationIsSafe(.copy, to: alias, clones: true)
        try assertSelfDestinationIsSafe(.copy, to: alias, clones: false)
        try assertSelfDestinationIsSafe(.move, to: alias, clones: true)
    }

    /// Runs the engine on a background thread and cancels it if it copies more than `maxItems` files or runs
    /// past `timeout`, so a copy into its own subtree can't run away and fill the disk.
    private func runEngineGuarded(_ mode: CopyEngine.Mode, _ sources: [URL], to destination: URL, clones: Bool,
                                  maxItems: Int = 200, timeout: TimeInterval = 10) -> (engine: CopyEngine, runaway: Bool) {
        let operation = FileOperation(kind: mode == .move ? .move : .copy, sources: sources, destination: destination)
        let engine = CopyEngine(operation: operation, mode: mode)
        engine.useClones = clones
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { engine.run(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        var runaway = false
        while done.wait(timeout: .now() + 0.01) == .timedOut {
            if !runaway && (operation.snapshot.completedItems > maxItems || Date() > deadline) {
                runaway = true
                operation.cancel()
            }
        }
        return (engine, runaway)
    }

    /// In a fresh `base`, copies or moves the folder `real` into `target(base)`, another path for `real` or a
    /// folder inside it. It must be refused like a plain "into itself" drop: one error, nothing created,
    /// source untouched.
    private func assertIntoItselfIsRefused(_ mode: CopyEngine.Mode, clones: Bool, base: String,
                                           to target: (URL) -> URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = root.appendingPathComponent(base)
        try makeFile("\(base)/real/a.txt", size: 10)
        try makeFile("\(base)/real/sub/b.txt", size: 10)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("lnk").path, withDestinationPath: "real")
        let destination = target(dir)
        let real = dir.appendingPathComponent("real")
        let (engine, runaway) = runEngineGuarded(mode, [real], to: destination, clones: clones)
        var items = 0, deepest = 0
        for case let url as URL in FileManager.default.enumerator(at: real, includingPropertiesForKeys: nil) ?? .init() {
            items += 1
            deepest = max(deepest, url.path.count)
        }
        let what = "\(mode) clones=\(clones) to \(destination.path): runaway \(runaway), errors \(engine.errors.count) "
            + "\(engine.errors.prefix(2)), created \(engine.created.map { $0.path }), items under real \(items), "
            + "deepest path \(deepest) chars, files copied \(engine.operation.snapshot.completedItems)"
        XCTAssertFalse(runaway, what, file: file, line: line)
        XCTAssertEqual(engine.errors.count, 1, what, file: file, line: line)
        XCTAssertTrue(engine.errors.first?.contains("into itself") == true, what, file: file, line: line)
        XCTAssertTrue(engine.created.isEmpty, what, file: file, line: line)
        XCTAssertEqual(items, 3, what, file: file, line: line) // a.txt, sub, sub/b.txt
    }

    func testCopyAndMoveFolderIntoAliasOfItselfAreRefused() throws {
        // Unfixed code nests copies until PATH_MAX, deeper than FileManager can remove.
        let tree = root!
        addTeardownBlock {
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", tree.path]
            try? rm.run()
            rm.waitUntilExit()
        }
        var targets: [(String, (URL) -> URL)] = [("self", { $0.appendingPathComponent("lnk") }),
                                                 ("sub", { $0.appendingPathComponent("lnk/sub") })]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("probe"), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("PROBE").path) {
            targets.append(("case", { $0.appendingPathComponent("REAL/sub") }))
        }
        if root.path.hasPrefix("/var/") {
            targets.append(("private", { URL(fileURLWithPath: "/private" + $0.appendingPathComponent("real/sub").path) }))
        }
        if let firm = firmlinkRoot() {
            let firmPath = firm.path, rootPath = root.path
            targets.append(("firmlink", { URL(fileURLWithPath: firmPath + $0.path.dropFirst(rootPath.count) + "/real/sub") }))
        } else {
            print("firmlink target skipped: no /System/Volumes/Data path to the temp folder")
        }
        for (name, target) in targets {
            try assertIntoItselfIsRefused(.copy, clones: true, base: "\(name)-clone", to: target)
            try assertIntoItselfIsRefused(.copy, clones: false, base: "\(name)-copy", to: target)
            try assertIntoItselfIsRefused(.move, clones: true, base: "\(name)-move", to: target)
        }
    }

    /// A hard-linked twin in another folder is a real conflict: replacing it must keep the data.
    func testReplacingHardLinkTwinInAnotherFolderKeepsData() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        for mode in [CopyEngine.Mode.copy, .move] {
            let token = trashToken()
            let source = try makeFile("a/\(token).txt", size: 10, byte: 3)
            let original = try Data(contentsOf: source)
            let twin = root.appendingPathComponent("b/\(token).txt")
            try FileManager.default.linkItem(at: source, to: twin)
            let resolver = StubResolver(.replace)
            let engine = runEngine(mode, [source], to: root.appendingPathComponent("b"), clones: true, resolver: resolver)
            removeTrashed(by: engine)
            XCTAssertEqual(resolver.asked, 1, "\(mode)")
            XCTAssertTrue(engine.errors.isEmpty, "\(mode) \(engine.errors)")
            XCTAssertEqual(try? Data(contentsOf: twin), original, "\(mode)")
            if mode == .copy {
                XCTAssertEqual(try? Data(contentsOf: source), original)
                var a = stat(), b = stat()
                XCTAssertTrue(lstat(source.path, &a) == 0 && lstat(twin.path, &b) == 0)
                XCTAssertNotEqual(a.st_ino, b.st_ino, "copy must be a separate file")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            }
        }
    }
}
