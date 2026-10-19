import AppKit
import Quartz

extension NSToolbarItem.Identifier {
    static let diskiNavigation = NSToolbarItem.Identifier("app.diski.navigation")
    static let diskiAirDrop = NSToolbarItem.Identifier("app.diski.airdrop")
    static let diskiViewMode = NSToolbarItem.Identifier("app.diski.viewmode")
    static let diskiGroup = NSToolbarItem.Identifier("app.diski.group")
    static let diskiShare = NSToolbarItem.Identifier("app.diski.share")
    static let diskiTags = NSToolbarItem.Identifier("app.diski.tags")
    static let diskiAction = NSToolbarItem.Identifier("app.diski.action")
    static let diskiSearch = NSToolbarItem.Identifier("app.diski.search")
    static let diskiOperations = NSToolbarItem.Identifier("app.diski.operations")
    static let diskiDualPane = NSToolbarItem.Identifier("app.diski.dualpane")
    static let diskiNewFolder = NSToolbarItem.Identifier("app.diski.newfolder")
    static let diskiTrash = NSToolbarItem.Identifier("app.diski.trash")
    static let diskiTerminal = NSToolbarItem.Identifier("app.diski.terminal")
    static let diskiGetInfo = NSToolbarItem.Identifier("app.diski.getinfo")
    static let diskiPreviewPane = NSToolbarItem.Identifier("app.diski.preview")
}

/// Holds one or two panes side by side.
final class PaneContainerViewController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    private(set) var panes: [PaneViewController] = []
    /// The first pane's share of the width. Kept while the window resizes;
    /// changed only by dragging the divider.
    private var firstShare: CGFloat = 0.5
    private var sharedWidth: CGFloat = 0
    private var isApplyingShare = false

    override func loadView() {
        let root = NSView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        let fullHeight = splitView.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fullHeight,
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        topToEdge = fullHeight
        topBelowToolbar = splitView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        view = root
        updateTopConstraint()
    }

    /// One pane scrolls under the toolbar; two start below it, so the
    /// divider between them does not cut through the toolbar.
    private var topToEdge: NSLayoutConstraint?
    private var topBelowToolbar: NSLayoutConstraint?

    private func updateTopConstraint() {
        guard let topToEdge, let topBelowToolbar else { return }
        let dual = panes.count > 1
        NSLayoutConstraint.deactivate(dual ? [topToEdge] : [topBelowToolbar])
        NSLayoutConstraint.activate(dual ? [topBelowToolbar] : [topToEdge])
    }

    func add(_ pane: PaneViewController) {
        addChild(pane)
        panes.append(pane)
        updateTopConstraint()
        splitView.addArrangedSubview(pane.view)
        splitView.adjustSubviews()
        equalize()
        // Again once the new pane has been laid out.
        DispatchQueue.main.async { [weak self] in self?.applyShare() }
    }

    func remove(_ pane: PaneViewController) {
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        panes.removeAll { $0 === pane }
        updateTopConstraint()
        // The remaining pane fills the container now, not at the next resize.
        splitView.adjustSubviews()
        sharedWidth = 0
    }

    func equalize() {
        firstShare = 0.5
        applyShare()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // A pane is often added before the window has its final size: keep the
        // share whenever the width changes instead of splitting once.
        let width = splitView.bounds.width
        guard abs(width - sharedWidth) > 0.5 else { return }
        applyShare()
    }

    private func applyShare() {
        let width = splitView.bounds.width
        guard panes.count == 2, width > 0 else { return }
        sharedWidth = width
        isApplyingShare = true
        let usable = width - splitView.dividerThickness
        splitView.setPosition((usable * firstShare).rounded(), ofDividerAt: 0)
        isApplyingShare = false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only a divider dragged by the user carries its index.
        guard !isApplyingShare, panes.count == 2, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let usable = splitView.bounds.width - splitView.dividerThickness
        guard usable > 0 else { return }
        firstShare = min(0.85, max(0.15, panes[0].view.frame.width / usable))
    }
}

private final class InspectorContainerViewController: NSViewController {
    override func loadView() { view = NSView() }

    func install(_ inspector: InspectorViewController) {
        guard inspector.parent !== self else { return }
        addChild(inspector)
        let content = inspector.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// A Diski browser window (or tab): sidebar, one or two panes, inspector,
/// and the Liquid Glass toolbar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                     NSSearchFieldDelegate, NSSharingServicePickerToolbarItemDelegate,
                                     NSMenuItemValidation, NSToolbarItemValidation, NSMenuDelegate, PaneViewControllerDelegate,
                                     SidebarViewControllerDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let splitController = NSSplitViewController()
    let sidebar = SidebarViewController()
    let paneContainer = PaneContainerViewController()
    private(set) lazy var inspector = InspectorViewController()
    private let inspectorContainer = InspectorContainerViewController()
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private(set) var activePane: PaneViewController!
    private var firstResponderObservation: NSKeyValueObservation?
    private var inspectorCollapseObservation: NSKeyValueObservation?
    /// Column view shows the selected file in its own preview column, like
    /// Finder's, so the preview pane steps aside while every pane is in it.
    private var previewPaneHiddenForColumns = false
    /// Whether the active pane's selection was empty at the last toolbar validation.
    private var selectionWasEmpty = true

    private weak var navigationGroup: NSToolbarItemGroup?
    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private weak var viewModeGroup: NSToolbarItemGroup?
    private weak var previewPaneGroup: NSToolbarItemGroup?
    private weak var searchItem: NSSearchToolbarItem?
    private weak var operationsItem: NSToolbarItem?
    private lazy var operationsView = OperationsToolbarView()

    /// The toolbar's progress item, when this window shows it (for the operations popover).
    var operationsAnchor: NSView? {
        guard let window, window.isVisible, operationsItem?.isHidden == false,
              operationsView.window === window else { return nil }
        return operationsView
    }
    private var previewItems: [URL] = []

    var panes: [PaneViewController] { paneContainer.panes }

    init(path: String, viewMode: ViewMode? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 620, height: 380)
        window.toolbarStyle = .unified
        // Finder draws no line under its toolbar: the list header and the
        // panes themselves separate the toolbar from the content.
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .visible
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "app.diski.browser"
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        sidebar.delegate = self
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 172
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        // Only the user shows and hides the sidebar: AppKit would hide it when the
        // window gets narrow and bring it back by itself when it widens again.
        sidebarItem.canCollapseFromWindowResize = false
        // Finder's sidebar has no line under the title bar.
        sidebarItem.titlebarSeparatorStyle = .none
        let contentItem = NSSplitViewItem(viewController: paneContainer)
        contentItem.minimumThickness = 360
        contentItem.titlebarSeparatorStyle = .none
        // The same full-height pane as the sidebar, on the trailing edge, so the
        // toolbar area above it is one surface with it (like Finder's preview).
        inspectorItem = NSSplitViewItem(sidebarWithViewController: inspectorContainer)
        inspectorItem.minimumThickness = 200
        inspectorItem.maximumThickness = 380
        inspectorItem.titlebarSeparatorStyle = .none
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.isCollapsed = !Prefs.showInspector
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.addSplitViewItem(inspectorItem)
        splitController.splitView.autosaveName = "DiskiMainSplit"
        window.contentViewController = splitController

        let pane = PaneViewController(path: path, viewMode: viewMode ?? Prefs.defaultViewMode)
        pane.delegate = self
        paneContainer.add(pane)
        activePane = pane
        pane.isActive = true
        updatePreviewPaneForColumnView()
        // The split view's autosave also stores the preview pane's collapsed
        // state, including a collapse that was only for column view. The
        // setting decides; once now and once after the restore at first layout.
        applyPreviewPaneSetting()
        DispatchQueue.main.async { [weak self] in self?.applyPreviewPaneSetting() }

        let toolbar = NSToolbar(identifier: "DiskiBrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1240, height: 780))
        window.setFrameAutosaveName("DiskiBrowserWindow")
        if window.frame.origin == .zero { window.center() }

        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            self?.firstResponderChanged()
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(operationsChanged), name: FileOperationManager.didChange, object: nil)
        center.addObserver(self, selector: #selector(operationFinished(_:)), name: FileOperationManager.didFinish, object: nil)
        center.addObserver(self, selector: #selector(clearSearchField(_:)), name: .diskiClearSearchField, object: nil)
        center.addObserver(self, selector: #selector(prefsChanged(_:)), name: Prefs.didChange, object: nil)
        updateWindowTitle()
        updateToolbarState()
        updateInspector()
        // Revealing the preview pane by dragging its edge refreshes it too.
        inspectorCollapseObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            self?.updatePreviewPaneToolbarState()
            if !item.isCollapsed { self?.updateInspector(force: true) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        activePane.content.focus()
    }

    // MARK: - Panes

    private func firstResponderChanged() {
        guard let responder = window?.firstResponder as? NSView else { return }
        for pane in panes where responder.isDescendant(of: pane.view) {
            if pane !== activePane { setActivePane(pane) }
            return
        }
    }

    private func setActivePane(_ pane: PaneViewController) {
        activePane?.isActive = false
        activePane = pane
        pane.isActive = true
        updateWindowTitle()
        updateToolbarState()
        updateInspector()
        sidebar.highlight(path: sidebarPath(for: pane))
        searchItem?.searchField.stringValue = pane.searchText
        ViewOptionsPanel.shared.paneDidChange(pane)
        revalidateSelectionItems(force: true)
    }

    /// Share and the other selection-dependent items only revalidate on window
    /// updates; a selection made without an event would leave them stale.
    private func revalidateSelectionItems(force: Bool = false) {
        let isEmpty = activePane.selectedItems.isEmpty
        guard force || isEmpty != selectionWasEmpty else { return }
        selectionWasEmpty = isEmpty
        window?.toolbar?.validateVisibleItems()
    }

    var isDualPane: Bool { panes.count > 1 }

    @objc func toggleDualPane(_ sender: Any?) {
        if panes.count > 1 {
            let closing = panes.first { $0 !== activePane } ?? panes[1]
            paneContainer.remove(closing)
            setActivePane(panes[0])
        } else {
            let pane = PaneViewController(path: activePane.displayedPath, viewMode: activePane.viewMode)
            pane.delegate = self
            paneContainer.add(pane)
            pane.content.focus()
            setActivePane(pane)
        }
        for pane in panes { pane.showsActiveIndicator = panes.count > 1 }
        activePane.isActive = true
        updatePreviewPaneForColumnView()
    }

    /// F5 / F6 in dual-pane mode: copy or move the selection to the other pane.
    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(move: true) }

    private func transferToOtherPane(move: Bool) {
        guard panes.count > 1, let other = panes.first(where: { $0 !== activePane }) else { NSSound.beep(); return }
        let urls = activePane.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        let destination = URL(fileURLWithPath: other.content.targetDirectory, isDirectory: true)
        if move {
            FileOperationManager.shared.move(urls, to: destination)
        } else {
            FileOperationManager.shared.copy(urls, to: destination)
        }
    }

    // MARK: - PaneViewControllerDelegate

    func paneDidChangeLocation(_ pane: PaneViewController) {
        // Search results leave column view for the list without a mode callback.
        updatePreviewPaneForColumnView()
        guard pane === activePane else { return }
        updateWindowTitle()
        updateToolbarState()
        updateInspector()
        sidebar.highlight(path: sidebarPath(for: pane))
        ViewOptionsPanel.shared.paneDidChange(pane)
        // Navigation can clear the selection without a selection callback.
        revalidateSelectionItems()
    }

    func paneDidChangeSelection(_ pane: PaneViewController) {
        guard pane === activePane else { return }
        updateInspector()
        revalidateSelectionItems()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
           panel.dataSource === self {
            previewItems = pane.selectedURLs
            panel.reloadData()
        }
    }

    /// Every view-mode change is followed by paneDidChangeLocation, which
    /// updates the toolbar and the preview pane.
    func paneDidChangeViewMode(_ pane: PaneViewController) {
        updatePreviewPaneForColumnView()
        guard pane === activePane else { return }
        ViewOptionsPanel.shared.paneDidChange(pane)
    }

    /// Hides the preview pane when every pane enters column view and brings
    /// it back (if it is on) when one leaves. Only acts on that change, and
    /// never on a focus switch, so the panes don't jump. No animation: it
    /// lands together with the new view.
    private func updatePreviewPaneForColumnView() {
        let hide = panes.allSatisfy { $0.viewMode == .columns }
        guard hide != previewPaneHiddenForColumns else { return }
        previewPaneHiddenForColumns = hide
        let collapse = hide || !Prefs.showInspector
        if inspectorItem.isCollapsed != collapse { inspectorItem.isCollapsed = collapse }
        updatePreviewPaneToolbarState()
    }

    private func applyPreviewPaneSetting() {
        let collapse = previewPaneHiddenForColumns || !Prefs.showInspector
        if inspectorItem.isCollapsed != collapse { inspectorItem.isCollapsed = collapse }
        updatePreviewPaneToolbarState()
    }

    func paneRequestsFocusSwitch(_ pane: PaneViewController) -> Bool {
        guard panes.count > 1, let other = panes.first(where: { $0 !== pane }) else { return false }
        other.content.focus()
        setActivePane(other)
        return true
    }

    func pane(_ pane: PaneViewController, openInNewTab path: String) {
        (NSApp.delegate as? AppDelegate)?.openTab(path: path, from: self)
    }

    func paneRequestsQuickLook(_ pane: PaneViewController) {
        toggleQuickLook()
    }

    func paneRequestsQuickLookDismissal(_ pane: PaneViewController) -> Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return false }
        panel.orderOut(nil)
        return true
    }

    func paneRequestsInspector(_ pane: PaneViewController) {
        updateInspector(force: true)
        if inspectorItem.isCollapsed {
            inspectorItem.animator().isCollapsed = false
            Prefs.showInspector = true
        }
        updatePreviewPaneToolbarState()
    }

    // MARK: - Sidebar

    func sidebarDidSelect(path: String) {
        activePane.navigate(to: path)
        activePane.content.focus()
    }

    func sidebarDidSelectTag(_ tag: String) {
        activePane.showTag(tag)
    }

    func sidebarDidSelectRecents() {
        activePane.showRecents()
    }

    private func sidebarPath(for pane: PaneViewController) -> String? {
        if pane.isShowingRecents { return SidebarViewController.recentsMarker }
        return pane.isSearchResults ? nil : pane.displayedPath
    }

    func sidebarRequestsDrop(_ info: NSDraggingInfo, destination: String) -> Bool {
        activePane.performDrop(info, destination: destination)
    }

    func sidebarDragOperation(_ info: NSDraggingInfo, destination: String) -> NSDragOperation {
        activePane.dragOperation(for: info, destination: destination)
    }

    // MARK: - Window title, toolbar & inspector state

    private func updateWindowTitle() {
        guard let window else { return }
        let title = activePane.displayTitle
        if window.title != title { window.title = title }
        let name = activePane.isSearchResults ? title : activePane.displayFolderName
        if window.tab.title != name { window.tab.title = name }
    }

    /// Writes only what changed: this runs on every navigation.
    private func updateToolbarState() {
        let back = activePane.canGoBack, forward = activePane.canGoForward
        if backItem?.isEnabled != back { backItem?.isEnabled = back }
        if forwardItem?.isEnabled != forward { forwardItem?.isEnabled = forward }
        let mode = activePane.viewMode.rawValue
        if let group = viewModeGroup, group.selectedIndex != mode { group.selectedIndex = mode }
        updatePreviewPaneToolbarState()
    }

    private func updatePreviewPaneToolbarState() {
        previewPaneGroup?.setSelected(!inspectorItem.isCollapsed, at: 0)
    }

    /// Skipped while the preview pane is collapsed; every reveal path forces it.
    private func updateInspector(force: Bool = false) {
        guard force || !inspectorItem.isCollapsed else { return }
        inspectorContainer.install(inspector)
        inspector.compact = activePane.viewMode == .gallery
        let selection = activePane.selectedItems
        if selection.isEmpty {
            inspector.show(items: [], folderPath: activePane.isSearchResults ? nil : activePane.displayedPath)
        } else {
            inspector.show(items: selection, folderPath: nil)
        }
    }

    @objc private func prefsChanged(_ notification: Notification) {
        // Only the full-path setting changes the window title.
        let key = notification.userInfo?[Prefs.changedKey] as? String
        guard key == nil || key == "showFullPathInTitle" else { return }
        updateWindowTitle()
    }

    // MARK: - Actions

    @objc func goBack(_ sender: Any?) { activePane.goBack(sender); activePane.content.focus() }
    @objc func goForward(_ sender: Any?) { activePane.goForward(sender); activePane.content.focus() }

    /// The Back/Forward segmented group: the clicked segment is its selectedIndex.
    @objc func navigationClicked(_ sender: Any?) {
        // From the toolbar's overflow menu the sender is the part (or its menu
        // item), not the group, and the group's momentary selection is stale.
        if let item = sender as? NSToolbarItem, !(item is NSToolbarItemGroup) {
            if item === backItem { goBack(sender) } else if item === forwardItem { goForward(sender) }
            return
        }
        if let menuItem = sender as? NSMenuItem {
            if menuItem.title == "Back" { goBack(sender) } else if menuItem.title == "Forward" { goForward(sender) }
            return
        }
        let index = (sender as? NSToolbarItemGroup)?.selectedIndex ?? navigationGroup?.selectedIndex ?? -1
        if index == 0 { goBack(sender) } else if index == 1 { goForward(sender) }
    }

    @objc func toolbarViewModeChanged(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup, let mode = ViewMode(rawValue: group.selectedIndex) else { return }
        activePane.setViewMode(mode)
    }

    /// Not `toggleInspector(_:)`: NSSplitViewController implements that and sits
    /// earlier in the responder chain, but the preview pane is a sidebar item.
    @objc func togglePreviewPane(_ sender: Any?) {
        let collapse = !inspectorItem.isCollapsed
        // Fill the pane before it slides in, not halfway through the animation.
        if !collapse { updateInspector(force: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            inspectorItem.animator().isCollapsed = collapse
        }
        // In column view the pane is only shown for now; the setting stays as it is.
        if !previewPaneHiddenForColumns { Prefs.showInspector = !collapse }
        updatePreviewPaneToolbarState()
    }

    @objc func togglePathBar(_ sender: Any?) {
        Prefs.showPathBar.toggle()
    }

    @objc func toggleStatusInfo(_ sender: Any?) {
        Prefs.showStatusInfo.toggle()
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let searchItem else { return }
        searchItem.beginSearchInteraction()
    }

    @objc func airDrop(_ sender: Any?) {
        let urls = activePane.selectedURLs
        if !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            AppDelegate.openAirDropWindow()
        }
    }

    @objc func showGoToFolder(_ sender: Any?) {
        guard let window else { return }
        GoToFolderController.present(on: window, startingAt: activePane.displayedPath) { [weak self] path in
            self?.activePane.navigate(to: path)
            self?.activePane.content.focus()
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openTab(path: activePane.displayedPath, from: self)
    }

    @objc func showViewOptions(_ sender: Any?) {
        ViewOptionsPanel.shared.toggle(for: activePane)
    }

    @objc func showOperations(_ sender: Any?) {
        ProgressWindowController.shared.present(anchor: operationsAnchor)
    }

    // MARK: - Search field

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchItem?.searchField else { return }
        activePane.setSearchText(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { activePane.setSearchText("") }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchItem?.searchField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)) {
            // Return / ↓ jumps from the search field into the results.
            activePane.content.focus()
            if activePane.selectedItems.isEmpty, let first = activePane.items.first {
                activePane.content.select([first], scroll: true)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchItem?.searchField.stringValue = ""
            activePane.setSearchText("")
            activePane.content.focus()
            return true
        }
        return false
    }

    @objc private func clearSearchField(_ notification: Notification) {
        guard let pane = notification.object as? PaneViewController, pane === activePane else { return }
        searchItem?.searchField.stringValue = ""
    }

    // MARK: - Operations feedback

    @objc private func operationsChanged() {
        guard operationsItem != nil else { return }
        operationsView.update(with: FileOperationManager.shared.operations)
        if let item = operationsItem {
            let shouldHide = FileOperationManager.shared.operations.isEmpty
            if item.isHidden != shouldHide { item.isHidden = shouldHide }
        }
    }

    /// Operations too quick for the progress window get a short native
    /// confirmation under the toolbar's progress item instead.
    @objc private func operationFinished(_ notification: Notification) {
        guard window?.isKeyWindow == true || NSApp.keyWindow == nil,
              Prefs.showOperationToasts,
              let operation = notification.object as? FileOperation, operation.state == .finished,
              !ProgressWindowController.shared.didShow(operation) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible,
                  self.operationsView.window === window, self.operationsItem?.isHidden == false else { return }
            OperationFinishedPopover.show(operation, relativeTo: self.operationsView)
        }
    }

    // MARK: - Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            previewItems = activePane.selectedURLs
            guard !previewItems.isEmpty else { NSSound.beep(); return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewItems = activePane.selectedURLs
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        index < previewItems.count ? previewItems[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let responder = window?.firstResponder else { return false }
        // Arrow keys move the selection in the browser while previewing.
        if [123, 124, 125, 126].contains(event.keyCode) {
            responder.keyDown(with: event)
            return true
        }
        return false
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let file = previewFile(for: item) else { return .zero }
        return activePane.content.iconScreenRect(for: file) ?? .zero
    }

    /// The image the panel zooms from and back into: the icon or thumbnail the
    /// row shows. Without it Quick Look morphs a blank (black) snapshot.
    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let file = previewFile(for: item) else { return nil }
        return activePane.content.iconImage(for: file)
            ?? ThumbnailCache.shared.cached(for: file, points: 32, scale: window?.backingScaleFactor ?? 2, iconMode: true)
            ?? IconCache.shared.cachedItemIcon(path: file.path)
            ?? IconCache.shared.immediateIcon(for: file)
    }

    private func previewFile(for item: QLPreviewItem?) -> FileItem? {
        guard let url = item?.previewItemURL ?? nil else { return nil }
        return activePane.selectedItems.first(where: { $0.url == url }) ?? activePane.items.first(where: { $0.url == url })
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return activePane.canGoBack
        case #selector(goForward(_:)): return activePane.canGoForward
        case #selector(togglePreviewPane(_:)):
            menuItem.title = inspectorItem.isCollapsed ? "Show Preview" : "Hide Preview"
            return true
        case #selector(togglePathBar(_:)):
            menuItem.title = Prefs.showPathBar ? "Hide Path Bar" : "Show Path Bar"
            return true
        case #selector(toggleStatusInfo(_:)):
            menuItem.title = Prefs.showStatusInfo ? "Hide Item Info" : "Show Item Info"
            return true
        case #selector(showViewOptions(_:)):
            menuItem.title = ViewOptionsPanel.shared.window?.isVisible == true ? "Hide View Options" : "Show View Options"
            return true
        case #selector(toggleDualPane(_:)):
            menuItem.title = isDualPane ? "Close Second Pane" : "Open Second Pane"
            return true
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return isDualPane && !activePane.selectedItems.isEmpty
        default:
            return true
        }
    }

    /// Items targeting the window controller would otherwise be enabled on every
    /// window update simply because it responds to their action.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let pane = activePane else { return false }
        if item === backItem || item.action == #selector(goBack(_:)) { return pane.canGoBack }
        if item === forwardItem || item.action == #selector(goForward(_:)) { return pane.canGoForward }
        if item.action == #selector(togglePreviewPane(_:)) {
            updatePreviewPaneToolbarState()
            return true
        }
        return true
    }

    /// Unhandled actions (e.g. while the sidebar has focus) go to the active pane.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let pane = activePane, pane.responds(to: action) { return pane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: - NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        FileOperationManager.shared.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self {
            panel.orderOut(nil)
        }
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebar.highlight(path: sidebarPath(for: activePane))
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .diskiNavigation, .flexibleSpace, .diskiOperations, .diskiAirDrop,
         .diskiViewMode, .diskiGroup, .diskiShare, .diskiTags, .diskiAction, .diskiPreviewPane, .diskiSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .diskiNavigation, .diskiOperations, .diskiAirDrop, .diskiViewMode,
         .diskiGroup, .diskiShare, .diskiTags, .diskiAction, .diskiSearch, .diskiDualPane, .diskiNewFolder,
         .diskiTrash, .diskiTerminal, .diskiGetInfo, .diskiPreviewPane, .flexibleSpace, .space]
    }

    private static var symbolImages: [String: NSImage] = [:]

    private func symbol(_ names: String..., label: String) -> NSImage? {
        for name in names {
            let key = name + ":" + label
            if let image = Self.symbolImages[key] { return image }
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: label) {
                Self.symbolImages[key] = image
                return image
            }
        }
        return nil
    }

    private func button(_ identifier: NSToolbarItem.Identifier, label: String, symbol image: NSImage?,
                        action: Selector, target: AnyObject? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = image
        item.action = action
        item.target = target
        item.isBordered = true
        return item
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .diskiNavigation:
            // Finder's native segmented capsule (with the centre divider), not two
            // separate bordered buttons.
            let images = [symbol("chevron.left", label: "Back"), symbol("chevron.right", label: "Forward")].compactMap { $0 }
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .momentary,
                                           labels: ["Back", "Forward"], target: self, action: #selector(navigationClicked(_:)))
            group.label = "Back/Forward"
            group.paletteLabel = "Back/Forward"
            group.isNavigational = true
            group.controlRepresentation = .expanded
            // The segments' state comes from updateToolbarState() alone: a
            // validation pass on the group must not overwrite it.
            group.autovalidates = false
            let parts = group.subitems
            if parts.count == 2 {
                parts[0].toolTip = "Back"
                parts[1].toolTip = "Forward"
                parts.forEach { $0.autovalidates = false }
                parts[0].isEnabled = activePane?.canGoBack ?? false
                parts[1].isEnabled = activePane?.canGoForward ?? false
                // The customization palette gets its own copy; keep the live one.
                if flag {
                    backItem = parts[0]
                    forwardItem = parts[1]
                }
            }
            if flag { navigationGroup = group }
            return group

        case .diskiAirDrop:
            return button(itemIdentifier, label: "AirDrop", symbol: symbol("airdrop", "dot.radiowaves.left.and.right", label: "AirDrop"),
                          action: #selector(airDrop(_:)), target: self)

        case .diskiViewMode:
            let images = ViewMode.allCases.compactMap { symbol($0.symbol, label: $0.title) }
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                                           labels: ViewMode.allCases.map { $0.title }, target: self,
                                           action: #selector(toolbarViewModeChanged(_:)))
            group.label = "View"
            group.paletteLabel = "View"
            group.controlRepresentation = .expanded
            group.selectedIndex = activePane?.viewMode.rawValue ?? 1
            if flag { viewModeGroup = group }
            return group

        case .diskiGroup:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sort"
            item.paletteLabel = "Sort & View Options"
            item.toolTip = "Sort and view options"
            item.image = symbol("square.grid.3x1.below.line.grid.1x2", "line.3.horizontal.decrease", label: "Sort")
            item.showsIndicator = true
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = NSUserInterfaceItemIdentifier("sortMenu")
            item.menu = menu
            return item

        case .diskiShare:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Share"
            item.paletteLabel = "Share"
            item.delegate = self
            return item

        case .diskiTags:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Tags"
            item.paletteLabel = "Tags"
            item.toolTip = "Tag the selected items"
            item.image = symbol("tag", label: "Tags")
            item.showsIndicator = false
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = NSUserInterfaceItemIdentifier("tagsMenu")
            item.menu = menu
            return item

        case .diskiAction:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Action"
            item.paletteLabel = "Action"
            item.toolTip = "Actions for the selected items"
            item.image = symbol("ellipsis", label: "Action")
            item.showsIndicator = false
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = NSUserInterfaceItemIdentifier("actionMenu")
            item.menu = menu
            return item

        case .diskiSearch:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.preferredWidthForSearchField = 230
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = true
            item.resignsFirstResponderWithCancel = true
            if flag { searchItem = item }
            return item

        case .diskiOperations:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Progress"
            item.paletteLabel = "File Operations Progress"
            item.toolTip = "File operations"
            operationsView.onClick = { [weak self] in self?.showOperations(nil) }
            item.view = operationsView
            item.isBordered = false
            item.isHidden = FileOperationManager.shared.operations.isEmpty
            if flag { operationsItem = item }
            return item

        case .diskiDualPane:
            return button(itemIdentifier, label: "Dual Pane", symbol: symbol("rectangle.split.2x1", label: "Dual Pane"),
                          action: #selector(toggleDualPane(_:)), target: self)
        case .diskiNewFolder:
            return button(itemIdentifier, label: "New Folder", symbol: symbol("folder.badge.plus", label: "New Folder"),
                          action: #selector(PaneViewController.newFolder(_:)))
        case .diskiTrash:
            return button(itemIdentifier, label: "Move to Trash", symbol: symbol("trash", label: "Trash"),
                          action: #selector(PaneViewController.moveToTrash(_:)))
        case .diskiTerminal:
            return button(itemIdentifier, label: "Terminal", symbol: symbol("terminal", label: "Terminal"),
                          action: #selector(PaneViewController.openInTerminal(_:)))
        case .diskiGetInfo:
            return button(itemIdentifier, label: "Get Info", symbol: symbol("info.circle", label: "Get Info"),
                          action: #selector(PaneViewController.getInfo(_:)))
        case .diskiPreviewPane:
            let images = [symbol("sidebar.trailing", "sidebar.right", label: "Preview")].compactMap { $0 }
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .selectAny,
                                           labels: ["Preview"], target: self, action: #selector(togglePreviewPane(_:)))
            group.label = "Preview"
            group.paletteLabel = "Preview"
            group.toolTip = "Show or hide the preview pane"
            group.isBordered = true
            group.controlRepresentation = .expanded
            group.setSelected(!inspectorItem.isCollapsed, at: 0)
            group.subitems.first?.toolTip = group.toolTip
            if flag { previewPaneGroup = group }
            return group
        default:
            return nil
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        activePane.selectedURLs
    }

    // MARK: - Toolbar menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let pane = activePane else { return }
        switch menu.identifier?.rawValue {
        case "sortMenu":
            menu.addItem(NSMenuItem.sectionHeader(title: "Sort By"))
            for key in SortKey.allCases {
                let entry = NSMenuItem(title: key.title, action: #selector(PaneViewController.sortBy(_:)), keyEquivalent: "")
                entry.representedObject = key.rawValue
                entry.target = pane
                entry.state = key == pane.arrangeOptions.sortKey ? .on : .off
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let folders = NSMenuItem(title: "Keep Folders on Top", action: #selector(PaneViewController.toggleFoldersOnTop(_:)), keyEquivalent: "")
            folders.target = pane
            folders.state = Prefs.foldersOnTop ? .on : .off
            menu.addItem(folders)
            let hidden = NSMenuItem(title: "Show Hidden Files", action: #selector(PaneViewController.toggleHiddenFiles(_:)), keyEquivalent: "")
            hidden.target = pane
            hidden.state = Prefs.showHiddenFiles ? .on : .off
            menu.addItem(hidden)
            let sizes = NSMenuItem(title: "Calculate Folder Sizes", action: #selector(toggleFolderSizes(_:)), keyEquivalent: "")
            sizes.target = self
            sizes.state = Prefs.calculateFolderSizes ? .on : .off
            menu.addItem(sizes)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Row Size"))
            for density in RowDensity.allCases {
                let entry = NSMenuItem(title: density.title, action: #selector(setRowDensity(_:)), keyEquivalent: "")
                entry.tag = density.rawValue
                entry.target = self
                entry.state = density == Prefs.rowDensity ? .on : .off
                menu.addItem(entry)
            }
        case "tagsMenu":
            for index in TagColors.sidebarOrder {
                let entry = NSMenuItem(title: TagColors.names[index], action: #selector(PaneViewController.applyTag(_:)), keyEquivalent: "")
                entry.tag = index
                entry.target = pane
                entry.image = PaneViewController.dotImage(TagColors.color(forLabel: index))
                entry.isEnabled = !pane.selectedItems.isEmpty
                menu.addItem(entry)
            }
        case "actionMenu":
            pane.populateContextMenu(menu, for: pane.selectedItems)
        default:
            break
        }
    }

    @objc func toggleFolderSizes(_ sender: Any?) {
        Prefs.calculateFolderSizes.toggle()
    }

    @objc func setRowDensity(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let density = RowDensity(rawValue: item.tag) else { return }
        Prefs.rowDensity = density
    }
}
