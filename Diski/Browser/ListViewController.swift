import AppKit

enum ListColumn: String, CaseIterable {
    case name, modified, created, added, size, kind

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .added: return "Date Added"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }

    var symbolName: String? {
        switch self {
        case .name: return nil
        case .modified: return "clock"
        case .created: return "calendar.badge.plus"
        case .added: return "tray.and.arrow.down"
        case .size: return "internaldrive"
        case .kind: return "doc"
        }
    }

    static let symbolSpace: CGFloat = 15

    var sortKey: SortKey {
        switch self {
        case .name: return .name
        case .modified: return .modified
        case .created: return .created
        case .added: return .added
        case .size: return .size
        case .kind: return .kind
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 420
        case .modified, .created, .added: return 150 + Self.symbolSpace
        case .size: return 84 + Self.symbolSpace
        case .kind: return 124 + Self.symbolSpace
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 110
        case .modified, .created, .added: return 64 + Self.symbolSpace
        case .size: return 76 + Self.symbolSpace // "Zero bytes", "999.9 MB" inside the 4-pt label insets
        case .kind: return 64 + Self.symbolSpace
        }
    }

    /// Narrow panes hide the least important columns first.
    var importance: Int {
        switch self {
        case .kind: return 0
        case .added: return 1
        case .created: return 2
        case .modified: return 3
        case .size: return 4
        case .name: return 5
        }
    }

    var isDate: Bool { self == .modified || self == .created || self == .added }
    var alignment: NSTextAlignment { self == .size ? .right : .left }

    init?(sortKey: SortKey) {
        switch sortKey {
        case .name: self = .name
        case .modified: self = .modified
        case .created: self = .created
        case .added: self = .added
        case .size: self = .size
        case .kind: self = .kind
        }
    }
}

/// Keyboard behavior shared by every view mode (Return, Space, Tab, ⌘↓...).
protocol FileViewKeyHandling: AnyObject {
    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool
}

extension NSEvent {
    /// A plain typed letter, digit, space or "." (Shift allowed): what the
    /// table-based views treat as type-to-select, so ⌘/⌃/⌥ combos don't count.
    var isTypeSelectKey: Bool {
        guard let chars = charactersIgnoringModifiers, !chars.isEmpty,
              modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." }
    }
}

final class FileOutlineView: NSOutlineView {
    weak var keyHandler: FileViewKeyHandling?
    /// Called when a drag leaves the list (spring-loading stops).
    var onDraggingExited: (() -> Void)?
    private var lastTypeSelect: TimeInterval = 0

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // NSTableView clears its own drop highlight here.
        super.draggingExited(sender)
        onDraggingExited?()
    }

    override func keyDown(with event: NSEvent) {
        let typing = ProcessInfo.processInfo.systemUptime - lastTypeSelect < 1.0
        if keyHandler?.handleKeyDown(event, typeSelecting: typing) == true { return }
        if event.isTypeSelectKey { lastTypeSelect = ProcessInfo.processInfo.systemUptime }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // Name fields only become first responder while renaming.
        if let field = responder as? NSTextField, !field.isEditable { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

// MARK: - Cells

final class NameCellView: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let tags = TagDotView()
    let loader = ItemImageLoader()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var nameGap: NSLayoutConstraint!
    private var tagGap: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.textColor = .labelColor
        name.cell?.truncatesLastVisibleLine = true
        // Truncated names show in full on hover, like Finder.
        name.allowsExpansionToolTips = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tags.translatesAutoresizingMaskIntoConstraints = false
        tags.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(name)
        addSubview(tags)
        imageView = icon
        textField = name
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 26)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 26)
        // Set per icon size in configure(_:iconSize:thumbnails:dimmed:).
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -1.5)
        nameGap = name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        tagGap = tags.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 5)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth, iconHeight,
            nameGap,
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagGap,
            tags.centerYAnchor.constraint(equalTo: centerYAnchor),
            tags.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, iconSize: CGFloat, thumbnails: Bool, dimmed: Bool) {
        objectValue = item
        // A cell reused while it was being renamed.
        if name.drawsBackground { endEditing() }
        // Finder keeps the names at one x for every icon size (cell + 20.5,
        // 28.5, 36.5) and moves the icon instead: its artwork starts about
        // 16 pt from the row edge, 4 pt before the name at 16-pt icons.
        let lead: CGFloat = iconSize <= 16 ? 0.5 : (iconSize <= 24 ? -0.5 : -1.5)
        let gap: CGFloat = iconSize <= 16 ? 4 : (iconSize <= 24 ? 5 : 6)
        if iconLeading.constant != lead { iconLeading.constant = lead }
        if nameGap.constant != gap { nameGap.constant = gap }
        if iconWidth.constant != iconSize { iconWidth.constant = iconSize }
        if iconHeight.constant != iconSize { iconHeight.constant = iconSize }
        let displayName = item.displayName
        if name.stringValue != displayName { name.stringValue = displayName }
        name.isEditable = false
        if name.toolTip != displayName { name.toolTip = displayName }
        loader.load(item, into: icon, points: iconSize, thumbnails: thumbnails, iconMode: true)
        icon.alphaValue = (dimmed || item.isHidden) ? 0.5 : 1
        let label = item.labelIndex
        let colors: [NSColor] = label > 0 ? [TagColors.color(forLabel: label)] : []
        if tags.colors != colors || tags.isHidden != colors.isEmpty { tags.colors = colors }
        // Without a tag dot the spacer would only cut the name short.
        let tagSpace: CGFloat = label > 0 ? 5 : 0
        if tagGap.constant != tagSpace { tagGap.constant = tagSpace }
    }

    func beginEditing(delegate: NSTextFieldDelegate) {
        guard let window else { return }
        name.isEditable = true
        name.isSelectable = true
        name.delegate = delegate
        // Finder's rename field: a text-background field with the native focus
        // ring, readable over the accent-colored selection; long names scroll.
        name.drawsBackground = true
        name.backgroundColor = .textBackgroundColor
        name.textColor = .textColor
        name.cell?.isScrollable = true
        name.lineBreakMode = .byClipping
        window.makeFirstResponder(name)
        if let editor = name.currentEditor() {
            editor.selectedRange = NameCellView.editableRange(for: name.stringValue)
        }
    }

    func endEditing() {
        name.isEditable = false
        name.isSelectable = false
        name.drawsBackground = false
        name.textColor = .labelColor
        name.cell?.isScrollable = false
        name.lineBreakMode = .byTruncatingMiddle
    }

    /// Finder selects the name without its extension when renaming.
    static func editableRange(for name: String) -> NSRange {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty || ext.count > 8 || name.hasPrefix(".") && ns.range(of: ".", options: .backwards).location == 0 {
            return NSRange(location: 0, length: ns.length)
        }
        return NSRange(location: 0, length: ns.length - (ext as NSString).length - 1)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loader.cancel()
    }
}

final class TextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private static var symbolImages: [String: NSImage] = [:]
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var rightLeadingConstraint: NSLayoutConstraint!
    private var rightTrailingConstraint: NSLayoutConstraint!
    private var isRightAligned = false
    private var configuredColumn: ListColumn?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.imageScaling = .scaleProportionallyDown
        symbol.contentTintColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Hugs its text, so a right-aligned value keeps its symbol right before it.
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(symbol)
        addSubview(label)
        textField = label
        leadingConstraint = symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        trailingConstraint = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        rightLeadingConstraint = symbol.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4)
        rightTrailingConstraint = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            leadingConstraint, trailingConstraint,
            symbol.widthAnchor.constraint(equalToConstant: 11),
            symbol.heightAnchor.constraint(equalToConstant: 11),
            symbol.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, column: ListColumn) {
        if label.stringValue == text, configuredColumn == column { return }
        configuredColumn = column
        label.stringValue = text
        label.alignment = column.alignment
        let rightAligned = column.alignment == .right
        if rightAligned != isRightAligned {
            NSLayoutConstraint.deactivate(isRightAligned
                ? [rightLeadingConstraint, rightTrailingConstraint] : [leadingConstraint, trailingConstraint])
            NSLayoutConstraint.activate(rightAligned
                ? [rightLeadingConstraint, rightTrailingConstraint] : [leadingConstraint, trailingConstraint])
            isRightAligned = rightAligned
        }
        if let name = column.symbolName {
            if Self.symbolImages[name] == nil,
               let image = NSImage(systemSymbolName: name, accessibilityDescription: column.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)) {
                image.isTemplate = true
                Self.symbolImages[name] = image
            }
            symbol.image = Self.symbolImages[name]
        } else {
            symbol.image = nil
        }
        symbol.setAccessibilityLabel(column.title)
        symbol.isHidden = text.isEmpty || column.symbolName == nil
        updateSymbolTint()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateSymbolTint() }
    }

    private func updateSymbolTint() {
        symbol.contentTintColor = backgroundStyle == .emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7)
            : .tertiaryLabelColor
    }

    /// Drags show only the icon and the name, like Finder.
    override var draggingImageComponents: [NSDraggingImageComponent] { [] }
}

private extension RowDensity {
    /// Finder on macOS 27: 20-pt rows with 16-pt icons (18 + 2 pt between
    /// rows); 33.5-pt rows with 32-pt icons.
    var listRowHeight: CGFloat {
        switch self {
        case .compact: return 18
        case .regular: return 26
        case .comfortable: return 31.5
        }
    }


}

// MARK: - List view

final class ListViewController: FileViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSMenuDelegate, NSTextFieldDelegate, FileViewKeyHandling {
    let outlineView = FileOutlineView()
    private let scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.contentView = VerticalClipView()
        return scrollView
    }()
    private let contextMenu = NSMenu()

    /// Arranged children of expanded folders, by folder path.
    private var childCache: [String: [FileItem]] = [:]
    private var expanded: [String: FileItem] = [:]
    private var renamingItem: FileItem?
    private var draggedItems: [FileItem] = []
    private var isApplyingSort = false
    /// Flat search results: no disclosure triangles.
    var isFlat = false

    /// The settings the rows are configured with. Prefs.didChange fires for
    /// every preference, most of which do not concern the list, and cells
    /// read these while scrolling instead of UserDefaults.
    private struct ListAppearance: Equatable {
        var density: RowDensity
        var thumbnails: Bool
        var folderSizes: Bool
        var columns: Set<String>
    }

    private static func currentAppearance() -> ListAppearance {
        ListAppearance(density: Prefs.rowDensity, thumbnails: Prefs.showThumbnailsInList,
                       folderSizes: Prefs.calculateFolderSizes, columns: Set(Prefs.listColumns))
    }

    private var listAppearance = ListViewController.currentAppearance()

    private static let nameCellID = NSUserInterfaceItemIdentifier("NameCell")
    /// One reuse queue per column, so reused cells keep their alignment and
    /// truncation and only their text changes.
    private static let textCellIDs: [ListColumn: NSUserInterfaceItemIdentifier] =
        Dictionary(uniqueKeysWithValues: ListColumn.allCases.map { ($0, NSUserInterfaceItemIdentifier("TextCell." + $0.rawValue)) })

    override func loadView() {
        listAppearance = Self.currentAppearance()
        let density = listAppearance.density
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsTypeSelect = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = density.listRowHeight
        outlineView.intercellSpacing = NSSize(width: 6, height: 2)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.keyHandler = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        outlineView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        outlineView.registerForDraggedTypes(PaneViewController.acceptedDragTypes)
        outlineView.draggingDestinationFeedbackStyle = .regular
        outlineView.onDraggingExited = { [weak self] in
            guard let self else { return }
            self.springWork?.cancel()
            self.springTarget = nil
            if self.outlineView.draggingDestinationFeedbackStyle != .regular {
                self.outlineView.draggingDestinationFeedbackStyle = .regular
            }
        }

        contextMenu.delegate = self
        outlineView.menu = contextMenu

        outlineView.headerView = nil
        outlineView.cornerView = nil
        buildColumns()
        // Restoring the autosaved columns also restores a sort; Prefs decide the
        // sort, and the pane has no content yet to re-sort.
        isApplyingSort = true
        outlineView.autosaveName = "DiskiListColumns"
        outlineView.autosaveTableColumns = true
        isApplyingSort = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        // The Name column absorbs the width instead (a horizontal scroller would
        // feed back into the fitted width and loop with legacy scroll bars).
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        view = scrollView

        NotificationCenter.default.addObserver(self, selector: #selector(directoryDidUpdate(_:)),
                                               name: DirectoryStore.didUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(folderContentsDidChange(_:)),
                                               name: DirectoryStore.folderContentsDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for path in expanded.keys { DirectoryStore.shared.endWatching(path) }
    }

    private var fittedWidth: CGFloat = 0
    private var isFitting = false
    private static let columnWidthsKey = "DiskiListColumnWidths"
    /// Widths the user gave the columns other than Name. Narrow panes shrink
    /// columns below these; they grow back when there is room again.
    private var preferredWidths: [String: CGFloat] =
        (UserDefaults.standard.dictionary(forKey: ListViewController.columnWidthsKey) as? [String: Double])?
            .mapValues { CGFloat($0) } ?? [:]
    /// The date format each date column has room for.
    private var dateLengths: [String: Formatters.DateLength] = [:]

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        guard !isFitting, abs(width - fittedWidth) > 0.5 else { return }
        fittedWidth = width
        isFitting = true
        fitColumns()
        isFitting = false
    }

    /// Like Finder, the Name column takes the width the other columns leave. In
    /// narrow panes it keeps a fair share: the other columns shrink in
    /// proportion (down to their minimums), and the least important ones are
    /// hidden until there is room, instead of being cut off at the edge.
    private func fitColumns() {
        let columns = outlineView.tableColumns
        guard let name = columns.first(where: { $0.identifier.rawValue == ListColumn.name.rawValue }) else { return }
        let others = columns.filter { $0 !== name }
        for column in others { column.width = preferredWidth(of: column) }
        outlineView.tile()
        let clip = scrollView.contentView.bounds.width
        let spacing = outlineView.intercellSpacing.width
        // The table's own insets, measured with the columns shown right now.
        let insets = contentWidth() - columns.filter { !$0.isHidden }.reduce(0) { $0 + $1.width + spacing }
        func room(for count: Int) -> CGFloat { clip - insets - CGFloat(count + 1) * spacing }

        // Names stay readable (about twenty characters after the disclosure
        // triangle and the icon) before any other column is kept.
        let nameFloor = max(name.minWidth, 200 + listAppearance.density.iconSize)
        var shown = others
        while let leastImportant = shown.min(by: { importance(of: $0) < importance(of: $1) }),
              nameFloor + shown.reduce(0, { $0 + $1.minWidth }) > room(for: shown.count) {
            shown.removeAll { $0 === leastImportant }
        }
        for column in others {
            let hidden = !shown.contains { $0 === column }
            if column.isHidden != hidden { column.isHidden = hidden }
        }

        let total = room(for: shown.count)
        let othersWidth = shown.reduce(0) { $0 + $1.width }
        let nameShare = max(nameFloor, (total * 0.4).rounded())
        if total - othersWidth >= nameShare {
            name.width = total - othersWidth
        } else {
            let scale = othersWidth > 0 ? max(0, total - nameShare) / othersWidth : 1
            var used: CGFloat = 0
            for column in shown {
                column.width = max(column.minWidth, (column.width * scale).rounded(.down))
                used += column.width
            }
            name.width = max(name.minWidth, total - used)
        }
        // Absorb rounding against the real layout.
        outlineView.tile()
        let excess = contentWidth() - clip
        if abs(excess) > 0.5 { name.width = max(name.minWidth, name.width - excess) }
        for column in shown { updateDateLength(for: column) }
    }

    /// The width the shown columns take, with the table's insets (the trailing
    /// inset mirrors the leading one).
    private func contentWidth() -> CGFloat {
        let columns = outlineView.tableColumns
        guard let first = columns.firstIndex(where: { !$0.isHidden }),
              let last = columns.lastIndex(where: { !$0.isHidden }) else { return 0 }
        return outlineView.rect(ofColumn: last).maxX + outlineView.rect(ofColumn: first).minX
    }

    private func importance(of column: NSTableColumn) -> Int {
        ListColumn(rawValue: column.identifier.rawValue)?.importance ?? 0
    }

    private func preferredWidth(of column: NSTableColumn) -> CGFloat {
        let id = column.identifier.rawValue
        return preferredWidths[id] ?? ListColumn(rawValue: id)?.defaultWidth ?? column.width
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        updateDateLength(for: column)
    }

    /// Date thresholds: the width each format needs, narrowest format first.
    private static var dateFormatWidths: [CGFloat] = []

    /// The longest date format that fits a column `width` points wide.
    private static func dateLength(forWidth width: CGFloat) -> Formatters.DateLength {
        if dateFormatWidths.isEmpty {
            // Wide samples: long weekday and month names, two-digit days,
            // months and hours (Wednesday, September 24 and December 31, 2025).
            let samples: [Double] = [9, 12].compactMap { (month: Int) -> Double? in
                var components = DateComponents()
                components.year = 2025
                components.month = month
                components.day = month == 9 ? 24 : 31
                components.hour = 12
                components.minute = 58
                return Calendar.current.date(from: components)?.timeIntervalSince1970
            }
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            dateFormatWidths = Formatters.DateLength.allCases.map { length in
                let widest = samples.map { sample in
                    (Formatters.listDate(sample, length: length) as NSString).size(withAttributes: [.font: font]).width
                }.max() ?? 0
                // 4-pt label insets and 2-pt text insets on both sides.
                return ceil(widest) + 12 + ListColumn.symbolSpace
            }
        }
        var best = Formatters.DateLength.dateOnly
        for length in Formatters.DateLength.allCases where dateFormatWidths[length.rawValue] <= width {
            best = length
        }
        return best
    }

    private func updateDateLength(for column: NSTableColumn) {
        guard let kind = ListColumn(rawValue: column.identifier.rawValue), kind.isDate else { return }
        let length = Self.dateLength(forWidth: column.width)
        guard dateLengths[kind.rawValue] != length else { return }
        dateLengths[kind.rawValue] = length
        let index = outlineView.column(withIdentifier: column.identifier)
        // Every row that has a view, including the ones prepared off screen
        // for responsive scrolling, so none keeps the old format.
        var rows = IndexSet()
        outlineView.enumerateAvailableRowViews { _, row in
            if row >= 0 { rows.insert(row) }
        }
        guard index >= 0, !rows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: index))
    }

    private func makeTableColumn(_ column: ListColumn) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = column.title
        tableColumn.width = column == .name ? column.defaultWidth : preferredWidths[column.rawValue] ?? column.defaultWidth
        tableColumn.minWidth = column.minWidth
        tableColumn.maxWidth = column == .name ? 4000 : 600
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue,
                                                               ascending: column.sortKey.defaultAscending)
        // Name always fills the row: widen it by narrowing the other columns.
        tableColumn.resizingMask = column == .name ? .autoresizingMask : .userResizingMask
        return tableColumn
    }

    private func buildColumns() {
        for column in outlineView.tableColumns { outlineView.removeTableColumn(column) }
        var columns: [ListColumn] = [.name]
        columns += Prefs.listColumns.compactMap { ListColumn(rawValue: $0) }.filter { $0 != .name }
        for column in columns {
            let tableColumn = makeTableColumn(column)
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        // Keep the table sort synchronized when columns change.
        syncSortIndicator(force: true)
        fittedWidth = 0
        if isViewLoaded { view.needsLayout = true }
    }

    /// Synchronizes the pane's sort descriptors. Only touches the table when the
    /// sort changed (or `force`, for columns that were just added).
    func syncSortIndicator(force: Bool = false) {
        guard let options = pane?.arrangeOptions else { return }
        let current = outlineView.sortDescriptors
        if force || current.count != 1 || current.first?.key != options.sortKey.rawValue
            || current.first?.ascending != options.ascending {
            isApplyingSort = true
            outlineView.sortDescriptors = [NSSortDescriptor(key: options.sortKey.rawValue, ascending: options.ascending)]
            isApplyingSort = false
        }

    }

    // MARK: Display

    override func itemsDidChange(from previous: [FileItem], changes: DirectoryStore.Changes?, reset: Bool) {
        guard isViewLoaded else { return }
        if reset {
            if renamingItem != nil {
                // Leaving the folder commits the rename, like Finder.
                view.window?.makeFirstResponder(outlineView)
                if renamingItem != nil { cancelRename() }
            }
            collapseAllWatching()
            sizeRequests.removeAll()
            outlineView.reloadData()
            outlineView.scrollRowToVisible(0)
            syncSortIndicator()
            requestAllSizesWhenSortedBySize()
            return
        }
        if let changes, !changes.isInitialLoad {
            applyDiff(old: previous, new: items, parent: nil)
            for item in changes.updated where item !== renamingItem && outlineView.row(forItem: item) >= 0 {
                outlineView.reloadItem(item, reloadChildren: false)
            }
            return
        }
        // Re-sorted or re-filtered without moving a row (sizes streaming in
        // while sorted by size, mostly): only expanded folders can change.
        if previous.count == items.count && zip(previous, items).allSatisfy({ $0 === $1 }) {
            syncSortIndicator()
            rearrangeExpandedFolders()
            return
        }
        // Re-sorted or re-filtered: one reload instead of hundreds of animated
        // row moves; selection and expansion are kept.
        if renamingItem != nil { cancelRename() }
        let selection = selectedItems
        childCache.removeAll()
        outlineView.reloadData()
        select(selection, scroll: false)
        syncSortIndicator()
        requestAllSizesWhenSortedBySize()
    }

    /// Re-arranges expanded folders from their listings (not from the cache,
    /// which is already filtered) and reloads only the ones that changed.
    private func rearrangeExpandedFolders() {
        // Children cached for folders that are not expanded would go stale.
        childCache = childCache.filter { expanded[$0.key] != nil }
        guard let pane else { return }
        for (path, folder) in expanded {
            guard let old = childCache[path] else { continue }
            let listing = DirectoryStore.shared.listing(for: path)
            guard listing.isLoaded else { continue }
            let new = pane.arrange(listing.items)
            if new.count == old.count && zip(old, new).allSatisfy({ $0 === $1 }) { continue }
            childCache[path] = new
            if let renaming = renamingItem, renaming.path.hasPrefix(path + "/") { cancelRename() }
            applyDiff(old: old, new: new, parent: folder)
        }
    }

    private func collapseAllWatching() {
        for path in expanded.keys { DirectoryStore.shared.endWatching(path) }
        expanded.removeAll()
        childCache.removeAll()
    }

    private func applyDiff(old: [FileItem], new: [FileItem], parent: FileItem?) {
        let oldSet = Set(old), newSet = Set(new)
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
        let inserted = IndexSet(new.indices.filter { !oldSet.contains(new[$0]) })
        var current = old.filter { newSet.contains($0) }
        let retained = new.filter { oldSet.contains($0) }
        guard !removed.isEmpty || !inserted.isEmpty || current != retained else { return }
        let selection = selectedItems
        if let renamingItem, !newSet.contains(renamingItem) { cancelRename() }
        if removed.isEmpty && inserted.isEmpty {
            // Only the order changed: reload without animating rows across the list.
            if let parent { outlineView.reloadItem(parent, reloadChildren: true) } else { outlineView.reloadData() }
            select(selection, scroll: false)
            pane?.viewSelectionDidChange(self)
            return
        }
        outlineView.beginUpdates()
        if !removed.isEmpty { outlineView.removeItems(at: removed, inParent: parent, withAnimation: []) }
        var positions = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element, $0.offset) })
        for (destination, item) in retained.enumerated() {
            guard let source = positions[item], source != destination else { continue }
            outlineView.moveItem(at: source, inParent: parent, to: destination, inParent: parent)
            current.remove(at: source)
            current.insert(item, at: destination)
            for index in destination...source { positions[current[index]] = index }
        }
        if !inserted.isEmpty { outlineView.insertItems(at: inserted, inParent: parent, withAnimation: []) }
        outlineView.endUpdates()
        select(selection, scroll: false)
        pane?.viewSelectionDidChange(self)
    }

    @objc private func directoryDidUpdate(_ notification: Notification) {
        guard let listing = notification.object as? DirectoryStore.Listing,
              let old = childCache[listing.path],
              let folder = expanded[listing.path],
              let pane else { return }
        let new = pane.arrange(listing.items)
        childCache[listing.path] = new
        applyDiff(old: old, new: new, parent: folder)
        if let changes = notification.userInfo?["changes"] as? DirectoryStore.Changes {
            for item in changes.updated where item !== renamingItem && outlineView.row(forItem: item) >= 0 {
                outlineView.reloadItem(item, reloadChildren: false)
            }
        }
    }

    private func children(of folder: FileItem) -> [FileItem] {
        if let cached = childCache[folder.path] { return cached }
        // A slow folder opens empty; directoryDidUpdate inserts its rows when they arrive.
        let listing = DirectoryStore.shared.load(folder.path, waitingUpTo: 0)
        let arranged = pane?.arrange(listing.items) ?? listing.items
        childCache[folder.path] = arranged
        return arranged
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let folder = item as? FileItem { return children(of: folder).count }
        return items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let folder = item as? FileItem { return children(of: folder)[index] }
        return items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard !isFlat, let file = item as? FileItem else { return false }
        return file.type == .directory && file.childCount != 0
    }

    // MARK: Expansion

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileItem else { return }
        if expanded[item.path] == nil {
            expanded[item.path] = item
            DirectoryStore.shared.beginWatching(item.path)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileItem else { return }
        let prefix = item.path + "/"
        for path in Array(expanded.keys) where path == item.path || path.hasPrefix(prefix) {
            expanded.removeValue(forKey: path)
            childCache.removeValue(forKey: path)
            DirectoryStore.shared.endWatching(path)
        }
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileItem, let tableColumn,
              let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        if column == .name {
            let cell = outlineView.makeView(withIdentifier: Self.nameCellID, owner: self) as? NameCellView
                ?? { let c = NameCellView(); c.identifier = Self.nameCellID; return c }()
            cell.configure(item, iconSize: listAppearance.density.iconSize, thumbnails: listAppearance.thumbnails,
                           dimmed: pane?.isCut(item) ?? false)
            if pane?.isSearchResults == true { cell.name.toolTip = item.path }
            return cell
        }
        let identifier = Self.textCellIDs[column] ?? NSUserInterfaceItemIdentifier("TextCell." + column.rawValue)
        let cell: TextCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? TextCellView {
            cell = reused
        } else {
            cell = TextCellView()
            cell.identifier = identifier
            cell.label.alignment = column.alignment
            // Like Finder, long kinds keep both ends ("Icon Comp… Icon").
            cell.label.lineBreakMode = column == .kind ? .byTruncatingMiddle : .byTruncatingTail
        }
        cell.configure(text: text(for: item, column: column), column: column)
        return cell
    }

    private var formattedValues: [String: String] = [:]

    private func cachedText(_ key: String, make: () -> String) -> String {
        if let value = formattedValues[key] { return value }
        if formattedValues.count >= 12000 { formattedValues.removeAll(keepingCapacity: true) }
        let value = make()
        formattedValues[key] = value
        return value
    }

    private func text(for item: FileItem, column: ListColumn) -> String {
        let length = dateLengths[column.rawValue] ?? .short
        switch column {
        case .name: return item.displayName
        case .modified: return cachedText("d/\(item.modified)/\(length.rawValue)") { Formatters.listDate(item.modified, length: length) }
        case .created: return cachedText("d/\(item.created)/\(length.rawValue)") { Formatters.listDate(item.created, length: length) }
        case .added: return item.added > 0 ? cachedText("d/\(item.added)/\(length.rawValue)") { Formatters.listDate(item.added, length: length) } : "--"
        case .kind: return FileKinds.kind(for: item)
        case .size:
            if (item.type == .directory || item.type == .package)
                && (item.displaySize < 0 || FolderSizer.shared.needsFirstWalk(item.path)) {
                requestSize(for: item)
            }
            // A cached size is applied right away by the request above.
            let size = item.displaySize
            return size >= 0 ? cachedText("s/\(size)") { Formatters.size(size) } : "--"
        }
    }

    /// Folders with a size request from this list still pending.
    private var sizeRequests = Set<String>()

    /// Sorted by size, every folder needs its size (not only the rows on
    /// screen), or folders with unknown sizes keep sorting into view and
    /// moving away again as their sizes arrive.
    private func requestAllSizesWhenSortedBySize() {
        guard listAppearance.folderSizes, pane?.arrangeOptions.sortKey == .size else { return }
        // Bottom up: the newest request walks first, so the top rows come first.
        for item in items.reversed() where (item.type == .directory || item.type == .package)
            && (item.displaySize < 0 || FolderSizer.shared.needsFirstWalk(item.path)) {
            requestSize(for: item)
        }
    }

    /// Starts (or joins) a size calculation. `refreshing` re-requests a size the
    /// item already shows because its contents changed.
    private func requestSize(for item: FileItem, refreshing: Bool = false) {
        guard listAppearance.folderSizes, !isFlat || item.type == .package else { return }
        let path = item.path
        if let cached = FolderSizer.shared.cached(path) {
            let changed = cached.bytes != item.computedFolderSize
            item.computedFolderSize = cached.bytes
            if refreshing && changed { reloadSizeCell(for: item) }
            return
        }
        // Show the size from an earlier launch until the walk confirms it.
        if item.computedFolderSize < 0, let remembered = FolderSizer.shared.rememberedSize(path) {
            item.computedFolderSize = remembered
        }
        // Cells are configured over and over: one request per folder, unless the
        // walk it joined has gone out of date.
        guard !sizeRequests.contains(path) || !FolderSizer.shared.isComputing(path) else { return }
        sizeRequests.insert(path)
        FolderSizer.shared.size(of: path) { [weak self, weak item] result in
            guard let self else { return }
            self.sizeRequests.remove(path)
            // A remembered size that was right needs no redraw and no re-sort.
            guard let item, item.computedFolderSize != result.bytes else { return }
            item.computedFolderSize = result.bytes
            self.reloadSizeCell(for: item)
        }
    }

    // Sizes of shown folders whose contents changed are recalculated at most
    // twice a second, so a long copy updates the list without flooding it.
    private var pendingSizeRefresh = Set<String>()
    private var sizeRefreshScheduled = false

    @objc private func folderContentsDidChange(_ notification: Notification) {
        guard listAppearance.folderSizes, isViewLoaded,
              let paths = notification.userInfo?["paths"] as? Set<String> else { return }
        pendingSizeRefresh.formUnion(paths)
        guard !sizeRefreshScheduled else { return }
        sizeRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPendingSizes()
        }
    }

    private func refreshPendingSizes() {
        sizeRefreshScheduled = false
        let paths = pendingSizeRefresh
        pendingSizeRefresh.removeAll()
        for path in paths {
            guard let item = shownItem(atPath: path), item.type == .directory || item.type == .package else { continue }
            requestSize(for: item, refreshing: true)
        }
    }

    /// The item for `path` if it is listed at the top level or in an expanded folder.
    private func shownItem(atPath path: String) -> FileItem? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if isFlat { return items.first { $0.path == path } }
        if parent == directoryPath { return items.first { $0.name == name } }
        return childCache[parent]?.first { $0.name == name }
    }

    private var pendingSizeCells = Set<FileItem>()
    private var sizeCellsScheduled = false

    private func reloadSizeCell(for item: FileItem) {
        pendingSizeCells.insert(item)
        guard !sizeCellsScheduled else { return }
        sizeCellsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeCellsScheduled = false
            let pending = self.pendingSizeCells
            self.pendingSizeCells.removeAll(keepingCapacity: true)
            var rows = IndexSet()
            for item in pending {
                let row = self.outlineView.row(forItem: item)
                if row >= 0 { rows.insert(row) }
            }
            guard !rows.isEmpty else { return }
            if !rows.intersection(self.outlineView.selectedRowIndexes).isEmpty { self.pane?.updateBottomBar() }
            let column = self.outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.size.rawValue))
            if column >= 0 {
                self.outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: column))
            }
            if self.pane?.arrangeOptions.sortKey == .size { self.pane?.scheduleResort() }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == ListColumn.name.rawValue else { return nil }
        return (item as? FileItem)?.displayName
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        notifySelectionChanged()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSort, let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key, let sortKey = SortKey(rawValue: key) else { return }
        pane?.setSort(sortKey, ascending: descriptor.ascending)
    }

    /// Like Finder, Name stays the first column.
    func outlineView(_ outlineView: NSOutlineView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex > 0 && newColumnIndex > 0
    }

    // MARK: Selection API

    override var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
    }

    override func select(_ items: [FileItem], scroll: Bool) {
        var rows = IndexSet()
        for item in items {
            let row = outlineView.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { outlineView.scrollRowToVisible(first) }
    }

    override func selectAllItems() { outlineView.selectAll(nil) }
    override func deselectAllItems() { outlineView.deselectAll(nil) }

    override func focus() {
        view.window?.makeFirstResponder(outlineView)
    }

    override func refresh(_ items: [FileItem]) {
        // The row being renamed keeps its field (and the typed name).
        for item in items where item !== renamingItem && outlineView.row(forItem: item) >= 0 {
            outlineView.reloadItem(item, reloadChildren: false)
        }
    }

    override func appearanceSettingsDidChange() {
        // Called for every preference: only the list's own settings reload it.
        let current = Self.currentAppearance()
        guard current != listAppearance else { return }
        let old = listAppearance
        listAppearance = current
        if old.density != current.density {
            let height = current.density.listRowHeight
            if outlineView.rowHeight != height { outlineView.rowHeight = height }

        }
        // Rebuild only when the configured columns change.
        let shown = outlineView.tableColumns.compactMap { ListColumn(rawValue: $0.identifier.rawValue) }.filter { $0 != .name }
        let wanted = Prefs.listColumns.compactMap { ListColumn(rawValue: $0) }
        if Set(shown) != Set(wanted) {
            buildColumns()
        }
        // Density, previews, folder sizes or columns changed: every row shows them.
        if renamingItem != nil { cancelRename() }
        let selection = selectedItems
        outlineView.reloadData()
        select(selection, scroll: false)
    }

    override func iconScreenRect(for item: FileItem) -> NSRect? {
        let row = outlineView.row(forItem: item)
        guard row >= 0, let window = view.window,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return nil }
        let rect = cell.icon.convert(cell.icon.bounds, to: nil)
        return window.convertToScreen(rect)
    }

    override func iconImage(for item: FileItem) -> NSImage? {
        let row = outlineView.row(forItem: item)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return nil }
        return cell.icon.image
    }

    // MARK: Opening

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else { return }
        let inNewTab = NSEvent.modifierFlags.contains(.command)
        pane?.open([item], inNewTab: inNewTab)
    }

    func handleKeyDown(_ event: NSEvent, typeSelecting: Bool) -> Bool {
        pane?.handleKeyDown(event, typeSelecting: typeSelecting) ?? false
    }

    // MARK: Rename

    override func beginRename(_ item: FileItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.name.rawValue))
        guard column >= 0,
              let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView else { return }
        renamingItem = item
        cell.name.stringValue = item.name   // the full name while editing, ".app" included
        cell.beginEditing(delegate: self)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let item = renamingItem else { return }
        renamingItem = nil
        let newName = field.stringValue
        (field.superview as? NameCellView)?.endEditing()
        view.window?.makeFirstResponder(outlineView)
        if newName == item.name || pane?.commitRename(item, to: newName) != true {
            field.stringValue = item.displayName
        }
    }

    /// The rename field grows with the name while typing, like Finder's.
    func controlTextDidChange(_ obj: Notification) {
        (obj.object as? NSTextField)?.invalidateIntrinsicContentSize()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), renamingItem != nil {
            cancelRename(field: control as? NSTextField)
            return true
        }
        return false
    }

    /// Ends a rename without applying it: Escape, or a reload that would
    /// replace the field (which ends editing without telling the delegate).
    private func cancelRename(field: NSTextField? = nil) {
        guard let item = renamingItem else { return }
        renamingItem = nil
        var cell = field?.superview as? NameCellView
        if cell == nil {
            let row = outlineView.row(forItem: item)
            let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.name.rawValue))
            if row >= 0, column >= 0 {
                cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: false) as? NameCellView
            }
        }
        if let cell {
            cell.name.abortEditing()
            cell.name.stringValue = item.displayName
            cell.endEditing()
        }
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        var targets: [FileItem] = []
        if row >= 0, let item = outlineView.item(atRow: row) as? FileItem {
            if outlineView.selectedRowIndexes.contains(row) {
                targets = selectedItems
            } else {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                targets = [item]
            }
        }
        pane?.populateContextMenu(menu, for: targets)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileItem)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        self.draggedItems = draggedItems.compactMap { $0 as? FileItem }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete {
            pane?.trash(draggedItems.map { $0.url })
        }
        draggedItems = []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let pane else { return [] }
        var target = item as? FileItem
        if let candidate = target, !candidate.isNavigable {
            target = outlineView.parent(forItem: candidate) as? FileItem
        }
        if pane.isSearchResults && target == nil { return [] }
        let destination = target?.path ?? directoryPath
        let operation = pane.dragOperation(for: info, destination: destination)
        if operation.isEmpty { return [] }
        // Like Finder, a drop into the folder being shown draws no ring around
        // the whole list; folder rows keep the native drop highlight.
        let feedback: NSTableView.DraggingDestinationFeedbackStyle = target == nil ? .none : .regular
        if outlineView.draggingDestinationFeedbackStyle != feedback {
            outlineView.draggingDestinationFeedbackStyle = feedback
        }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        springLoad(target)
        return operation
    }

    /// Spring-loaded folders: hovering a drag over a folder expands it.
    private var springTarget: FileItem?
    private var springWork: DispatchWorkItem?

    private func springLoad(_ target: FileItem?) {
        guard target !== springTarget else { return }
        springTarget = target
        springWork?.cancel()
        guard let target, target.type == .directory, !outlineView.isItemExpanded(target) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.springTarget === target else { return }
            NSAnimationContext.runAnimationGroup { _ in
                self.outlineView.animator().expandItem(target)
            }
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springWork?.cancel()
        springTarget = nil
        if outlineView.draggingDestinationFeedbackStyle != .regular {
            outlineView.draggingDestinationFeedbackStyle = .regular
        }
        let destination = (item as? FileItem)?.path ?? directoryPath
        return pane?.performDrop(info, destination: destination) ?? false
    }
}

/// The list never scrolls sideways: its columns are fitted to the width, and
/// a table briefly wider than the pane (mid-resize) would otherwise shift
/// left and cut off the inset rows' rounded edges and leading margin.
private final class VerticalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}
