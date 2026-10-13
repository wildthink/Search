import AppKit

// `bench catalog ID ACTION …`: a catalog's tab driven and read from the
// shell, the way the bench drives pages. Every answer carries the tree as
// lines — "+" a section, "-" a row, indented as nested, "×" in the trash —
// with what is chosen and whether there are changes to save.
//
//   tree                       what is in it
//   select TITLE…              choose rows by their titles
//   open                       the chosen rows in tabs → how many tabs there are
//   add URL…                   addresses where something new goes
//   section TITLE              a new section there, named
//   set FIELD VALUE            title|description|address|tags|notes of the one chosen
//   move TITLE [INDEX]         the chosen rows into the section named (or "top")
//   trash | restore | empty    throw away, put back, empty the trash
//   undo | redo | save
//   filter TEXT                the filter, as typed ("" to clear)
//   addpage                    Bookmarks › Add Page to Catalog, for the tab in front

extension Bench {
    /// The fork's commands. Whether `verb` was one.
    func surfboard(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) -> Bool {
        guard verb == "catalog" else { return false }
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty,
              let tab = browser.tabs.first(where: { (Store.testing || $0.bench) && $0.id.uuidString.lowercased().hasPrefix(ref) }),
              let document = tab.document as? CatalogDocument
        else {
            answer(["error": "no catalog tab “\(request["id"] as? String ?? "")” — see tabs"])
            return true
        }
        let args = request["args"] as? [String] ?? []
        let catalog = document.catalog
        func rows(titled titles: [String]) -> [CatalogNode] {
            titles.compactMap { title in (catalog.root.all + catalog.trash.all).first { $0.title == title } }
        }
        func choose(_ nodes: [CatalogNode]) {
            for node in nodes {
                var up = node.parent
                while let parent = up, parent !== catalog.root {
                    document.outline.expandItem(parent)
                    up = parent.parent
                }
            }
            document.outline.selectRowIndexes(IndexSet(nodes.map { document.outline.row(forItem: $0) }.filter { $0 >= 0 }),
                                              byExtendingSelection: false)
        }
        switch request["action"] as? String ?? "tree" {
        case "tree": break
        case "select": choose(rows(titled: args))
        case "open":
            document.open(document.chosen)
        case "add": document.add(args.compactMap(URL.init(string:)))
        case "section":
            document.newSection(nil)
            if let name = args.first, let node = document.chosen.first {
                catalog.change(id: node.concept?.id ?? "") { $0.title = name }
                document.reload(keeping: [node.concept?.id ?? ""])
            }
        case "set":
            guard args.count == 2, let node = document.chosen.first, let id = node.concept?.id else {
                answer(["error": "set FIELD VALUE, with one row chosen"])
                return true
            }
            let value = args[1]
            document.change("Change") {
                catalog.change(id: id) { concept in
                    switch args[0] {
                    case "title": concept.title = value
                    case "description": concept.summary = value
                    case "address": concept.resource = value
                    case "tags": concept.tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    case "notes": concept.body = value
                    default: break
                    }
                }
            }
        case "move":
            let target = args.first == "top" ? catalog.root : rows(titled: Array(args.prefix(1))).first
            guard let target else { answer(["error": "no section “\(args.first ?? "")”"]); return true }
            let moving = document.chosen
            let index = args.count > 1 ? Int(args[1]) ?? target.children.count : target.children.count
            document.change("Move") {
                var at = index
                for node in moving {
                    if node.parent === target, let was = target.children.firstIndex(where: { $0 === node }), was < at { at -= 1 }
                    node.detach()
                    target.insert(node, at: at)
                    at += 1
                }
            }
            choose(moving)
        case "trash": document.throwAway(document.chosen)
        case "restore": document.restore(document.chosen)
        case "empty": document.emptyTrash()
        case "undo": document.undoManager?.undo()
        case "redo": document.undoManager?.redo()
        case "save":
            document.save { saved in
                answer(Bench.describe(document, tab: tab, browser: browser, ["saved": saved]))
            }
            return true
        case "addpage":
            // Bookmarks › Add Page to Catalog, for the tab in front.
            Surfboard.addPage(from: browser)
        case "filter":
            document.filterForBench(args.first ?? "")
        default:
            answer(["error": "catalog ID tree|select|open|add|section|set|move|trash|restore|empty|undo|redo|save|filter|addpage"])
            return true
        }
        answer(Bench.describe(document, tab: tab, browser: browser))
        return true
    }

    static func describe(_ document: CatalogDocument, tab: Tab, browser: Browser, _ extra: [String: Any] = [:]) -> [String: Any] {
        let catalog = document.catalog
        func lines(_ nodes: [CatalogNode], _ depth: Int, _ mark: String) -> [String] {
            nodes.flatMap { node in
                [String(repeating: "  ", count: depth) + (node.isSection ? "+ " : mark) + node.title]
                    + lines(node.children, depth + 1, mark)
            }
        }
        return [
            "title": catalog.title,
            "tree": lines(catalog.root.children, 0, "- "),
            "trash": lines(catalog.trash.children, 0, "× "),
            "chosen": document.chosen.map(\.title),
            "shown": (0..<document.outline.numberOfRows).compactMap { (document.outline.item(atRow: $0) as? CatalogNode)?.title },
            "edited": document.dirty,
            "undo": ["level": document.undoManager?.groupingLevel ?? -1, "can": document.undoManager?.canUndo ?? false,
                     "name": document.undoManager?.undoActionName ?? "", "byEvent": document.undoManager?.groupsByEvent ?? false],
            "tabTitle": tab.title,
            "tabs": browser.tabs.count,
        ].merging(extra) { _, new in new }
    }
}

extension CatalogDocument {
    /// The filter, as if typed.
    func filterForBench(_ text: String) {
        filter.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: filter))
    }
}
