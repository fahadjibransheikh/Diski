import XCTest
@testable import Diski

final class EngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskiTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ relative: String, size: Int = 0, byte: UInt8 = 0x41) throws -> URL {
        let url = root.appendingPathComponent(relative)
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

    // MARK: Item updates, caches

    private func makeItem(type: EntryType = .file, size: Int64 = 10, allocatedSize: Int64 = 4096, mode: UInt32 = 0o644,
                          added: Double = 100, isMountPoint: Bool = false, linkTargetIsDirectory: Bool = false) -> FileItem {
        FileItem(name: "x", parentPath: "/tmp", type: type, fileID: 1, size: size, allocatedSize: allocatedSize,
                 created: 1, modified: 2, added: added, finderFlags: 0, bsdFlags: 0, mode: mode, childCount: -1,
                 isMountPoint: isMountPoint, linkTargetIsDirectory: linkTargetIsDirectory)
    }

    func testUpdateReportsEveryCopiedField() {
        // `chmod +x` changes only the mode (and ctime): the Kind column and icon must refresh.
        let variants: [(String, FileItem)] = [
            ("mode", makeItem(mode: 0o755)),
            ("allocatedSize", makeItem(allocatedSize: 8192)),
            ("added", makeItem(added: 200)),
            ("isMountPoint", makeItem(isMountPoint: true)),
            ("linkTargetIsDirectory", makeItem(linkTargetIsDirectory: true)),
        ]
        for (field, other) in variants {
            XCTAssertTrue(makeItem().update(from: other), "a changed \(field) is not reported")
        }
        XCTAssertFalse(makeItem().update(from: makeItem()))
    }

    func testFolderSizeCacheIsCapped() throws {
        let sizer = FolderSizer.shared
        let original = sizer.maxCached
        sizer.maxCached = 2
        addTeardownBlock { sizer.maxCached = original }
        var paths: [String] = []
        for i in 0..<3 {
            try makeFile("cap\(i)/f.bin", size: 100)
            let path = root.appendingPathComponent("cap\(i)").path
            paths.append(path)
            let done = expectation(description: "walk \(i)")
            sizer.size(of: path) { _ in done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        XCTAssertNil(sizer.cached(paths[0]), "the oldest entry survived the cap")
        XCTAssertNotNil(sizer.cached(paths[2]))
    }

    func testThumbnailKeyIncludesScale() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<64 { for y in 0..<64 { rep.setColor(NSColor(red: CGFloat(x) / 64, green: CGFloat(y) / 64, blue: 0.5, alpha: 1), atX: x, y: y) } }
        let url = root.appendingPathComponent("pic-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let item = try XCTUnwrap(FileItem.make(path: url.path))

        let done = expectation(description: "1x thumbnail delivered")
        var delivered: NSImage?
        ThumbnailCache.shared.request(for: item, points: 64, scale: 1) { delivered = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertNotNil(delivered, "Quick Look produced no thumbnail in the test host")
        XCTAssertNotNil(ThumbnailCache.shared.cached(for: item, points: 64, scale: 1))
        XCTAssertNil(ThumbnailCache.shared.cached(for: item, points: 64, scale: 2), "a 1x thumbnail served a 2x request")
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

    // MARK: PR-D2 hard links, rescan events

    func testFolderSizeCountsHardLinksOnce() throws {
        let big = try makeFile("links/big.bin", size: 5000)
        try makeFile("links/small.bin", size: 100)
        try FileManager.default.linkItem(at: big, to: root.appendingPathComponent("links/big-link.bin"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("links/sub"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: big, to: root.appendingPathComponent("links/sub/big-link2.bin"))
        let (bytes, items) = FolderSizer.Walk(root: root.appendingPathComponent("links").path).run()
        XCTAssertEqual(bytes, 5100)
        XCTAssertEqual(items, 5, "every link still counts as an item")
    }

    func testSubtreeInvalidationDropsCachedDescendants() throws {
        try makeFile("tree/child/a.bin", size: 100)
        try makeFile("tree2/b.bin", size: 100)
        let sizer = FolderSizer.shared
        let paths = ["tree", "tree/child", "tree2"].map { root.appendingPathComponent($0).path }
        for path in paths {
            let done = expectation(description: path)
            sizer.size(of: path) { _ in done.fulfill() }
            wait(for: [done], timeout: 10)
            XCTAssertNotNil(sizer.cached(path))
        }
        sizer.invalidate(subtrees: [paths[0]])
        XCTAssertNil(sizer.cached(paths[0]))
        XCTAssertNil(sizer.cached(paths[1]), "a cached descendant survived")
        XCTAssertNotNil(sizer.cached(paths[2]), "a sibling that only shares the name prefix was dropped")
        sizer.invalidate(subtrees: ["/"])
        XCTAssertNil(sizer.cached(paths[2]), "the root `/` did not drop a cached folder")
    }

    func testRescanFlagsAreRecognized() {
        let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            XCTAssertTrue(DirectoryWatcher.isRescan(FSEventStreamEventFlags(flag)), "flag \(flag)")
            XCTAssertTrue(DirectoryWatcher.isRescan(FSEventStreamEventFlags(flag) | dir), "flag \(flag) with ItemIsDir")
        }
        for flag in [0, kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemModified] {
            XCTAssertFalse(DirectoryWatcher.isRescan(FSEventStreamEventFlags(flag)), "flag \(flag)")
        }
    }

    func testRescanEventReachesWatcherCallback() throws {
        let tree = root.appendingPathComponent("tree").path
        try makeFile("tree/a.bin", size: 10)
        let watcher = DirectoryWatcher()
        let delivered = expectation(description: "onChange")
        var subtrees: [String] = []
        watcher.onChange = { _, _, roots in subtrees = roots; delivered.fulfill() }
        // What the FSEvents callback builds from a MustScanSubDirs / dropped-event flag.
        watcher.handle([(path: tree + "/", isFile: false, rescan: true)])
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(subtrees, [tree], "trailing slash stripped, rescan root reported")
    }

    func testRescanEventRefreshesWatchedListingsAndSizes() throws {
        try makeFile("tree/child/grand/f.bin", size: 100)
        let child = root.appendingPathComponent("tree/child").path
        let grand = child + "/grand"
        let store = DirectoryStore.shared, sizer = FolderSizer.shared
        store.beginWatching(child)
        addTeardownBlock { store.endWatching(child) }
        let listing = store.loadNow(child)
        XCTAssertEqual(listing.items.map(\.name), ["grand"])
        let sized = expectation(description: "sized")
        sizer.size(of: grand) { _ in sized.fulfill() }
        wait(for: [sized], timeout: 10)
        XCTAssertNotNil(sizer.cached(grand))

        // Nothing on disk changes, so only the rescan can re-read the listing or re-request the size.
        let readBefore = listing.lastRead
        let resized = expectation(forNotification: DirectoryStore.folderContentsDidChange, object: store) { note in
            (note.userInfo?["paths"] as? Set<String>)?.contains(grand) == true
        }
        store.watcher.handle([(path: root.appendingPathComponent("tree").path, isFile: false, rescan: true)])
        wait(for: [resized], timeout: 5)
        XCTAssertNil(sizer.cached(grand), "a cached size under the rescan root survived")
        let deadline = Date().addingTimeInterval(5)
        while listing.lastRead == readBefore && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(listing.lastRead, readBefore, "the watched listing under the root was not re-read")
    }
}
