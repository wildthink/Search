import AppKit
import UniformTypeIdentifiers

// A Surfboard catalog in a tab: its outline on the left, what is chosen on the
// right. A site or a file opens in a tab of its own (onLink), the way a link
// in a Markdown file does, so the catalog stays where it is to go on from.
// Edits are the document's — undone with ⌘Z, marked in the tab's name, and
// written with ⌘S as any file Search edits (TabContent.swift): only the
// files that changed, with the trash emptied of what has been there longer
// than keepDays (Catalog.decay).
//
// Things come in by pasting an address (⌘V), dropping a link or a file on the
// outline, or New Section; rows are dragged where they belong, and ⌫ puts the
// chosen ones in the trash, the last row of the outline.

/// Which files are catalogs: a .surfboard folder.
enum Catalogs {
    static let type = "com.wildthink.surfboard"

    static func handles(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "surfboard" else { return false }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}

final class CatalogDocument: NSDocument, TabContent, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    /// How long a thrown-away row stays in the trash before a save lets it go,
    /// as the Surfboard app keeps it.
    static let keepDays = 30

    private(set) var catalog = Catalog(catalog: nil, items: [:])

    /// The folder as read and as last written: saving changes it in place,
    /// so a file nothing touched is left as it is.
    private var bundle: FileWrapper?

    /// What the last save wrote, marked as on disk once it is.
    private var writing: Catalog.Output?

    private let page = CatalogPage()
    private let split = NSSplitView()
    let filter = NSSearchField()
    let outline = CatalogOutlineView()
    private let outlineScroll = NSScrollView()
    private let detail = CatalogDetail()

    var onDirty: ((Bool) -> Void)?
    var onLink: ((URL) -> Void)?
    var isReading: Bool { false }
    var view: NSView { page }
    var focus: NSView { outline }

    /// For find and the assistant: what is in it, as the listing OKF's own
    /// tools read.
    var text: String? { catalog.indexText() }

    /// The rows matching what is typed in the filter, when something is.
    private var found: [CatalogNode]?

    /// The first undo of an edit typed into the panel, kept from its first
    /// keystroke to its last: one edit, one undo.
    private var typing: Catalog.Snapshot?

    override init() {
        super.init()
        build()
    }

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { false }
    override class func isNativeType(_ type: String) -> Bool { true }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        fileType.map { [$0] } ?? [Catalogs.type]
    }
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        "surfboard"
    }
    override var windowForSheet: NSWindow? { page.window ?? NSApp.keyWindow }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard fileWrapper.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
        let chosen = selectedIDs()
        let open = expandedIDs()
        bundle = fileWrapper
        catalog = Catalog(bundle: fileWrapper)
        CatalogDocument.lastUsed = self
        undoManager?.removeAllActions()
        reload(keeping: chosen, open: open)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        endTyping()
        catalog.decay(before: Date().addingTimeInterval(-Double(CatalogDocument.keepDays) * 24 * 60 * 60))
        let output = catalog.output()
        let folder = bundle ?? FileWrapper(directoryWithFileWrappers: [:])
        catalog.update(folder, with: output)
        bundle = folder
        writing = output
        return folder
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self, let output = writing {
                catalog.saved(output)
                writing = nil
                // What decay took is gone from the outline too.
                reload(keeping: selectedIDs(), open: expandedIDs())
            }
            completionHandler(error)
        }
    }

    override func close() {
        NSFileCoordinator.removeFilePresenter(self)
        super.close()
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        onDirty?(isDocumentEdited)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        NSPrintOperation(view: outline, printInfo: printInfo)
    }

    /// Another app changed the catalog — the Surfboard app, a sync, an
    /// editor on _catalog.md. With nothing changed here, it is read again.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        rereadIfUntouched()
    }

    override func presentedSubitemDidChange(at url: URL) {
        super.presentedSubitemDidChange(at: url)
        rereadIfUntouched()
    }

    private var rereading = false
    private func rereadIfUntouched() {
        guard !rereading else { return }
        rereading = true
        // Changes come in bursts — a folder of files written one by one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            rereading = false
            guard !isDocumentEdited, typing == nil, writing == nil, let fileURL, let fileType else { return }
            try? revert(toContentsOf: fileURL, ofType: fileType)
        }
    }

    // MARK: - TabContent

    var zoom: CGFloat {
        get { outlineScroll.magnification }
        set { outlineScroll.magnification = newValue }
    }

    /// ⌘F: the filter over the outline.
    func showFind() {
        page.window?.makeFirstResponder(filter)
    }

    func setReading(_ on: Bool) -> Bool { false }

    // MARK: - The view

    private func build() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: page.topAnchor),
            split.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        ])

        let left = NSView()
        filter.placeholderString = "Filter"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(filter)

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.autosaveExpandedItems = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openChosen(_:))
        outline.document = self
        outline.registerForDraggedTypes([CatalogOutlineView.row, .URL, .fileURL, .string])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
        outlineScroll.allowsMagnification = true
        outlineScroll.minMagnification = 0.6
        outlineScroll.maxMagnification = 2.5
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(outlineScroll)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),
            filter.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -10),
            outlineScroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8),
            outlineScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])

        detail.document = self
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail.view)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        detail.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        DispatchQueue.main.async { [weak self] in
            guard let self, split.bounds.width > 0 else { return }
            split.setPosition(min(380, split.bounds.width * 0.42), ofDividerAt: 0)
        }
    }

    /// Everything drawn again from the catalog, the same rows chosen and
    /// open as far as they still exist.
    func reload(keeping chosen: [String] = [], open: Set<String>? = nil) {
        if let text = found.map({ _ in filter.stringValue }) { found = matches(text) }
        outline.reloadData()
        if let open {
            for node in catalog.root.all + [catalog.trash] where open.contains(key(node)) { outline.expandItem(node) }
        } else {
            // Opened fresh: the top level open, the trash closed.
            for node in catalog.root.children where node.isSection { outline.expandItem(node) }
        }
        let rows = IndexSet(chosen.compactMap { id in
            (catalog.root.all + catalog.trash.all).first { key($0) == id }.map { outline.row(forItem: $0) }
        }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        detail.show(chosen: self.chosen, in: catalog)
    }

    /// A row's name for keeping it chosen or open across a reload: its file,
    /// or a text section's place in the tree.
    private func key(_ node: CatalogNode) -> String {
        if node === catalog.trash { return "trash" }
        if let id = node.concept?.id { return id }
        var path = [node.text]
        var at = node.parent
        while let up = at, up !== catalog.root, up !== catalog.trash { path.insert(up.title, at: 0); at = up.parent }
        return "text:" + path.joined(separator: "/")
    }

    private func selectedIDs() -> [String] { chosen.map(key) }

    private func expandedIDs() -> Set<String>? {
        guard outline.numberOfRows > 0 else { return nil }
        return Set((catalog.root.all + [catalog.trash]).filter { outline.isItemExpanded($0) }.map(key))
    }

    var chosen: [CatalogNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? CatalogNode }
    }

    /// The rows a menu or a key acts on: the one clicked, with the others
    /// chosen if it is one of them.
    private var acted: [CatalogNode] {
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            return (outline.item(atRow: clicked) as? CatalogNode).map { [$0] } ?? []
        }
        return chosen
    }

    // MARK: - Changes

    /// A change to the catalog, undoable as one step, named for the Edit menu.
    func change(_ name: String, _ change: () -> Void) {
        endTyping()
        let before = catalog.snapshot()
        let chosenBefore = selectedIDs()
        change()
        remember(before, chosen: chosenBefore, as: name)
        reload(keeping: selectedIDs(), open: expandedIDs())
    }

    private func remember(_ snapshot: Catalog.Snapshot, chosen: [String], as name: String) {
        // A step of its own, closed now: left to the event's own group, a
        // change made from a menu, a drop or a script would only count once
        // the next key or click ended that group. Grouping by event is held
        // off meanwhile, or opening this group would open that one around it.
        let own = undoManager?.groupingLevel == 0
        let byEvent = undoManager?.groupsByEvent ?? true
        if own {
            undoManager?.groupsByEvent = false
            undoManager?.beginUndoGrouping()
        }
        defer {
            if own {
                undoManager?.endUndoGrouping()
                undoManager?.groupsByEvent = byEvent
            }
        }
        undoManager?.registerUndo(withTarget: self) { document in
            let now = document.catalog.snapshot()
            let chosenNow = document.selectedIDs()
            let open = document.expandedIDs()
            document.catalog.restore(snapshot)
            document.remember(now, chosen: chosenNow, as: name)
            document.reload(keeping: chosen, open: open)
        }
        undoManager?.setActionName(name)
    }

    /// A field in the panel changed: the catalog follows as it is typed,
    /// and the whole edit is one undo, from the first keystroke.
    func typed(_ change: () -> Void) {
        if typing == nil {
            let before = catalog.snapshot()
            typing = before
            remember(before, chosen: selectedIDs(), as: "Typing")
        }
        change()
        // Only the rows: the panel is where the typing is.
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: [0])
    }

    func endTyping() {
        if typing != nil, let editor = page.window?.firstResponder as? NSText, editor.isDescendant(of: detail.view) {
            page.window?.makeFirstResponder(outline)
        }
        typing = nil
    }

    func open(_ nodes: [CatalogNode]) {
        for node in nodes {
            if let url = node.concept?.url {
                onLink?(url)
            } else if outline.isExpandable(node) {
                outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
            }
        }
    }

    @objc func openChosen(_ sender: Any?) {
        let clicked = outline.clickedRow
        if clicked >= 0, let node = outline.item(atRow: clicked) as? CatalogNode { open([node]) } else { open(chosen) }
    }

    /// Into the trash, or — for rows already there — gone for good.
    func throwAway(_ nodes: [CatalogNode]) {
        let rows = nodes.filter { $0 !== catalog.trash && !isTrashed($0) }
        let gone = nodes.filter { $0 !== catalog.trash && isTrashed($0) }
        // A row under another chosen one goes with it.
        let top = rows.filter { row in !rows.contains { $0 !== row && $0.contains(row) } }
        guard !top.isEmpty || !gone.isEmpty else { NSSound.beep(); return }
        let next = neighbour(after: nodes)
        change(top.isEmpty ? "Delete Now" : "Move to Trash") {
            top.forEach { catalog.throwAway($0) }
            gone.forEach { catalog.purge($0) }
        }
        if let next, outline.row(forItem: next) >= 0 {
            outline.selectRowIndexes([outline.row(forItem: next)], byExtendingSelection: false)
        }
    }

    private func neighbour(after nodes: [CatalogNode]) -> CatalogNode? {
        let rows = nodes.map { outline.row(forItem: $0) }.filter { $0 >= 0 }
        guard let last = rows.max() else { return nil }
        let set = Set(nodes.map(ObjectIdentifier.init))
        for row in (last + 1)..<max(last + 1, outline.numberOfRows) {
            if let node = outline.item(atRow: row) as? CatalogNode, !set.contains(ObjectIdentifier(node)),
               !nodes.contains(where: { $0.contains(node) }) { return node }
        }
        return nil
    }

    func isTrashed(_ node: CatalogNode) -> Bool { catalog.trash.contains(node) && node !== catalog.trash }

    func restore(_ nodes: [CatalogNode]) {
        let top = nodes.filter { isTrashed($0) && $0.parent === catalog.trash }
        guard !top.isEmpty else { return }
        change("Put Back") { top.forEach { catalog.restore($0) } }
    }

    func emptyTrash() {
        guard !catalog.trash.children.isEmpty else { return }
        change("Empty Trash") { catalog.trash.children.forEach { catalog.purge($0) } }
    }

    /// Where something new goes: into the chosen section, or beside the chosen
    /// row, or at the end.
    private func place() -> (parent: CatalogNode, index: Int) {
        guard let node = chosen.last, !isTrashed(node), node !== catalog.trash else {
            return (catalog.root, catalog.root.children.count)
        }
        if node.isSection { return (node, node.children.count) }
        let parent = node.parent ?? catalog.root
        return (parent, (parent.children.firstIndex { $0 === node } ?? parent.children.count - 1) + 1)
    }

    func add(_ urls: [URL], to parent: CatalogNode? = nil, at index: Int? = nil) {
        let target = parent.map { ($0, index ?? $0.children.count) } ?? place()
        let made = urls.map { url -> CatalogNode in
            var concept = CatalogConcept.new(type: url.isFileURL ? CatalogConcept.fileType : CatalogConcept.websiteType,
                                             resource: url.absoluteString)
            if url.isFileURL { concept.title = url.lastPathComponent }
            return CatalogNode(concept: concept)
        }
        guard !made.isEmpty else { return }
        change(made.count == 1 ? "Add Address" : "Add Addresses") {
            for (n, node) in made.enumerated() { target.0.insert(node, at: target.1 + n) }
        }
        if target.0 !== catalog.root { outline.expandItem(target.0) }
        outline.selectRowIndexes(IndexSet(made.map { outline.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        outline.scrollRowToVisible(outline.selectedRow)
    }

    @objc func newSection(_ sender: Any?) {
        let target = place()
        let node = CatalogNode(concept: .new(type: CatalogConcept.sectionType, title: "New Section"))
        change("New Section") { target.parent.insert(node, at: target.index) }
        outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
        detail.editTitle()
    }

    /// ⌘V: addresses on the clipboard — links, files, or text that reads as
    /// one address a line.
    @objc func pasteAddresses(_ sender: Any?) {
        let urls = CatalogDocument.addresses(on: .general)
        guard !urls.isEmpty else { NSSound.beep(); return }
        add(urls)
    }

    static func addresses(on board: NSPasteboard) -> [URL] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.filter { $0.isFileURL || $0.scheme == "http" || $0.scheme == "https" }
        }
        guard let text = board.string(forType: .string) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.contains(" "), let url = URL(string: line), url.scheme == "http" || url.scheme == "https" else { return nil }
            return url
        }
    }

    @objc func copyAddresses(_ sender: Any?) {
        let urls = acted.compactMap { $0.concept?.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    // MARK: - Filter

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === filter else { return }
        let text = filter.stringValue.trimmingCharacters(in: .whitespaces)
        found = text.isEmpty ? nil : matches(text)
        outline.reloadData()
        if found == nil { reload(keeping: selectedIDs(), open: nil) } else if outline.numberOfRows > 0 {
            outline.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    /// Every row in the catalog — not the trash — whose title, description,
    /// address, tags or notes hold every word typed.
    private func matches(_ text: String) -> [CatalogNode] {
        let words = text.lowercased().split(separator: " ")
        return catalog.root.all.dropFirst().filter { node in
            guard let concept = node.concept, !node.isSection else { return false }
            let hay = [concept.shownTitle, concept.summary ?? "", concept.resource ?? "", concept.tags.joined(separator: " "),
                       concept.body].joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === filter else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            page.window?.makeFirstResponder(outline)
            if selector == #selector(NSResponder.insertNewline(_:)) { open(chosen) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            filter.stringValue = ""
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: filter))
            page.window?.makeFirstResponder(outline)
            return true
        default:
            return false
        }
    }

    // MARK: - NSOutlineViewDataSource

    private func children(of item: Any?) -> [CatalogNode] {
        if item == nil {
            if let found { return found }
            return catalog.root.children + (catalog.trash.children.isEmpty ? [] : [catalog.trash])
        }
        return (item as? CatalogNode)?.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        found != nil && item != nil ? 0 : children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        found == nil && !((item as? CatalogNode)?.children.isEmpty ?? true)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CatalogNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("catalogRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(image)
            cell.addSubview(field)
            cell.imageView = image
            cell.textField = field
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let isTrash = node === catalog.trash
        let title = isTrash ? "Trash" : node.title
        let line = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: node.isSection && !isTrash ? .medium : .regular),
            .foregroundColor: isTrashed(node) ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        let aside = isTrash ? "\(catalog.trash.all.count - 1)" : CatalogDocument.aside(node)
        if !aside.isEmpty {
            line.append(NSAttributedString(string: "  " + aside, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        cell.textField?.attributedStringValue = line
        cell.textField?.toolTip = node.concept?.resource
        cell.imageView?.image = isTrash ? CatalogDocument.symbol("trash", nil) : CatalogDocument.icon(for: node)
        cell.imageView?.contentTintColor = isTrash ? .secondaryLabelColor : CatalogDocument.tint(node.concept?.color)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        CatalogDocument.lastUsed = self
        endTyping()
        detail.show(chosen: chosen, in: catalog)
    }

    /// What follows a row's name: its description, else where it is.
    static func aside(_ node: CatalogNode) -> String {
        guard let concept = node.concept, !node.isSection else { return "" }
        if let summary = concept.summary, !summary.isEmpty { return summary }
        guard let url = concept.url, concept.title?.isEmpty == false else { return "" }
        return url.isFileURL ? url.deletingLastPathComponent().lastPathComponent : url.host ?? ""
    }

    static func icon(for node: CatalogNode) -> NSImage? {
        guard let concept = node.concept else { return symbol("folder", nil) }
        if let name = concept.icon, let image = symbol(name, nil) { return image }
        if let url = concept.url {
            if url.isFileURL {
                if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
                return symbol("doc", nil)
            }
            // Only an icon Search already has: a catalog doesn't reach out to
            // every site in it just for a picture.
            if !concept.isSection, let site = Favicons.site(url), let image = Favicons.shared.cached(site) { return image }
        }
        switch concept.type {
        case CatalogConcept.sectionType: return symbol("folder", nil)
        case "Person": return symbol("person.crop.circle", nil)
        case "Place": return symbol("mappin.and.ellipse", nil)
        case "Note": return symbol("note.text", nil)
        case CatalogConcept.websiteType: return symbol("globe", nil)
        default: return symbol("doc.text", nil)
        }
    }

    static func symbol(_ name: String, _ label: String?) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    /// The Surfboard app's colours, by name.
    static func tint(_ name: String?) -> NSColor? {
        switch name {
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "blue": .systemBlue
        case "purple": .systemPurple
        case "pink": .systemPink
        case "gray": .systemGray
        default: .secondaryLabelColor
        }
    }

    // MARK: - Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? CatalogNode, node !== catalog.trash, found == nil else { return nil }
        let board = NSPasteboardItem()
        board.setString(key(node), forType: CatalogOutlineView.row)
        // Out of the catalog — to a tab, a mail, the Finder — it is its address.
        if let url = node.concept?.url {
            board.setString(url.absoluteString, forType: url.isFileURL ? .fileURL : .URL)
            board.setString(url.absoluteString, forType: .string)
        }
        return board
    }

    private var dragged: [CatalogNode] = []

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems items: [Any]) {
        dragged = items.compactMap { $0 as? CatalogNode }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragged = []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard found == nil else { return [] }
        var target = item as? CatalogNode
        var index = index
        // Onto a row that isn't a section: beside it instead.
        if let row = target, !row.isSection, row !== catalog.trash {
            let parent = row.parent === catalog.root ? nil : row.parent
            index = (row.parent?.children.firstIndex { $0 === row } ?? 0) + 1
            target = parent
            outlineView.setDropItem(parent, dropChildIndex: index)
        }
        // Below the trash, at the top level: the end of the catalog.
        if target == nil, index > catalog.root.children.count { outlineView.setDropItem(nil, dropChildIndex: catalog.root.children.count) }
        let inside = info.draggingSource as? NSOutlineView === outlineView && !dragged.isEmpty
        if inside {
            if let target, dragged.contains(where: { $0.contains(target) }) { return [] }
            return .move
        }
        if target === catalog.trash || target.map(isTrashed) == true { return [] }
        return CatalogDocument.addresses(on: info.draggingPasteboard).isEmpty ? [] : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let target = (item as? CatalogNode) ?? catalog.root
        let inside = info.draggingSource as? NSOutlineView === outlineView && !dragged.isEmpty
        guard inside else {
            let urls = CatalogDocument.addresses(on: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            add(urls, to: target, at: index < 0 ? target.children.count : index)
            return true
        }
        let moving = dragged.filter { row in !dragged.contains { $0 !== row && $0.contains(row) } }
        let intoTrash = target === catalog.trash || isTrashed(target)
        change(intoTrash ? "Move to Trash" : "Move") {
            var at = index < 0 ? target.children.count : index
            for node in moving {
                // Taken out above where it goes: one place fewer to count.
                if node.parent === target, let was = target.children.firstIndex(where: { $0 === node }), was < at { at -= 1 }
                let wasTrashed = isTrashed(node)
                node.detach()
                if intoTrash, !wasTrashed {
                    for row in node.all where row.concept?.deleted == nil { row.concept?.deleted = Date() }
                } else if !intoTrash, wasTrashed {
                    for row in node.all { row.concept?.deleted = nil }
                }
                target.insert(node, at: at)
                at += 1
            }
        }
        if target !== catalog.root { outline.expandItem(target) }
        outline.selectRowIndexes(IndexSet(moving.map { outline.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        return true
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = acted
        func item(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if rows.contains(where: { $0.concept?.url != nil }) {
            item(rows.count > 1 ? "Open in Tabs" : "Open in New Tab", #selector(openActed(_:)))
            item(rows.count > 1 ? "Copy Addresses" : "Copy Address", #selector(copyAddresses(_:)))
            menu.addItem(.separator())
        }
        if rows.contains(where: { $0 === catalog.trash }) {
            item("Empty Trash", #selector(emptyTrashAction(_:)))
            return
        }
        if rows.contains(where: isTrashed) {
            item("Put Back", #selector(putBack(_:)))
            item("Delete Now", #selector(throwAwayActed(_:)))
            return
        }
        item("New Section", #selector(newSection(_:)))
        item("Paste Address", #selector(pasteAddresses(_:)))
        if !rows.isEmpty {
            menu.addItem(.separator())
            item("Move to Trash", #selector(throwAwayActed(_:)))
        }
    }

    @objc private func openActed(_ sender: Any?) { open(acted) }
    @objc private func throwAwayActed(_ sender: Any?) { throwAway(acted) }
    @objc private func putBack(_ sender: Any?) { restore(acted) }
    @objc private func emptyTrashAction(_ sender: Any?) { emptyTrash() }
}

/// The outline, with the keys a catalog answers: Return opens, ⌫ throws
/// away, ⌘V adds addresses, and ⌘Z undoes with the document (see
/// DocumentTextView for why it has to say so).
final class CatalogOutlineView: NSOutlineView {
    static let row = NSPasteboard.PasteboardType("com.wildthink.surfboard.row")
    weak var document: CatalogDocument?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: document?.open(document?.chosen ?? [])
        case 51, 117: document?.throwAway(document?.chosen ?? [])
        default: super.keyDown(with: event)
        }
    }

    @objc func undo(_ sender: Any?) { document?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { document?.undoManager?.redo() }
    @objc func paste(_ sender: Any?) { document?.pasteAddresses(sender) }
    @objc func copy(_ sender: Any?) { document?.copyAddresses(sender) }
    @objc func delete(_ sender: Any?) { document?.throwAway(document?.chosen ?? []) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return document?.undoManager?.canUndo ?? false
        case #selector(redo(_:)): return document?.undoManager?.canRedo ?? false
        case #selector(paste(_:)): return !CatalogDocument.addresses(on: .general).isEmpty
        case #selector(copy(_:)): return document?.chosen.contains { $0.concept?.url != nil } ?? false
        case #selector(delete(_:)): return !(document?.chosen.isEmpty ?? true)
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

/// The tab's ground: the outline's side as a sidebar is, the rest as a page.
final class CatalogPage: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
