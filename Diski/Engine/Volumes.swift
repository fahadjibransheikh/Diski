import AppKit

struct VolumeInfo: Hashable {
    let url: URL
    /// `url.path`, stored: volume lookups compare it for every title and menu update.
    let path: String
    let name: String
    let isRoot: Bool
    let isInternal: Bool
    let isEjectable: Bool
    let isRemovable: Bool
    let isLocal: Bool
    let totalCapacity: Int64
    let availableCapacity: Int64
}

/// Mounted volumes, kept current through workspace mount notifications.
final class VolumeMonitor {
    static let shared = VolumeMonitor()
    static let didChange = Notification.Name("DiskiVolumesDidChange")
    /// Posted on the main thread when a value of `cachedAvailableCapacity` changed.
    static let capacityDidChange = Notification.Name("DiskiVolumeCapacityDidChange")

    private(set) var volumes: [VolumeInfo] = []
    private var observers: [NSObjectProtocol] = []

    private struct Capacity {
        var bytes: Int64
        var readAt: Date
    }
    /// Finder's free space per mount point, read in the background.
    private var capacities: [String: Capacity] = [:]
    private var capacityReads = Set<String>()
    private let capacityQueue = DispatchQueue(label: "app.diski.volumes", qos: .utility)

    /// Statfs-fast keys only: the purgeable-space key ("important usage") asks
    /// the system to size its caches, which takes up to hundreds of ms per volume.
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    private static let keySet = Set(keys)

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        // Usually ready by the time the first status bar draws.
        _ = cachedAvailableCapacity(forPath: "/")
    }

    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            guard let info = Self.info(for: url) else { continue }
            result.append(info)
        }
        // Boot volume first, then internal, then the rest by name.
        result.sort { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if result != volumes {
            volumes = result
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
        if values.volumeIsBrowsable == false { return nil }
        let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
        let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(url: url, path: url.path, name: name, isRoot: isRoot,
                          isInternal: values.volumeIsInternal ?? isRoot,
                          isEjectable: values.volumeIsEjectable ?? false,
                          isRemovable: values.volumeIsRemovable ?? false,
                          isLocal: values.volumeIsLocal ?? true,
                          totalCapacity: total, availableCapacity: available)
    }

    /// The volume containing `path` (longest mount-point prefix).
    func volume(containing path: String) -> VolumeInfo? {
        var best: VolumeInfo?
        var bestLength = -1
        for volume in volumes {
            let mount = volume.path
            if mount == "/" || path == mount || path.hasPrefix(mount + "/") {
                let length = mount.utf8.count
                if length > bestLength {
                    best = volume
                    bestLength = length
                }
            }
        }
        return best
    }

    /// Finder's free space (purgeable space included) for the volume holding
    /// `path`: the last known value at once (nil until the first read lands),
    /// refreshed in the background when older than `maxAge`. Posts
    /// `capacityDidChange` when a read changes it. Main thread only.
    func cachedAvailableCapacity(forPath path: String, maxAge: TimeInterval = 10) -> Int64? {
        let mount = volume(containing: path)?.path ?? "/"
        let known = capacities[mount]
        let fresh = known.map { Date().timeIntervalSince($0.readAt) <= maxAge } ?? false
        if !fresh && !capacityReads.contains(mount) {
            capacityReads.insert(mount)
            capacityQueue.async { [weak self] in
                let bytes = VolumeMonitor.availableCapacity(forPath: mount)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.capacityReads.remove(mount)
                    guard let bytes else { return }
                    let changed = self.capacities[mount]?.bytes != bytes
                    self.capacities[mount] = Capacity(bytes: bytes, readAt: Date())
                    if changed { NotificationCenter.default.post(name: VolumeMonitor.capacityDidChange, object: self) }
                }
            }
        }
        return known?.bytes
    }

    /// Marks every known free-space value as old (after copies, moves and
    /// deletions); the next `cachedAvailableCapacity` call re-reads it.
    func invalidateCapacities() {
        capacities = capacities.mapValues { Capacity(bytes: $0.bytes, readAt: .distantPast) }
    }

    /// Free space for the volume holding `path` (fresh value, not cached; slow:
    /// call it off the main thread).
    static func availableCapacity(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map { Int64($0) }
    }

    func eject(_ volume: VolumeInfo, completion: @escaping (Error?) -> Void) {
        let url = volume.url
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                self.refresh()
                completion(failure)
            }
        }
    }
}
