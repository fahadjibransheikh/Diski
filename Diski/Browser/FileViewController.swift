import AppKit

/// Base class for the four view modes (icons, list, columns, gallery).
/// The pane owns navigation, arranging and file actions; view modes only
/// display items and report selection.
class FileViewController: NSViewController {
    weak var pane: PaneViewController?
    private(set) var items: [FileItem] = []
    private(set) var directoryPath = ""

    /// Shows `items` (already arranged) for `directory`. When `changes` is
    /// non-nil the view may animate the difference; `reset` scrolls to the top.
    func display(items newItems: [FileItem], directory: String, changes: DirectoryStore.Changes?, reset: Bool) {
        let previous = items
        items = newItems
        directoryPath = directory
        itemsDidChange(from: previous, changes: changes, reset: reset)
    }

    /// Subclass hook.
    func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {}

    var selectedItems: [FileItem] { [] }
    func select(_ items: [FileItem], scroll: Bool) {}
    func selectAllItems() {}
    func deselectAllItems() {}
    func beginRename(_ item: FileItem) {}
    func focus() {}
    /// Items whose attributes changed (folder sizes, icons): refresh their cells.
    func refresh(_ items: [FileItem]) {}
    func appearanceSettingsDidChange() {}
    /// The folder new items and pastes go into (the focused column in column view).
    var targetDirectory: String { directoryPath }
    /// Screen rect of an item's icon, for Quick Look zoom animations.
    func iconScreenRect(for item: FileItem) -> NSRect? { nil }
    /// The image the item's cell shows right now (icon or thumbnail), for Quick Look's zoom.
    func iconImage(for item: FileItem) -> NSImage? { nil }
    /// Called before the view mode is replaced.
    func willDeactivate() {}

    func notifySelectionChanged() {
        pane?.viewSelectionDidChange(self)
    }
}

// MARK: - Shared cell helpers

/// Loads the best available image for an item into an image view: the type
/// icon immediately, then the item's own icon or a Quick Look thumbnail.
final class ItemImageLoader {
    private(set) weak var item: FileItem?
    private weak var imageView: NSImageView?
    private var thumbnailToken: String?
    /// What was last loaded: reconfiguring a cell for the same, unchanged item
    /// (folder sizes arriving, a rearrange) keeps its thumbnail or the request
    /// in flight instead of restarting it and flashing back to the type icon.
    private var loadedKey: (modified: Double, size: Int64, points: CGFloat, thumbnails: Bool, iconMode: Bool)?
    private var showsThumbnail = false
    private var generation = 0
    private static let iconQueue = DispatchQueue(label: "app.diski.cell-type-icons", qos: .userInitiated)

    /// `iconMode`: Quick Look's decorated thumbnail (rounded, inset, shadowed), as
    /// Finder shows files in its list, column and icon views; big previews stay plain.
    func load(_ item: FileItem, into imageView: NSImageView, points: CGFloat, thumbnails: Bool, iconMode: Bool = false) {
        if item === self.item, imageView === self.imageView, let k = loadedKey,
           k.modified == item.modified, k.size == item.size, k.points == points, k.thumbnails == thumbnails,
           k.iconMode == iconMode { return }
        cancel()
        self.item = item
        self.imageView = imageView
        loadedKey = (modified: item.modified, size: item.size, points: points, thumbnails: thumbnails, iconMode: iconMode)
        let wantsThumbnail = thumbnails && FileKinds.wantsThumbnail(item)
        let scale = imageView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if wantsThumbnail, let cached = ThumbnailCache.shared.cached(for: item, points: points, scale: scale, iconMode: iconMode) {
            imageView.image = cached
            showsThumbnail = true
            return
        }
        let requestGeneration = generation
        if let icon = IconCache.shared.cachedItemIcon(path: item.path) {
            imageView.image = icon
        } else {
            // A type seen before draws at once; only a new type's icon is fetched off the main thread.
            if let icon = IconCache.shared.cachedTypeIcon(for: item) {
                imageView.image = icon
            } else {
                imageView.image = nil
                Self.iconQueue.async {
                    let icon = IconCache.shared.icon(for: FileKinds.type(for: item))
                    DispatchQueue.main.async { [weak self, weak imageView] in
                        guard let self, self.generation == requestGeneration, !self.showsThumbnail,
                              imageView?.image == nil else { return }
                        imageView?.image = icon
                    }
                }
            }
            if IconCache.shared.needsItemIcon(item) {
                IconCache.shared.loadItemIcon(for: item) { [weak self, weak imageView] icon in
                    // A thumbnail that arrived first wins over the item's icon.
                    guard let self, self.item === item, self.generation == requestGeneration, !self.showsThumbnail else { return }
                    imageView?.image = icon
                }
            }
        }
        // request() answers failed keys at once (with nil), so no separate check.
        if wantsThumbnail {
            thumbnailToken = ThumbnailCache.shared.request(for: item, points: points, scale: scale,
                                                           iconMode: iconMode) { [weak self, weak imageView] image in
                guard let self, self.item === item, self.generation == requestGeneration else { return }
                self.thumbnailToken = nil
                guard let image else { return }
                self.showsThumbnail = true
                imageView?.image = image
            }
        }
    }

    func cancel() {
        generation += 1
        if let token = thumbnailToken {
            ThumbnailCache.shared.cancel(token)
            thumbnailToken = nil
        }
        item = nil
        loadedKey = nil
        showsThumbnail = false
    }
}

/// Finder tag colors by legacy label index (1...7).
enum TagColors {
    static let names = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
    static let sidebarOrder = [6, 7, 5, 2, 4, 3, 1] // Red, Orange, Yellow, Green, Blue, Purple, Gray

    static func color(forLabel index: Int) -> NSColor {
        switch index {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return .clear
        }
    }

    static func color(forTagName name: String) -> NSColor? {
        guard let index = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), index > 0 else {
            return nil
        }
        return color(forLabel: index)
    }
}

/// A small filled circle used for tag dots.
final class TagDotView: NSView {
    var colors: [NSColor] = [] {
        didSet {
            // Before the guard: a fresh view whose first value is [] must still hide.
            isHidden = colors.isEmpty
            guard colors != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: colors.isEmpty ? 0 : CGFloat(colors.count - 1) * 5 + 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Flat dots, no outline; the 9 pt dot is centred in its 10 pt frame.
        let d: CGFloat = 9, step: CGFloat = 5, y = (bounds.height - d) / 2
        for i in stride(from: colors.count - 1, through: 0, by: -1) {
            NSGraphicsContext.saveGraphicsState()
            if i > 0 { // 1 pt gap where the dot in front overlaps: shows the real row background, no outline
                let clip = NSBezierPath(rect: bounds)
                clip.append(NSBezierPath(ovalIn: NSRect(x: CGFloat(i - 1) * step + 0.5, y: y, width: d, height: d).insetBy(dx: -1, dy: -1)))
                clip.windingRule = .evenOdd
                clip.addClip()
            }
            colors[i].setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(i) * step + 0.5, y: y, width: d, height: d)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
