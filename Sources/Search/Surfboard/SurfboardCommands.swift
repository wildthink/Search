import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The browser's way into catalogs, in the Bookmarks menu: the page in front
// added to a catalog, and a new catalog made. Listed with every other command
// (Shortcuts.swift), so Settings › Shortcuts can change their keys.

enum Surfboard {
    /// The fork's commands, after upstream's own.
    static let commands: [Command] = [
        Command("bookmarks.addToCatalog", "Add Page to Catalog", .bookmarks, KeyCombo("d", shift: true)) { addPage(from: $0) },
        Command("bookmarks.newCatalog", "New Catalog…", .bookmarks, nil) { newCatalog(in: $0) },
    ]

    /// Where Add Page to Catalog puts pages: the catalog last chosen in, or
    /// failing that the one open in this window, or in any.
    @MainActor static func target(for browser: Browser) -> (CatalogDocument, Tab, Browser)? {
        let open = Browsers.all.flatMap { owner in
            owner.tabs.compactMap { tab in (tab.document as? CatalogDocument).map { ($0, tab, owner) } }
        }
        if let last = CatalogDocument.lastUsed, let found = open.first(where: { $0.0 === last }) { return found }
        return open.first { $0.2 === browser } ?? open.first
    }

    /// The page in front, into the catalog's "From Browser" section — the
    /// Surfboard app's place for what its star added — and saved, unless the
    /// catalog has changes of its own waiting: those are yours to save.
    @MainActor static func addPage(from browser: Browser) {
        guard let tab = browser.active, let url = tab.pageAddress, url.scheme == "http" || url.scheme == "https" || url.isFileURL,
              !(tab.document is CatalogDocument)
        else { NSSound.beep(); return }
        guard let (document, _, _) = target(for: browser) else {
            browser.announce("Open a catalog first — or make one with Bookmarks › New Catalog…")
            return
        }
        let name = document.catalog.title
        if let existing = document.catalog.root.all.first(where: { $0.concept?.url == url }) {
            document.reveal(existing)
            browser.announce("Already in \(name)")
            return
        }
        let clean = !document.dirty
        let title = tab.title.trimmingCharacters(in: .whitespaces)
        document.addPage(url, title: title.isEmpty ? nil : title)
        // NSDocument counts the change a turn of the run loop later.
        if clean { DispatchQueue.main.async { document.save { _ in } } }
        browser.announce("Added to \(name)")
    }

    /// A new, empty catalog where you choose, opened in a tab.
    @MainActor static func newCatalog(in browser: Browser) {
        let panel = NSSavePanel()
        panel.title = "New Catalog"
        panel.nameFieldStringValue = "Catalog.surfboard"
        if let type = UTType(Catalogs.type) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try make(at: url)
            _ = browser.open(url, foreground: true)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// An empty catalog's files: its tree, named for the file, and the listing.
    static func make(at url: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        try files.createDirectory(at: url.appendingPathComponent("items"), withIntermediateDirectories: true)
        let catalog = Catalog(catalog: nil, items: [:])
        catalog.title = url.deletingPathExtension().lastPathComponent
        try Data(catalog.catalogText().utf8).write(to: url.appendingPathComponent(Catalog.catalogFile))
        try Data(catalog.indexText().utf8).write(to: url.appendingPathComponent(Catalog.indexFile))
    }
}

extension CatalogDocument {
    /// The catalog last chosen in, for Add Page to Catalog.
    static weak var lastUsed: CatalogDocument?

    /// A page, at the end of "From Browser", made at the top if it isn't there.
    func addPage(_ url: URL, title: String?) {
        let section = catalog.root.children.first { $0.title == "From Browser" && $0.isSection }
        var concept = CatalogConcept.new(type: url.isFileURL ? CatalogConcept.fileType : CatalogConcept.websiteType,
                                         title: title, resource: url.absoluteString)
        if url.isFileURL, concept.title == nil { concept.title = url.lastPathComponent }
        let node = CatalogNode(concept: concept)
        change("Add Page") {
            if let section {
                section.append(node)
            } else {
                var made = CatalogConcept.new(type: CatalogConcept.sectionType, title: "From Browser")
                made.icon = "star"
                made.color = "yellow"
                let fresh = CatalogNode(concept: made)
                fresh.append(node)
                catalog.root.insert(fresh, at: 0)
            }
        }
        reveal(node)
    }

    /// Open as far as it, chosen, and scrolled to.
    func reveal(_ node: CatalogNode) {
        var up = node.parent
        var chain: [CatalogNode] = []
        while let parent = up, parent !== catalog.root { chain.insert(parent, at: 0); up = parent.parent }
        chain.forEach { outline.expandItem($0) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }
}

/// The two items in the Bookmarks menu.
struct SurfboardMenuItems: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Button("Add Page to Catalog") { Surfboard.addPage(from: browser) }
            .shortcut("bookmarks.addToCatalog")
            .disabled(browser.active?.isBlank ?? true)
        Button("New Catalog…") { Surfboard.newCatalog(in: browser) }
            .shortcut("bookmarks.newCatalog")
    }
}
