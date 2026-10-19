import AppKit

/// Collection view with Finder-like keyboard handling and type-to-select.
final class FileCollectionView: NSCollectionView {
    weak var keyHandler: FileViewKeyHandling?
    var onTypeSelect: ((String) -> Void)?
    /// Selection colors follow focus: accent when focused, gray otherwise.
    var onFocusChange: (() -> Void)?
    private var typed = ""
    private var lastTyped: TimeInterval = 0

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let typing = now - lastTyped < 1.0
        if keyHandler?.handleKeyDown(event, typeSelecting: typing) == true { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }) {
            typed = typing ? typed + chars : chars
            lastTyped = now
            onTypeSelect?(typed)
            return
        }
        super.keyDown(with: event)
    }
}

final class CollectionImagePrefetcher {
    private weak var collection: NSCollectionView?
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var tokens: [String: String] = [:]
    private let content: () -> ([FileItem], CGFloat)

    init(collection: NSCollectionView, clip: NSClipView, content: @escaping () -> ([FileItem], CGFloat)) {
        self.collection = collection
        self.content = content
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                          object: clip, queue: .main) { [weak self] _ in
            self?.schedule()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        cancel()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        for token in tokens.values { ThumbnailCache.shared.cancel(token) }
        tokens.removeAll()
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.prefetch() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func prefetch() {
        guard let collection else { return }
        let visible = collection.indexPathsForVisibleItems().map { $0.item }
        guard let first = visible.min(), let last = visible.max() else { cancel(); return }
        let (items, points) = content()
        let count = min(64, max(1, visible.count))
        let lower = max(0, first - count), upper = min(items.count, last + count + 1)
        guard lower < upper else { cancel(); return }
        let candidates = (lower..<upper).filter { $0 < first || $0 > last }.map { items[$0] }
        let wanted = Set(candidates.map { $0.path })
        for path in Array(tokens.keys) where !wanted.contains(path) {
            ThumbnailCache.shared.cancel(tokens.removeValue(forKey: path))
        }
        let scale = collection.window?.backingScaleFactor ?? 2
        for item in candidates where tokens[item.path] == nil && FileKinds.wantsThumbnail(item) {
            guard ThumbnailCache.shared.cached(for: item, points: points, scale: scale, iconMode: true) == nil else { continue }
            let path = item.path
            if let token = ThumbnailCache.shared.request(for: item, points: points, scale: scale, iconMode: true,
                                                         completion: { [weak self] _ in self?.tokens.removeValue(forKey: path) }) {
                tokens[path] = token
            }
        }
    }
}

/// Finder's icon-view names: up to two lines, broken after a space, hyphen,
/// underscore or dot when possible, and the second line shortened in the
/// middle so the end of the name (its extension) stays visible.
enum IconLabelLayout {
    /// Laid-out names by font size, width and name: cells are configured on
    /// every reload and scroll, and a layout costs several text measurements.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4000
        return cache
    }()

    static func text(for name: String, font: NSFont, width: CGFloat) -> String {
        let key = "\(font.fontName)|\(font.pointSize)|\(width)|\(name)" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = layout(name, font: font, width: width)
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func layout(_ name: String, font: NSFont, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: attributes).width }
        guard width > 20, measure(name) > width else { return name }
        let characters = Array(name)
        // The most characters that fit on the first line.
        var low = 1, high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(characters[0..<mid])) <= width { low = mid } else { high = mid - 1 }
        }
        // Break between words; a dot only when there is no space, hyphen or
        // underscore ("Truth.m4a" stays together); else wherever it fills up.
        var split = low
        if let breakIndex = characters[0..<low].lastIndex(where: { " -_".contains($0) }), breakIndex >= low / 3 {
            split = breakIndex + 1
        } else if let dot = characters[0..<low].lastIndex(of: "."), dot >= low / 3 {
            split = dot + 1
        }
        let first = String(characters[0..<split]).trimmingCharacters(in: .whitespaces)
        let rest = String(characters[split...]).trimmingCharacters(in: .whitespaces)
        return first + "\n" + truncatingMiddle(rest, width: width, measure: measure)
    }

    /// Like Finder: both halves get the same width, and no space is kept next
    /// to the ellipsis.
    private static func truncatingMiddle(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(text) > width else { return text }
        let characters = Array(text)
        let ellipsis = "…"
        let half = (width - measure(ellipsis)) / 2
        // The longest start that fits in half the width.
        var low = 0, high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(characters[0..<mid])) <= half { low = mid } else { high = mid - 1 }
        }
        var head = characters[0..<low]
        while let last = head.last, last.isWhitespace { head = head.dropLast() }
        let start = String(head) + ellipsis
        // The longest end that fits in the rest.
        let room = width - measure(start)
        var tailLow = 0, tailHigh = characters.count - low
        while tailLow < tailHigh {
            let mid = (tailLow + tailHigh + 1) / 2
            if measure(String(characters[(characters.count - mid)...])) <= room { tailLow = mid } else { tailHigh = mid - 1 }
        }
        var tail = characters[(characters.count - tailLow)...]
        while let first = tail.first, first.isWhitespace { tail = tail.dropFirst() }
        return start + String(tail)
    }
}

/// Finder-style icon cell: icon with a soft highlight, name in a tinted capsule when selected.
final class IconItemView: NSView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let iconBackground = NSView()
    let nameBackground = NSView()
    weak var item: IconViewItem?
    private var iconSize: NSLayoutConstraint!
    private var showsSelection = false
    private var showsEmphasis = false
    private var showsDropTarget = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [iconBackground, nameBackground, icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 8
        iconBackground.layer?.cornerCurve = .continuous
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerRadius = 4
        nameBackground.layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.alignment = .center
        name.font = .systemFont(ofSize: 12)
        name.maximumNumberOfLines = 2
        name.usesSingleLineMode = false
        name.lineBreakMode = .byClipping
        name.cell?.wraps = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconSize = icon.widthAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconSize,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            iconBackground.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalTo: icon.widthAnchor, constant: 10),
            iconBackground.heightAnchor.constraint(equalTo: icon.heightAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            name.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Finder's pill hugs the name: the label's own 2 pt inset is the
            // padding, and it stays clear of the icon box.
            nameBackground.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            nameBackground.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            nameBackground.topAnchor.constraint(equalTo: name.topAnchor),
            nameBackground.bottomAnchor.constraint(equalTo: name.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIconSize(_ size: CGFloat) {
        if iconSize.constant != size { iconSize.constant = size }
    }

    /// Shows `fullName` laid out like Finder for an item `itemWidth` wide.
    func setName(_ fullName: String, itemWidth: CGFloat) {
        // Only editing makes the field wrap.
        if name.cell?.wraps == true {
            name.lineBreakMode = .byClipping
            name.cell?.wraps = false
        }
        name.stringValue = IconLabelLayout.text(for: fullName, font: name.font ?? .systemFont(ofSize: 12),
                                                width: max(40, itemWidth - 12))
    }

    /// The full name in an editable, wrapping field.
    func beginEditingName(_ fullName: String) {
        name.cell?.wraps = true
        name.lineBreakMode = .byCharWrapping
        name.stringValue = fullName
    }

    func applySelection(_ selected: Bool, emphasized: Bool, dropTarget: Bool = false) {
        showsSelection = selected
        showsEmphasis = emphasized
        showsDropTarget = dropTarget
        applyColors()
    }

    /// Layer colors are resolved in the view's own appearance, and again when it changes.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let box: NSColor? = self.showsDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.25)
                : (self.showsSelection ? NSColor.quaternaryLabelColor : nil)
            self.iconBackground.layer?.backgroundColor = box?.cgColor
            // The same blue as the list's selection, like Finder.
            let fill = self.showsEmphasis ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
            self.nameBackground.layer?.backgroundColor = self.showsSelection ? fill.cgColor : nil
        }
        name.textColor = showsSelection && showsEmphasis ? .alternateSelectedControlTextColor : .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { item?.openFromDoubleClick() }
    }
}

final class IconViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconViewItem")
    let loader = ItemImageLoader()
    weak var controller: IconViewController?
    private(set) var file: FileItem?

    var itemView: IconItemView { view as! IconItemView }

    override func loadView() {
        let view = IconItemView()
        view.item = self
        self.view = view
        imageView = view.icon
        textField = view.name
    }

    func configure(_ file: FileItem, iconSize: CGFloat, itemWidth: CGFloat, dimmed: Bool) {
        self.file = file
        itemView.setIconSize(iconSize)
        itemView.setName(file.displayName, itemWidth: itemWidth)
        itemView.name.isEditable = false
        // Finder's icon-view thumbnails: Quick Look's rounded, inset, shadowed style; music tiles for audio.
        loader.load(file, into: itemView.icon, points: iconSize, thumbnails: true, iconMode: true)
        itemView.icon.alphaValue = (dimmed || file.isHidden) ? 0.5 : 1
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelectionAppearance() }
    }

    func updateSelectionAppearance() {
        let emphasized = view.window?.isKeyWindow == true && view.window?.firstResponder === collectionView
        // Live while rubber-band selecting, like Finder.
        let shown = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        itemView.applySelection(shown, emphasized: emphasized, dropTarget: highlightState == .asDropTarget)
    }

    func openFromDoubleClick() {
        guard let file else { return }
        controller?.pane?.open([file], inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
        file = nil
    }
}

/// Finder's icon view shows no insertion line between icons.
final class IconGapIndicator: NSView, NSCollectionViewElement {}

final class IconViewController: FileViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
                                NSMenuDelegate, NSTextFieldDelegate, FileViewKeyHandling {
    static let gapIdentifier = NSUserInterfaceItemIdentifier("IconGap")
    let collectionView = FileCollectionView()
    private let scrollView = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let contextMenu = NSMenu()
    private var renamingItem: FileItem?
    private var draggedItems: [FileItem] = []
    /// Whole points: the size slider is continuous.
    private var iconSize: CGFloat = 64
    private var prefetcher: CollectionImagePrefetcher?

    override func loadView() {
        configureLayout()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyHandler = self
        collectionView.onTypeSelect = { [weak self] text in self?.typeSelect(text) }
        collectionView.onFocusChange = { [weak self] in self?.refreshSelectionAppearance() }
        collectionView.register(IconViewItem.self, forItemWithIdentifier: IconViewItem.identifier)
        collectionView.register(IconGapIndicator.self, forSupplementaryViewOfKind: NSCollectionView.elementKindInterItemGapIndicator,
                                withIdentifier: IconViewController.gapIdentifier)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        collectionView.registerForDraggedTypes(PaneViewController.acceptedDragTypes)
        contextMenu.delegate = self
        collectionView.menu = contextMenu

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view = scrollView
        prefetcher = CollectionImagePrefetcher(collection: collectionView, clip: scrollView.contentView) { [weak self] in
            (self?.items ?? [], self?.iconSize ?? 64)
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureLayout() {
        iconSize = max(16, Prefs.iconSize.rounded())
        // Finder's grid: 112 x 112 cells at 64 pt icons, no gaps between them.
        layout.itemSize = NSSize(width: max(112, iconSize + 48), height: iconSize + 48)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 9, left: 10, bottom: 14, right: 10)
    }

    // Finder's grid: a fixed pitch from the leading edge; spare width stays on the trailing side.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        insetForSectionAt section: Int) -> NSEdgeInsets {
        var inset = layout.sectionInset
        let width = collectionView.bounds.width
        let pitch = layout.itemSize.width
        // 10 pt stay free for overlay scrollers.
        let columns = max(1, ((width - inset.left - 10) / pitch).rounded(.down))
        inset.right = max(0, width - inset.left - columns * pitch)
        return inset
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === view.window else { return }
        refreshSelectionAppearance()
    }

    private func refreshSelectionAppearance() {
        for case let item as IconViewItem in collectionView.visibleItems() {
            item.updateSelectionAppearance()
        }
    }

    // MARK: Display

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        prefetcher?.cancel()
        prefetcher?.schedule()
        if reset || changes == nil || changes?.isInitialLoad == true {
            let selection = reset ? [] : selectedItems
            collectionView.reloadData()
            if reset { collectionView.scroll(.zero) } else { select(selection, scroll: false) }
            return
        }
        var removed = Set<IndexPath>()
        var inserted = Set<IndexPath>()
        // FileItem's == and hash are identity, so these compare identity.
        let oldSet = Set(previous), newSet = Set(items)
        let orderKept = previous.lazy.filter { newSet.contains($0) }.elementsEqual(items.lazy.filter { oldSet.contains($0) })
        var reloadAll = false
        if orderKept {
            // The items that stay kept their order: the difference is just what
            // left and what came (O(n), and the same as Myers' result).
            for (offset, file) in previous.enumerated() where !newSet.contains(file) {
                removed.insert(IndexPath(item: offset, section: 0))
            }
            for (offset, file) in items.enumerated() where !oldSet.contains(file) {
                inserted.insert(IndexPath(item: offset, section: 0))
            }
        } else if previous.count + items.count > 2000 {
            // Items moved. Myers is O(n·d): too slow on the main thread for big lists.
            reloadAll = true
        } else {
            for change in items.difference(from: previous) {
                switch change {
                case let .remove(offset, _, _): removed.insert(IndexPath(item: offset, section: 0))
                case let .insert(offset, _, _): inserted.insert(IndexPath(item: offset, section: 0))
                }
            }
        }
        if reloadAll || removed.count + inserted.count > 300 {
            let selection = selectedItems
            collectionView.reloadData()
            select(selection, scroll: false)
            return
        }
        collectionView.animator().performBatchUpdates({
            if !removed.isEmpty { collectionView.deleteItems(at: removed) }
            if !inserted.isEmpty { collectionView.insertItems(at: inserted) }
        }, completionHandler: nil)
        if let updated = changes?.updated, !updated.isEmpty { refresh(updated) }
        notifySelectionChanged()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconViewItem.identifier, for: indexPath)
        if let iconItem = item as? IconViewItem, indexPath.item < items.count {
            iconItem.controller = self
            let file = items[indexPath.item]
            iconItem.configure(file, iconSize: iconSize, itemWidth: layout.itemSize.width,
                               dimmed: pane?.isCut(file) ?? false)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: IconViewController.gapIdentifier, for: indexPath)
    }

    override func willDeactivate() {
        prefetcher?.cancel()
        for case let item as IconViewItem in collectionView.visibleItems() { item.loader.cancel() }
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let cell = item as? IconViewItem, indexPath.item < items.count else { return }
        let file = items[indexPath.item]
        cell.configure(file, iconSize: iconSize, itemWidth: layout.itemSize.width,
                       dimmed: pane?.isCut(file) ?? false)
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? IconViewItem)?.loader.cancel()
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        notifySelectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        notifySelectionChanged()
    }

    // MARK: Selection API

    override var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    override func select(_ files: [FileItem], scroll: Bool) {
        var paths = Set<IndexPath>()
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for (index, item) in items.enumerated() where wanted.contains(ObjectIdentifier(item)) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        collectionView.selectionIndexPaths = paths
        if scroll, !paths.isEmpty {
            collectionView.scrollToItems(at: paths, scrollPosition: .nearestHorizontalEdge)
        }
        refreshSelectionAppearance()
        notifySelectionChanged()
    }

    override func selectAllItems() { collectionView.selectAll(nil) }
    override func deselectAllItems() { collectionView.deselectAll(nil) }

    override func focus() {
        view.window?.makeFirstResponder(collectionView)
        refreshSelectionAppearance()
    }

    override func refresh(_ files: [FileItem]) {
        var paths = Set<IndexPath>()
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for (index, item) in items.enumerated() where wanted.contains(ObjectIdentifier(item)) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        if !paths.isEmpty { collectionView.reloadItems(at: paths) }
    }

    override func appearanceSettingsDidChange() {
        // Only the icon size affects this view; every other preference is a no-op here.
        guard max(16, Prefs.iconSize.rounded()) != iconSize else { return }
        configureLayout()
        layout.invalidateLayout()
        let selection = selectedItems
        collectionView.reloadData()
        select(selection, scroll: false)
    }

    override func iconScreenRect(for file: FileItem) -> NSRect? {
        guard let index = items.firstIndex(where: { $0 === file }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconViewItem,
              let window = view.window else { return nil }
        let icon = item.itemView.icon
        return window.convertToScreen(icon.convert(icon.bounds, to: nil))
    }

    override func iconImage(for file: FileItem) -> NSImage? {
        guard let index = items.firstIndex(where: { $0 === file }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconViewItem else { return nil }
        return item.itemView.icon.image
    }

    private func typeSelect(_ text: String) {
        guard let match = items.first(where: { $0.name.range(of: text, options: [.caseInsensitive, .anchored]) != nil }) else {
            return
        }
        select([match], scroll: true)
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    // MARK: Rename

    override func beginRename(_ file: FileItem) {
        guard let index = items.firstIndex(where: { $0 === file }) else { return }
        let path = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: path) as? IconViewItem, let window = view.window else { return }
        renamingItem = file
        let field = item.itemView.name
        item.itemView.beginEditingName(file.name)
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        item.itemView.applySelection(false, emphasized: false)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NameCellView.editableRange(for: field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let file = renamingItem else { return }
        renamingItem = nil
        field.isEditable = false
        field.isSelectable = false
        let newName = field.stringValue
        view.window?.makeFirstResponder(collectionView)
        if newName == file.name || pane?.commitRename(file, to: newName) != true {
            (field.superview as? IconItemView)?.setName(file.displayName, itemWidth: layout.itemSize.width)
        }
        refreshSelectionAppearance()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let file = renamingItem,
           let field = control as? NSTextField {
            renamingItem = nil
            field.abortEditing()
            (field.superview as? IconItemView)?.setName(file.displayName, itemWidth: layout.itemSize.width)
            field.isEditable = false
            view.window?.makeFirstResponder(collectionView)
            refreshSelectionAppearance()
            return true
        }
        return false
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var targets: [FileItem] = []
        if let event = NSApp.currentEvent {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            if let path = collectionView.indexPathForItem(at: point), path.item < items.count {
                if collectionView.selectionIndexPaths.contains(path) {
                    targets = selectedItems
                } else {
                    select([items[path.item]], scroll: false)
                    targets = [items[path.item]]
                }
            }
        }
        pane?.populateContextMenu(menu, for: targets)
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < items.count else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggedItems = indexPaths.compactMap { $0.item < items.count ? items[$0.item] : nil }
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if operation == .delete { pane?.trash(draggedItems.map { $0.url }) }
        draggedItems = []
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let pane else { return [] }
        let index = proposedDropIndexPath.pointee.item
        var destination = directoryPath
        if proposedDropOperation.pointee == .on, index < items.count, items[index].isNavigable {
            destination = items[index].path
        } else {
            proposedDropOperation.pointee = .before
        }
        if pane.isSearchResults && destination == directoryPath { return [] }
        return pane.dragOperation(for: draggingInfo, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        var destination = directoryPath
        if dropOperation == .on, indexPath.item < items.count, items[indexPath.item].isNavigable {
            destination = items[indexPath.item].path
        }
        return pane?.performDrop(draggingInfo, destination: destination) ?? false
    }
}
