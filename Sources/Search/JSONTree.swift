import AppKit

// JSON, read as the tree it is: for a .json tab's reading view (see
// TabContent.swift), with ⇧⌘R going between it and the source.
//
// An outline of keys and values, the top level open and everything below it
// closed, each branch saying how much it holds. A branch's rows are made
// only when it is opened, so a file of a hundred thousand records costs what
// is on screen. A file that isn't valid JSON says so, and where, rather than
// showing half a tree.

final class JSONTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scroll = NSScrollView()
    let outline = NSOutlineView()
    private let problem = NSTextField(wrappingLabelWithString: "")
    private var root: Node?

    /// One key and its value. Children are made on first asking.
    final class Node {
        let key: String
        let value: Any
        /// Where each key first stands in the source, for its order.
        private let order: [String: Int]
        private var made: [Node]?

        init(key: String, value: Any, order: [String: Int] = [:]) {
            self.key = key
            self.value = value
            self.order = order
        }

        var children: [Node] {
            if let made { return made }
            let made: [Node]
            if let object = value as? [String: Any] {
                // In the file's order, which the parser doesn't keep: a key
                // it never saw (escaped in the source) goes last, by name.
                made = object.keys.sorted { a, b in
                    switch (order[a], order[b]) {
                    case let (x?, y?): x < y
                    case (_?, nil): true
                    case (nil, _?): false
                    case (nil, nil): a.localizedStandardCompare(b) == .orderedAscending
                    }
                }.map { Node(key: $0, value: object[$0] as Any, order: order) }
            } else if let array = value as? [Any] {
                made = array.enumerated().map { Node(key: "\($0.offset)", value: $0.element, order: order) }
            } else {
                made = []
            }
            self.made = made
            return made
        }

        var isBranch: Bool { value is [String: Any] || value is [Any] }

        /// What the value column says: the value itself, or how much a
        /// branch holds.
        var summary: String {
            switch value {
            case let object as [String: Any]: return object.count == 1 ? "{ 1 key }" : "{ \(object.count) keys }"
            case let array as [Any]: return array.count == 1 ? "[ 1 item ]" : "[ \(array.count) items ]"
            case let string as String: return "“\(string)”"
            case let number as NSNumber:
                // JSON's true and false come back as NSNumber too.
                return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            case is NSNull: return "null"
            default: return "\(value)"
            }
        }

        var tint: NSColor {
            switch value {
            case is String: return .systemGreen
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return .systemPurple
            case is NSNumber: return .systemBlue
            case is NSNull: return .tertiaryLabelColor
            default: return .secondaryLabelColor
            }
        }
    }

    override init() {
        super.init()
        let key = NSTableColumn(identifier: .init("key"))
        key.title = "Key"
        key.width = 260
        let value = NSTableColumn(identifier: .init("value"))
        value.title = "Value"
        value.width = 520
        outline.addTableColumn(key)
        outline.addTableColumn(value)
        outline.outlineTableColumn = key
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.addItem(withTitle: "Copy Value", action: #selector(copyValue(_:)), keyEquivalent: "").target = self
        outline.menu?.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "").target = self

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.4
        scroll.maxMagnification = 3

        problem.textColor = .secondaryLabelColor
        problem.font = .systemFont(ofSize: 13)
        problem.isHidden = true
        problem.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(problem)
        NSLayoutConstraint.activate([
            problem.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28),
            problem.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 32),
            problem.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -32),
        ])
    }

    /// The tree of `source`, or why there is none. What was open stays open
    /// where the same keys are still there to open.
    func show(_ source: String) {
        let open = expandedPaths()
        do {
            let value = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
            root = Node(key: "", value: value, order: JSONTree.keyOrder(source))
            problem.isHidden = true
            outline.isHidden = false
            outline.reloadData()
            if open.isEmpty {
                // The top level open, the rest closed.
                for child in root?.children ?? [] where child.isBranch { outline.expandItem(child) }
            } else {
                reopen(open, under: root, path: [])
            }
        } catch {
            root = nil
            outline.reloadData()
            outline.isHidden = true
            problem.isHidden = false
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            problem.stringValue = "This isn’t valid JSON, so there is no tree to show.\n\(detail)\n\n⇧⌘R shows the source."
        }
    }

    /// Every key's first place in the source, in one pass. A key used in
    /// more than one object takes its first place everywhere, which keeps
    /// each object's own order unless two disagree about it.
    static func keyOrder(_ source: String) -> [String: Int] {
        guard let pattern = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*:"#) else { return [:] }
        var order: [String: Int] = [:]
        let text = source as NSString
        pattern.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            let key = text.substring(with: match.range(at: 1))
            if order[key] == nil { order[key] = order.count }
        }
        return order
    }

    // MARK: - keeping what was open

    private func expandedPaths() -> Set<[String]> {
        var paths = Set<[String]>()
        func walk(_ node: Node, _ path: [String]) {
            for child in node.children where outline.isItemExpanded(child) {
                paths.insert(path + [child.key])
                walk(child, path + [child.key])
            }
        }
        if let root { walk(root, []) }
        return paths
    }

    private func reopen(_ paths: Set<[String]>, under node: Node?, path: [String]) {
        for child in node?.children ?? [] where paths.contains(path + [child.key]) {
            outline.expandItem(child)
            reopen(paths, under: child, path: path + [child.key])
        }
    }

    // MARK: - copying

    private var clicked: Node? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? Node : nil
    }

    @objc private func copyValue(_ sender: Any?) {
        guard let node = clicked else { return }
        let text: String
        if node.isBranch || node.value is NSNull,
           let data = try? JSONSerialization.data(withJSONObject: node.value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = (node.value as? String) ?? node.summary
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Where the value is, as code would reach it: user.addresses[0].city.
    @objc private func copyPath(_ sender: Any?) {
        guard let node = clicked else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path(to: node), forType: .string)
    }

    func path(to node: Node) -> String {
        var parts: [String] = []
        var at: Node? = node
        while let current = at {
            let parent = outline.parent(forItem: current) as? Node
            parts.insert((parent ?? root)?.value is [Any] ? "[\(current.key)]" : current.key, at: 0)
            at = parent
        }
        return parts.reduce("") { path, part in
            path.isEmpty || part.hasPrefix("[") ? path + part : path + "." + part
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Node) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isBranch == true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let column = tableColumn else { return nil }
        let isKey = column.identifier.rawValue == "key"
        let id = NSUserInterfaceItemIdentifier(isKey ? "jsonKey" : "jsonValue")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let parentIsArray = (outlineView.parent(forItem: node) as? Node ?? root)?.value is [Any]
        if isKey {
            cell.textField?.stringValue = node.key
            cell.textField?.font = parentIsArray
                ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                : .systemFont(ofSize: 12, weight: .medium)
            cell.textField?.textColor = parentIsArray ? .secondaryLabelColor : .labelColor
        } else {
            cell.textField?.stringValue = node.summary
            cell.textField?.font = node.isBranch
                ? .systemFont(ofSize: 12)
                : .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.textColor = node.tint
            cell.textField?.toolTip = node.isBranch ? nil : node.summary
        }
        return cell
    }
}
