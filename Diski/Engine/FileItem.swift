import Foundation
import UniformTypeIdentifiers

/// The kind of file-system object an entry represents.
enum EntryType: UInt8 {
    case file
    case directory
    /// A directory that presents itself as a single file (apps, bundles, `.rtfd`, ...).
    case package
    case symlink
    case other
}

/// One entry in a directory listing.
///
/// Entries are reference types so table and outline views can use them as
/// stable items. When a directory is refreshed, existing entries are updated
/// in place (see `update(from:)`) so selection and expansion state survive.
final class FileItem: Hashable, CustomStringConvertible {
    let name: String
    let parentPath: String
    private(set) var type: EntryType
    private(set) var fileID: UInt64
    /// Logical size in bytes for files and packages; `-1` when unknown (folders).
    private(set) var size: Int64
    private(set) var allocatedSize: Int64
    /// Seconds since 1970.
    private(set) var created: Double
    private(set) var modified: Double
    private(set) var added: Double
    private(set) var finderFlags: UInt16
    private(set) var bsdFlags: UInt32
    private(set) var mode: UInt32
    /// Number of entries in a directory, `-1` when unknown.
    private(set) var childCount: Int32
    private(set) var isMountPoint: Bool
    /// For symlinks: whether the link resolves to a directory.
    private(set) var linkTargetIsDirectory: Bool
    /// Dot-files and items with the BSD or Finder "hidden" flag (computed once:
    /// every arrange and every cell asks).
    private(set) var isHidden: Bool

    /// Recursive size computed in the background for folders (`-1` = not computed yet).
    var computedFolderSize: Int64 = -1

    init(name: String, parentPath: String, type: EntryType, fileID: UInt64, size: Int64,
         allocatedSize: Int64, created: Double, modified: Double, added: Double,
         finderFlags: UInt16, bsdFlags: UInt32, mode: UInt32, childCount: Int32,
         isMountPoint: Bool, linkTargetIsDirectory: Bool) {
        self.name = name
        self.parentPath = parentPath
        self.type = type
        self.fileID = fileID
        self.size = size
        self.allocatedSize = allocatedSize
        self.created = created
        self.modified = modified
        self.added = added
        self.finderFlags = finderFlags
        self.bsdFlags = bsdFlags
        self.mode = mode
        self.childCount = childCount
        self.isMountPoint = isMountPoint
        self.linkTargetIsDirectory = linkTargetIsDirectory
        isHidden = FileItem.hidden(name: name, bsdFlags: bsdFlags, finderFlags: finderFlags)
    }

    private static func hidden(name: String, bsdFlags: UInt32, finderFlags: UInt16) -> Bool {
        name.utf8.first == UInt8(ascii: ".") || (bsdFlags & UInt32(UF_HIDDEN)) != 0 || (finderFlags & 0x4000) != 0
    }

    private static let showsAllExtensions = UserDefaults.standard.bool(forKey: "AppleShowAllExtensions")

    // MARK: Derived values

    private var _path: String?
    var path: String {
        if let p = _path { return p }
        let p = parentPath == "/" ? "/" + name : parentPath + "/" + name
        _path = p
        return p
    }

    private var _url: URL?
    var url: URL {
        if let u = _url { return u }
        let u = URL(fileURLWithPath: path, isDirectory: type == .directory || type == .package)
        _url = u
        return u
    }

    private var _sortKey: NameSortKey?
    /// Pre-folded name used for fast natural sorting.
    var sortKey: NameSortKey {
        if let k = _sortKey { return k }
        let k = NameSortKey(name)
        _sortKey = k
        return k
    }

    private var _ext: String?
    /// Lower-cased path extension (empty when there is none).
    var ext: String {
        if let e = _ext { return e }
        var e = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            e = String(name[name.index(after: dot)...]).lowercased()
        }
        _ext = e
        return e
    }

    /// Whether double-clicking navigates into this entry.
    var isNavigable: Bool {
        type == .directory || (type == .symlink && linkTargetIsDirectory)
    }

    /// Folders and packages (anything that is a directory on disk).
    var isDirectoryOnDisk: Bool { type == .directory || type == .package }

    var isAlias: Bool { type == .file && (finderFlags & 0x8000) != 0 }
    var hasCustomIcon: Bool { (finderFlags & 0x0400) != 0 }
    var isLocked: Bool { (bsdFlags & UInt32(UF_IMMUTABLE)) != 0 }
    var isApplication: Bool { type == .package && ext == "app" }

    private var _applicationDisplayName: String?

    /// The name Finder shows: applications without ".app" unless all extensions are shown.
    var displayName: String {
        guard isApplication, !FileItem.showsAllExtensions, name.utf8.count > 4 else { return name }
        if let cached = _applicationDisplayName { return cached }
        let text = String(name.dropLast(4))
        _applicationDisplayName = text
        return text
    }

    /// Legacy Finder label index (0 = none, 1...7) kept in sync with the first colored tag.
    var labelIndex: Int { Int((finderFlags >> 1) & 0x7) }

    /// Size used for display and sorting: file size, or computed folder size.
    var displaySize: Int64 {
        switch type {
        case .directory: return computedFolderSize
        case .package: return size >= 0 ? size : computedFolderSize
        default: return size
        }
    }

    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
    var addedDate: Date? { added > 0 ? Date(timeIntervalSince1970: added) : nil }

    /// Copies the mutable attributes of a fresh read of the same entry into this one.
    /// Returns true when anything visible changed.
    @discardableResult
    func update(from other: FileItem) -> Bool {
        let changed = type != other.type || size != other.size || modified != other.modified
            || finderFlags != other.finderFlags || bsdFlags != other.bsdFlags
            || childCount != other.childCount || created != other.created || fileID != other.fileID
            || mode != other.mode || allocatedSize != other.allocatedSize || added != other.added
            || isMountPoint != other.isMountPoint || linkTargetIsDirectory != other.linkTargetIsDirectory
        if _sortKey == nil { _sortKey = other._sortKey }
        if _ext == nil { _ext = other._ext }
        type = other.type
        fileID = other.fileID
        size = other.size
        allocatedSize = other.allocatedSize
        created = other.created
        modified = other.modified
        added = other.added
        finderFlags = other.finderFlags
        bsdFlags = other.bsdFlags
        mode = other.mode
        childCount = other.childCount
        isMountPoint = other.isMountPoint
        linkTargetIsDirectory = other.linkTargetIsDirectory
        isHidden = other.isHidden
        if changed { _url = nil }
        return changed
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    var description: String { "FileItem(\(path))" }
}

extension FileItem {
    /// Builds an item for an arbitrary path with `lstat`, for places that do
    /// not come from a directory listing (sidebar, search results, drops).
    static func make(path rawPath: String) -> FileItem? {
        let path = rawPath.utf8.count > 1 && rawPath.utf8.last == UInt8(ascii: "/") ? String(rawPath.dropLast()) : rawPath
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        let parent = path == "/" ? "/" : (path as NSString).deletingLastPathComponent
        var type: EntryType
        var linkDir = false
        switch st.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFREG: type = .file
        case S_IFLNK:
            type = .symlink
            var target = stat()
            if stat(path, &target) == 0 { linkDir = (target.st_mode & S_IFMT) == S_IFDIR }
        default: type = .other
        }
        var finderFlags: UInt16 = 0
        var info = [UInt8](repeating: 0, count: 32)
        if getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW) == 32 {
            finderFlags = UInt16(info[8]) << 8 | UInt16(info[9])
        }
        if type == .directory && FileKinds.isPackage(name: name, finderFlags: finderFlags) {
            type = .package
        }
        let isMount: Bool = {
            guard type == .directory, path != "/" else { return path == "/" }
            var parentStat = stat()
            guard stat(parent, &parentStat) == 0 else { return false }
            return parentStat.st_dev != st.st_dev
        }()
        let created = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileItem(name: name, parentPath: parent, type: type, fileID: UInt64(st.st_ino),
                        size: type == .directory ? -1 : Int64(st.st_size),
                        allocatedSize: Int64(st.st_blocks) * 512,
                        created: created, modified: modified, added: 0,
                        finderFlags: finderFlags, bsdFlags: st.st_flags, mode: UInt32(st.st_mode),
                        childCount: -1, isMountPoint: isMount, linkTargetIsDirectory: linkDir)
    }
}
