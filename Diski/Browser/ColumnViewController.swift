import AppKit

final class ColumnTableView: NSTableView {
    weak var keyHandler: FileViewKeyHandling?
    var onBecomeFirstResponder: (() -> Void)?
    var onArrow: ((_ left: Bool) -> Bool)?
    private var lastTypeSelect: TimeInterval = 0

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let typing = ProcessInfo.processInfo.systemUptime - lastTypeSelect < 1.0
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, event.keyCode == 123 || event.keyCode == 124 {
            if onArrow?(event.keyCode == 123) == true { return }
        }
        if keyHandler?.handleKeyDown(event, typeSelecting: typing) == true { return }
        if event.isTypeSelectKey { lastTypeSelect = ProcessInfo.processInfo.systemUptime }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, !field.isEditable { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRowHeight()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRowHeight()
    }

    /// Finder's rows: 22.5 pt on Retina (45 px), 22 pt on 1x screens, where NSTableView would round 22.5 up to 23.
    private func updateRowHeight() {
        let height: CGFloat = (window?.backingScaleFactor ?? 2) > 1.5 ? 20.5 : 20
        if rowHeight != height { rowHeight = height }
    }
}

final class ColumnCellView: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    let tags = TagDotView()
    let loader = ItemImageLoader()
    /// 0 without a tag dot, so an untagged name runs right up to the chevron.
    private var tagsGap: NSLayoutConstraint!
    private static let chevronImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
    /// Finder's chevron on the blue highlight is translucent white, not solid.
    private static let emphasizedChevron = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.6)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [icon, name, chevron, tags] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        name.allowsExpansionToolTips = true
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = Self.chevronImage
        chevron.contentTintColor = .tertiaryLabelColor
        tags.isHidden = true
        tagsGap = tags.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 0)
        // Finder's metrics: 16 pt icon 6 pt into the highlight, the name field 5 pt
        // after the icon (its ink 21 pt after the icon's), the chevron about 6 pt
        // before the highlight's end.
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagsGap,
            tags.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: tags.trailingAnchor, constant: 2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, dimmed: Bool) {
        objectValue = item
        name.stringValue = item.displayName
        if name.isEditable { name.isEditable = false }
        chevron.isHidden = !item.isNavigable
        loader.load(item, into: icon, points: 16, thumbnails: Prefs.showThumbnailsInList, iconMode: true)
        icon.alphaValue = (dimmed || item.isHidden) ? 0.5 : 1
        let label = item.labelIndex
        // Unchanged tags skip TagDotView's didSet (and the Auto Layout pass it causes).
        let colors: [NSColor] = label > 0 ? [TagColors.color(forLabel: label)] : []
        if tags.colors != colors { tags.colors = colors }
        let gap: CGFloat = colors.isEmpty ? 0 : 4
        if tagsGap.constant != gap { tagsGap.constant = gap }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { chevron.contentTintColor = backgroundStyle == .emphasized ? Self.emphasizedChevron : .tertiaryLabelColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loader.cancel()
        } else if let item = objectValue as? FileItem {
            loader.load(item, into: icon, points: 16, thumbnails: Prefs.showThumbnailsInList, iconMode: true)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
    }
}

/// A column's own (vertical) scroll view. Sideways swipes and shift-scrolling
/// belong to the strip of columns around it, so they are handed to it; without
/// this the columns scrolled out of sight on the left cannot be reached.
final class ColumnScrollView: NSScrollView {
    private var forwardsHorizontal = false

    override func scrollWheel(with event: NSEvent) {
        // Decide once per gesture (momentum follows the gesture); a wheel has no phases.
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            forwardsHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if forwardsHorizontal, let strip = enclosingScrollView {
            strip.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Lays columns out side by side with fixed widths. Manual layout keeps the
/// horizontal scroller's document view from driving the window's size.
final class ColumnsDocumentView: NSView {
    override var isFlipped: Bool { true }
    private(set) var entries: [(view: NSView, width: CGFloat)] = []
    /// Legacy scrollers: each column's track is the divider, so no separators are drawn.
    var hidesDividers = false { didSet { if hidesDividers != oldValue { needsLayout = true } } }

    private(set) var contentWidth: CGFloat = 0

    func append(_ view: NSView, width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
        entries.append((view, width))
        contentWidth += width
        needsLayout = true
    }

    func remove(_ view: NSView) {
        for entry in entries where entry.view === view { contentWidth -= entry.width }
        entries.removeAll { $0.view === view }
        view.removeFromSuperview()
        needsLayout = true
    }

    func setWidth(_ width: CGFloat, for view: NSView) {
        guard let index = entries.firstIndex(where: { $0.view === view }), entries[index].width != width else { return }
        contentWidth += width - entries[index].width
        entries[index].width = width
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for entry in entries {
            entry.view.frame = NSRect(x: x, y: 0, width: entry.width, height: bounds.height)
            if let box = entry.view as? NSBox {
                // No line where the strip ends at the preview pane or the window edge; legacy scroller tracks divide the columns themselves.
                let hide = hidesDividers || x + entry.width >= bounds.width - 8
                if box.isHidden != hide { box.isHidden = hide }
            }
            x += entry.width
        }
    }
}

/// Finder's column view: one column per folder from the volume root down,
/// with a preview column when a file is selected.
final class ColumnViewController: FileViewController, NSTableViewDataSource, NSTableViewDelegate,
                                  NSMenuDelegate, NSTextFieldDelegate, FileViewKeyHandling {
    final class Column {
        let path: String
        var items: [FileItem]
        let scroll = ColumnScrollView()
        let table = ColumnTableView()
        let separator = NSBox()

        init(path: String, items: [FileItem]) {
            self.path = path
            self.items = items
        }
    }

    private let scrollView = NSScrollView()
    private let document = ColumnsDocumentView()
    private var columns: [Column] = []
    private var preview: NSView?
    private(set) var activeColumn = 0 {
        didSet { if activeColumn != oldValue { revealActiveColumn() } }
    }

    /// Arrowing left or right into a column scrolled out of sight brings it back into view.
    private func revealActiveColumn() {
        guard !isSyncing, activeColumn < columns.count else { return }
        document.layoutSubtreeIfNeeded()
        document.scrollToVisible(columns[activeColumn].scroll.frame)
    }
    private var isSyncing = false
    private var renamingItem: FileItem?
    private let contextMenu = NSMenu()
    private var draggedItems: [FileItem] = []
    private static let cellID = NSUserInterfaceItemIdentifier("ColumnCell")

    private static let nameAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]

    /// Like Finder, each column is as wide as its longest name needs, within limits.
    private static func fittedWidth(for items: [FileItem]) -> CGFloat {
        // Only the longest names can be the widest: measure at most 96 of them (O(n) length histogram).
        var candidates = items
        if items.count > 96 {
            var histogram = [Int](repeating: 0, count: 256)
            for item in items { histogram[min(item.displayName.utf16.count, 255)] += 1 }
            var threshold = 255, count = 0
            while threshold > 0 { count += histogram[threshold]; if count >= 96 { break }; threshold -= 1 }
            candidates = Array(items.lazy.filter { min($0.displayName.utf16.count, 255) >= threshold }.prefix(128))
        }
        var widest: CGFloat = 0
        var tagged = false
        for item in candidates {
            widest = max(widest, (item.displayName as NSString).size(withAttributes: nameAttributes).width)
            if item.labelIndex > 0 { tagged = true }
        }
        // .inset cell padding (16 + 16), icon 16 + 5, label padding 4, 2 + chevron 8; tag dot 4 + 10.
        var chrome: CGFloat = 67 + (tagged ? 14 : 0)
        if NSScroller.preferredScrollerStyle == .legacy {
            chrome += NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        // Capped so one long name doesn't push the other columns off screen.
        return min(340, max(152, (widest + chrome).rounded(.up)))
    }

    /// Legacy (always visible) scrollers take room in every column and replace the dividers.
    private var legacyScrollers: Bool { NSScroller.preferredScrollerStyle == .legacy }

    override func loadView() {
        document.autoresizingMask = []
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Each column scrolls (and insets under the toolbar) on its own.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true
        contextMenu.delegate = self
        document.hidesDividers = legacyScrollers
        view = scrollView
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(directoryDidUpdate(_:)), name: DirectoryStore.didUpdate, object: nil)
        center.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(scrollerStyleChanged),
                           name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    @objc private func clipResized() {
        resizeDocument()
    }

    /// Legacy scrollers: like Finder, each column's always-visible track is its divider (no hairline next to it).
    @objc private func scrollerStyleChanged() {
        let legacy = legacyScrollers
        for column in columns {
            column.scroll.autohidesScrollers = !legacy
            document.setWidth(Self.fittedWidth(for: column.items), for: column.scroll)
        }
        document.hidesDividers = legacy
        resizeDocument()
    }

    private func resizeDocument() {
        let clip = scrollView.contentView.bounds.size
        let size = NSSize(width: max(document.contentWidth, clip.width), height: clip.height)
        if document.frame.size != size {
            document.frame = NSRect(origin: .zero, size: size)
        }
        document.needsLayout = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for column in columns { DirectoryStore.shared.endWatching(column.path) }
    }

    override func willDeactivate() {
        for column in columns {
            DirectoryStore.shared.endWatching(column.path)
            document.remove(column.scroll)
            document.remove(column.separator)
        }
        columns.removeAll()
        removePreview()
    }

    /// The deepest folder shown (window title, path bar).
    var deepestPath: String { columns.last?.path ?? directoryPath }

    override var targetDirectory: String {
        guard activeColumn < columns.count else { return deepestPath }
        return columns[activeColumn].path
    }

    // MARK: Building

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        if reset || columns.isEmpty || !columns.contains(where: { $0.path == directoryPath }) {
            rebuild(to: directoryPath)
        } else if changes == nil {
            // Sort or visibility changed: re-arrange every column.
            for column in columns {
                let listing = DirectoryStore.shared.listing(for: column.path)
                replaceItems(of: column, with: pane?.arrange(listing.items) ?? listing.items)
            }
        } else if let column = columns.first(where: { $0.path == directoryPath }) {
            // The deepest folder changed on disk (the pane's listing; directoryDidUpdate leaves it to the pane).
            replaceItems(of: column, with: items) // the pane's already-arranged items
        }
    }

    /// A folder's items for a new column: a cached listing shows at once and is quietly re-read in the background when stale (directoryDidUpdate then refreshes the column); an uncached one is read now.
    private func columnItems(for path: String) -> [FileItem] {
        let store = DirectoryStore.shared
        let listing = store.listing(for: path)
        if listing.isLoaded {
            store.load(path)
        } else {
            store.loadNow(path)
        }
        return pane?.arrange(listing.items) ?? listing.items
    }

    private func rebuild(to path: String) {
        isSyncing = true
        defer { isSyncing = false }
        for column in columns {
            DirectoryStore.shared.endWatching(column.path)
            document.remove(column.scroll)
            document.remove(column.separator)
        }
        columns.removeAll()
        removePreview()

        let root = VolumeMonitor.shared.volume(containing: path)?.path ?? "/"
        var chain: [String] = []
        var current = path
        while true {
            chain.append(current)
            if current == root || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        chain.reverse()
        for (index, directory) in chain.enumerated() {
            let arranged: [FileItem]
            if directory == path {
                arranged = items
            } else {
                arranged = columnItems(for: directory)
            }
            let column = addColumn(path: directory, items: arranged)
            if index + 1 < chain.count, let row = column.items.firstIndex(where: { $0.path == chain[index + 1] }) {
                column.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                column.table.scrollRowToVisible(row)
            }
        }
        activeColumn = max(0, columns.count - 1)
        scrollToEnd(animated: false)
    }

    @discardableResult
    private func addColumn(path: String, items: [FileItem]) -> Column {
        let column = Column(path: path, items: items)
        let table = column.table
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = 20.5
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.keyHandler = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = contextMenu
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        table.registerForDraggedTypes(PaneViewController.acceptedDragTypes)
        table.onBecomeFirstResponder = { [weak self, weak column] in
            guard let self, let column, let index = self.columns.firstIndex(where: { $0 === column }) else { return }
            if self.activeColumn != index {
                self.activeColumn = index
                self.notifySelectionChanged()
            }
        }
        table.onArrow = { [weak self, weak column] left in
            guard let self, let column, let index = self.columns.firstIndex(where: { $0 === column }) else { return false }
            return self.handleArrow(left: left, from: index)
        }

        column.scroll.documentView = table
        column.scroll.hasVerticalScroller = true
        column.scroll.autohidesScrollers = !legacyScrollers
        column.scroll.drawsBackground = false
        column.scroll.borderType = .noBorder
        column.separator.boxType = .separator

        document.append(column.scroll, width: Self.fittedWidth(for: items))
        document.append(column.separator, width: 1)
        if !isSyncing { resizeDocument() }
        columns.append(column)
        DirectoryStore.shared.beginWatching(path)
        table.reloadData()
        return column
    }

    private func removeColumns(after index: Int) {
        removePreview()
        while columns.count > index + 1 {
            let column = columns.removeLast()
            DirectoryStore.shared.endWatching(column.path)
            document.remove(column.scroll)
            document.remove(column.separator)
        }
        resizeDocument()
    }

    private func removePreview() {
        if let preview {
            previewController.show(items: [], folderPath: nil)
            document.remove(preview)
        }
        preview = nil
        resizeDocument()
    }

    /// One preview, reused for every file: it looks like the preview pane, and
    /// each selection cancels the previous thumbnail request.
    private lazy var previewController: InspectorViewController = {
        let controller = InspectorViewController()
        self.addChild(controller)
        return controller
    }()

    private func showPreview(for item: FileItem) {
        let view = previewController.view
        document.append(view, width: 300)
        preview = view
        resizeDocument()
        // Lay the column out first so the thumbnail is requested at the preview's real size, not 64 pt.
        document.layoutSubtreeIfNeeded()
        previewController.show(items: [item], folderPath: nil) // cancels the previous thumbnail request
    }

    private func scrollToEnd(animated: Bool) {
        resizeDocument()
        document.layoutSubtreeIfNeeded()
        let width = document.contentWidth
        let visible = scrollView.contentView.bounds.width
        let x = max(0, width - visible)
        let point = NSPoint(x: x, y: 0)
        guard scrollView.contentView.bounds.origin != point else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
        } else {
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func replaceItems(of column: Column, with newItems: [FileItem]) {
        let selected = column.table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
        column.items = newItems
        document.setWidth(Self.fittedWidth(for: newItems), for: column.scroll)
        resizeDocument()
        isSyncing = true
        column.table.reloadData()
        let wanted = Set(selected.map { ObjectIdentifier($0) })
        var rows = IndexSet()
        for (row, item) in newItems.enumerated() where wanted.contains(ObjectIdentifier(item)) { rows.insert(row) }
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncing = false
        // A folder whose column is open may have disappeared.
        if let index = columns.firstIndex(where: { $0 === column }), rows.isEmpty, index < columns.count - 1 {
            removeColumns(after: index)
            columnsDidChange()
        }
    }

    @objc private func directoryDidUpdate(_ notification: Notification) {
        // The pane's own listing (the deepest folder) arrives arranged through itemsDidChange.
        guard let listing = notification.object as? DirectoryStore.Listing, listing !== pane?.listing,
              let column = columns.first(where: { $0.path == listing.path }) else { return }
        replaceItems(of: column, with: pane?.arrange(listing.items) ?? listing.items)
    }

    private func columnInfo(for tableView: NSTableView) -> (Int, Column)? {
        guard let index = columns.firstIndex(where: { $0.table === tableView }) else { return nil }
        return (index, columns[index])
    }

    private func columnsDidChange() {
        pane?.adoptColumnLocation(deepestPath)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        columnInfo(for: tableView)?.1.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let (_, column) = columnInfo(for: tableView), row < column.items.count else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? ColumnCellView
            ?? { let c = ColumnCellView(); c.identifier = Self.cellID; return c }()
        let item = column.items[row]
        cell.configure(item, dimmed: pane?.isCut(item) ?? false)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let (_, column) = columnInfo(for: tableView), row < column.items.count else { return nil }
        return column.items[row].displayName
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let table = notification.object as? NSTableView, let (index, column) = columnInfo(for: table) else { return }
        activeColumn = index
        let selected = table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
        removeColumns(after: index)
        if selected.count == 1 {
            let item = selected[0]
            if item.isNavigable {
                var path = item.path
                if item.type == .symlink { path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
                addColumn(path: path, items: columnItems(for: path))
            } else {
                showPreview(for: item)
            }
        }
        scrollToEnd(animated: true)
        columnsDidChange()
        notifySelectionChanged()
    }

    private func handleArrow(left: Bool, from index: Int) -> Bool {
        if left {
            guard index > 0 else { return true }
            let previous = columns[index - 1]
            view.window?.makeFirstResponder(previous.table)
            activeColumn = index - 1
            // Collapse back to the folder selected in the previous column.
            isSyncing = true
            columns[index].table.deselectAll(nil)
            isSyncing = false
            removeColumns(after: index) // also removes the preview
            columnsDidChange()
            notifySelectionChanged()
            return true
        }
        guard index + 1 < columns.count else { return true }
        let next = columns[index + 1]
        view.window?.makeFirstResponder(next.table)
        if next.table.selectedRow < 0, !next.items.isEmpty {
            next.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        activeColumn = index + 1
        notifySelectionChanged()
        return true
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard let (_, column) = columnInfo(for: sender), sender.clickedRow >= 0, sender.clickedRow < column.items.count else { return }
        let item = column.items[sender.clickedRow]
        if item.isNavigable {
            pane?.navigate(to: item.path)
        } else {
            pane?.open([item])
        }
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    // MARK: Selection API

    override var selectedItems: [FileItem] {
        guard activeColumn < columns.count else { return [] }
        let column = columns[activeColumn]
        return column.table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
    }

    override func select(_ files: [FileItem], scroll: Bool) {
        guard !columns.isEmpty else { return }
        // The deepest column that holds the items (a re-sort keeps a folder selected in an earlier column).
        let wanted = Set(files.map { ObjectIdentifier($0) })
        var target = columns.count - 1
        var rows = IndexSet()
        if !wanted.isEmpty {
            for index in stride(from: columns.count - 1, through: 0, by: -1) {
                var found = IndexSet()
                for (row, item) in columns[index].items.enumerated() where wanted.contains(ObjectIdentifier(item)) { found.insert(row) }
                if !found.isEmpty { target = index; rows = found; break }
            }
        }
        let column = columns[target]
        activeColumn = target
        if column.table.selectedRowIndexes != rows { column.table.selectRowIndexes(rows, byExtendingSelection: false) }
        if scroll, let first = rows.first { column.table.scrollRowToVisible(first) }
    }

    override func selectAllItems() {
        guard activeColumn < columns.count else { return }
        columns[activeColumn].table.selectAll(nil)
    }

    override func deselectAllItems() {
        guard activeColumn < columns.count else { return }
        columns[activeColumn].table.deselectAll(nil)
    }

    override func focus() {
        guard activeColumn < columns.count else { return }
        view.window?.makeFirstResponder(columns[activeColumn].table)
    }

    override func refresh(_ files: [FileItem]) {
        let wanted = Set(files.map { ObjectIdentifier($0) })
        for column in columns {
            var rows = IndexSet()
            for (row, item) in column.items.enumerated() where wanted.contains(ObjectIdentifier(item)) { rows.insert(row) }
            if !rows.isEmpty { column.table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
        }
    }

    override func appearanceSettingsDidChange() {
        for column in columns { column.table.reloadData() }
    }

    override func iconScreenRect(for file: FileItem) -> NSRect? {
        for column in columns {
            guard let row = column.items.firstIndex(where: { $0 === file }),
                  let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnCellView,
                  let window = view.window else { continue }
            return window.convertToScreen(cell.icon.convert(cell.icon.bounds, to: nil))
        }
        return nil
    }

    override func iconImage(for file: FileItem) -> NSImage? {
        for column in columns {
            guard let row = column.items.firstIndex(where: { $0 === file }),
                  let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnCellView else { continue }
            return cell.icon.image
        }
        return nil
    }

    // MARK: Rename

    override func beginRename(_ file: FileItem) {
        for column in columns {
            guard let row = column.items.firstIndex(where: { $0 === file }) else { continue }
            column.table.scrollRowToVisible(row)
            guard let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCellView,
                  let window = view.window else { return }
            renamingItem = file
            cell.name.isEditable = true
            cell.name.isSelectable = true
            cell.name.delegate = self
            cell.name.lineBreakMode = .byClipping
            cell.name.stringValue = file.name   // the full name while editing
            window.makeFirstResponder(cell.name)
            cell.name.currentEditor()?.selectedRange = NameCellView.editableRange(for: file.name)
            return
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let file = renamingItem else { return }
        renamingItem = nil
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingMiddle
        focus()
        let newName = field.stringValue
        if newName == file.name || pane?.commitRename(file, to: newName) != true {
            field.stringValue = file.displayName
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let file = renamingItem,
           let field = control as? NSTextField {
            renamingItem = nil
            field.abortEditing()
            field.stringValue = file.displayName
            field.isEditable = false
            field.lineBreakMode = .byTruncatingMiddle
            focus()
            return true
        }
        return false
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var targets: [FileItem] = []
        for (index, column) in columns.enumerated() {
            let row = column.table.clickedRow
            guard row >= 0, row < column.items.count else { continue }
            activeColumn = index
            if column.table.selectedRowIndexes.contains(row) {
                targets = column.table.selectedRowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
            } else {
                column.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                targets = [column.items[row]]
            }
            break
        }
        pane?.populateContextMenu(menu, for: targets)
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let (_, column) = columnInfo(for: tableView), row < column.items.count else { return nil }
        return column.items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let (_, column) = columnInfo(for: tableView) else { return }
        draggedItems = rowIndexes.compactMap { $0 < column.items.count ? column.items[$0] : nil }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete { pane?.trash(draggedItems.map { $0.url }) }
        draggedItems = []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let pane, let (_, column) = columnInfo(for: tableView) else { return [] }
        var destination = column.path
        if dropOperation == .on, row < column.items.count, column.items[row].isNavigable {
            destination = column.items[row].path
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return pane.dragOperation(for: info, destination: destination)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let (_, column) = columnInfo(for: tableView) else { return false }
        var destination = column.path
        if dropOperation == .on, row >= 0, row < column.items.count, column.items[row].isNavigable {
            destination = column.items[row].path
        }
        return pane?.performDrop(info, destination: destination) ?? false
    }
}
