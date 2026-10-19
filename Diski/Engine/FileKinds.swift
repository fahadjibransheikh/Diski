import Foundation
import UniformTypeIdentifiers

/// Thread-safe, cached answers to "what is this file?" questions.
/// Launch Services lookups are slow; everything here is cached per extension.
enum FileKinds {
    private static let lock = NSLock()
    private static var packageByExt: [String: Bool] = [:]
    private static var kindByKey: [String: String] = [:]
    private static var typeByKey: [String: UTType] = [:]
    private static var traitsByKey: [String: Traits] = [:]

    private static let maxCachedKeys = 4096

    static func preparationKey(for item: FileItem) -> String {
        if item.isAlias { return "/alias" }
        let executable = item.ext.isEmpty && item.type == .file && (item.mode & 0o111) != 0
        return (item.type == .package ? "/" : "") + item.ext + (executable ? "//x" : "")
    }

    /// The type checks the views make per cell, answered once per file key.
    private struct Traits: OptionSet {
        let rawValue: UInt8
        static let image = Traits(rawValue: 1)
        static let thumbnail = Traits(rawValue: 4)
    }

    /// Directories that Finder presents as a single file.
    static func isPackage(name: String, finderFlags: UInt16) -> Bool {
        if finderFlags & 0x2000 != 0 { return true } // kHasBundle
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        lock.lock()
        if let cached = packageByExt[ext] { lock.unlock(); return cached }
        lock.unlock()
        let isPackage = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        lock.lock()
        if packageByExt.count < maxCachedKeys { packageByExt[ext] = isPackage }
        lock.unlock()
        return isPackage
    }

    /// The content type for an item (cached per extension).
    static func type(for item: FileItem) -> UTType {
        switch item.type {
        case .directory:
            return item.isMountPoint ? .volume : .folder
        case .symlink:
            return .symbolicLink
        case .other:
            return .item
        case .file, .package:
            if item.isAlias { return .aliasFile }
            let key = preparationKey(for: item)
            lock.lock()
            if let cached = typeByKey[key] { lock.unlock(); return cached }
            lock.unlock()
            var type: UTType
            if item.ext.isEmpty {
                type = item.type == .package ? .package : ((item.mode & 0o111) != 0 ? .unixExecutable : .data)
            } else if item.type == .package {
                type = UTType(filenameExtension: item.ext, conformingTo: .directory) ?? .package
            } else {
                type = UTType(filenameExtension: item.ext) ?? .data
            }
            lock.lock()
            if typeByKey.count < maxCachedKeys { typeByKey[key] = type }
            lock.unlock()
            return type
        }
    }

    /// Finder-style "Kind" description ("Folder", "JPEG image", "Application", ...).
    static func kind(for item: FileItem) -> String {
        switch item.type {
        case .directory:
            return item.isMountPoint ? "Volume" : "Folder"
        case .symlink:
            return "Alias"
        case .other:
            return "Special File"
        case .file, .package:
            if item.isAlias { return "Alias" }
            let executable = item.ext.isEmpty && item.type == .file && (item.mode & 0o111) != 0
            // "//x" cannot collide with an extension: extensions never contain "/".
            let key = preparationKey(for: item)
            lock.lock()
            if let cached = kindByKey[key] { lock.unlock(); return cached }
            lock.unlock()
            var kind: String
            if executable {
                kind = "Unix executable"
            } else if item.ext.isEmpty {
                kind = item.type == .package ? "Package" : "Document"
            } else {
                let type = Self.type(for: item)
                if let description = type.localizedDescription, !type.isDynamic {
                    kind = description.prefix(1).uppercased() + description.dropFirst()
                } else {
                    kind = item.type == .package ? "Package" : "\(item.ext.uppercased()) file"
                }
            }
            lock.lock()
            if kindByKey.count < maxCachedKeys { kindByKey[key] = kind }
            lock.unlock()
            return kind
        }
    }

    static func prepare(for item: FileItem) {
        _ = kind(for: item)
        if item.type == .file { _ = traits(of: item) }
    }

    /// Items worth asking Quick Look for a real thumbnail.
    static func wantsThumbnail(_ item: FileItem) -> Bool {
        item.type == .file && item.size > 0 && traits(of: item).contains(.thumbnail)
    }

    /// What `type(for:)` depends on for a plain file ("/" cannot occur in an extension).
    private static func fileKey(_ item: FileItem) -> String {
        if item.isAlias { return "/alias" }
        if item.ext.isEmpty { return (item.mode & 0o111) != 0 ? "/x" : "/" }
        return item.ext
    }

    /// Up to eight Launch Services conformance checks, made once per file key.
    /// Only called for plain files.
    private static func traits(of item: FileItem) -> Traits {
        let key = fileKey(item)
        lock.lock()
        if let cached = traitsByKey[key] { lock.unlock(); return cached }
        lock.unlock()
        let t = type(for: item)
        var traits: Traits = []
        if t.conforms(to: .image) { traits.insert(.image) }
        if traits.contains(.image) || t.conforms(to: .movie) || t.conforms(to: .pdf)
            || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet)
            || t.identifier == "com.apple.iwork.pages.sffpages" || t.conforms(to: .threeDContent)
            // Audio: the cover art, or Quick Look's music tile in icon mode, like Finder.
            || t.conforms(to: .audio) {
            traits.insert(.thumbnail)
        }
        lock.lock()
        if traitsByKey.count < maxCachedKeys { traitsByKey[key] = traits }
        lock.unlock()
        return traits
    }
}
