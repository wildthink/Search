import Foundation
import OKFFormat

// Each catalog is read by both — Search's Catalog and OKFFormat's OKFCatalog —
// and what each made of it compared: the tree, and every concept's fields.
// Then each writes, and the other reads what it wrote. Bundles named on the
// command line (a .surfboard folder) are checked too.

var failures = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if !ok {
        failures += 1
        print("✗ \(what())")
    }
}

/// The tree as a list of lines: a concept by its id, a text line by its words.
func shape(_ nodes: [CatalogNode], _ depth: Int = 0) -> [String] {
    nodes.flatMap { node in
        [String(repeating: "  ", count: depth) + (node.concept.map { "C \($0.id)" } ?? "T \(node.text)")]
            + shape(node.children, depth + 1)
    }
}

func shape(_ nodes: [OKFCatalogNode], _ depth: Int = 0) -> [String] {
    nodes.flatMap { node in
        [String(repeating: "  ", count: depth) + (node.concept.map { "C \($0.id)" } ?? "T \(node.title)")]
            // OKFFormat writes a row's children only under a section.
            + (node.isSection ? shape(node.children, depth + 1) : [])
    }
}

func fields(_ c: CatalogConcept) -> [String] {
    [c.type, c.title ?? "", c.summary ?? "", c.resource ?? "", c.tags.joined(separator: "|"),
     c.timestamp.map(Frontmatter.dateText) ?? "", c.icon ?? "", c.color ?? "",
     c.deleted.map(Frontmatter.dateText) ?? "", c.body]
}

func fields(_ c: OKFConcept) -> [String] {
    [c.type, c.title ?? "", c.summary ?? "", c.resourceRef?.raw ?? "", c.tags.joined(separator: "|"),
     c.timestamp.map(Frontmatter.dateText) ?? "", c.icon ?? "", c.color ?? "",
     c.deletedAt.map(Frontmatter.dateText) ?? "", c.body]
}

/// Both readings of the same files agree. With no tree to follow, files of
/// the same age come in an order OKFFormat leaves to chance: compared as sets.
func compare(_ name: String, catalog text: String?, items: [String: String], trashed: [String: String]) {
    let ours = Catalog(catalog: text, items: items, trashed: trashed)
    let theirs = OKFCatalog.parse(catalogText: text, itemFiles: items, trashFiles: trashed)
    check(ours.title == theirs.title, "\(name): title \(ours.title) ≠ \(theirs.title)")
    check(ours.style == (theirs.style ?? [:]), "\(name): style \(ours.style) ≠ \(theirs.style ?? [:])")
    var (a, b) = (shape(ours.root.children), shape(theirs.outline))
    if text == nil { (a, b) = (a.sorted(), b.sorted()) }
    check(a == b, "\(name): tree\n  Search:    \(a)\n  OKFFormat: \(b)")
    let (ta, tb) = (shape(ours.trash.children), shape(theirs.trash))
    check(ta == tb, "\(name): trash\n  Search:    \(ta)\n  OKFFormat: \(tb)")
    let mine = Dictionary((ours.root.concepts + ours.trash.concepts).map { ($0.id, fields($0)) }) { a, _ in a }
    let other = Dictionary((theirs.outline + theirs.trash).allFileConcepts.map { ($0.id, fields($0)) }) { a, _ in a }
    check(Set(mine.keys) == Set(other.keys), "\(name): concepts \(Set(mine.keys).symmetricDifference(other.keys))")
    for (id, value) in mine where other[id] != nil {
        check(value == other[id]!, "\(name): \(id)\n  Search:    \(value)\n  OKFFormat: \(other[id]!)")
    }
}

/// What Search writes, OKFFormat reads as Search meant it.
func roundTrip(_ name: String, _ catalog: Catalog) {
    let out = catalog.output(onlyChanged: false)
    var items: [String: String] = [:]
    var trashed: [String: String] = [:]
    for (path, text) in out.files {
        if path.hasPrefix("trash/") { trashed[String(path.dropFirst(6))] = text } else { items[path] = text }
    }
    compare("\(name), as Search wrote it", catalog: out.catalog, items: items, trashed: trashed)
    let again = Catalog(catalog: out.catalog, items: items, trashed: trashed)
    check(shape(again.root.children) == shape(catalog.root.children), "\(name): Search doesn't read back its own tree")

    // And what OKFFormat writes from that, Search reads the same.
    let theirs = OKFCatalog.parse(catalogText: out.catalog, itemFiles: items, trashFiles: trashed).serializeBundle()
    compare("\(name), as OKFFormat wrote it", catalog: theirs.catalogText, items: theirs.itemFiles, trashed: theirs.trashFiles)
}

// MARK: - Catalogs

let catalogText = """
---
type: Catalog
title: Reading
fontSize: "22"
theme: system
---

# Reading

- [From Browser](items/s1.md)
  - [Hacker News](items/hn.md)
- Basic Stuff
  - [swiftpackageindex.com](items/spi.md)
  - items/gone.md
  - [Jane](items/jane.md)
- [Reading List](items/s2.md)
  - [anything](items/spi.md)

## Trash

- [Old](items/old.md)
"""

let items: [String: String] = [
    "items/s1.md": "---\ntype: Section\ntitle: From Browser\nicon: star\ncolor: yellow\n---",
    "items/s2.md": "---\ntype: Section\ntitle: Reading List\n---",
    "items/hn.md": "---\ntype: Website\ntitle: Hacker News\ndescription: Links for the curious\nresource: \"https://news.ycombinator.com\"\ntags: [tech, news]\ntimestamp: \"2026-07-01T12:00:00Z\"\n---",
    "items/spi.md": "---\ntype: Website\nresource: \"https://swiftpackageindex.com/nodes-app/swift-markdown-engine\"\n---",
    "items/jane.md": "---\ntype: Person\ntitle: Jane Smith\nemail: [jane@rustyflagon.example]\naddress:\n    addressLocality: Evermore\n    postalCode: 94016\ngivenName: Jane\n---\n\nJane has run The Rusty Flagon for thirty years.",
    "items/loose.md": "---\ntype: Website\nresource: \"https://loose.example\"\ntimestamp: \"2026-08-01T00:00:00Z\"\n---",
    "items/v2.md": "---\ntype: Note\ntitle: Newer\ngenerated:\n  at: \"2026-05-01T10:00:00Z\"\n  by: \"human:jason\"\n---\nNotes.",
    // A generated: block that doesn't say who: not OKF 0.2's, and no time.
    "items/v2b.md": "---\ntype: Note\ntitle: Unsigned\ngenerated:\n  at: \"2026-05-01T10:00:00Z\"\n---\nNotes.",
]
let trashed = ["items/old.md": "---\ntype: Website\ntitle: Old\nresource: \"https://old.example\"\ndeleted: \"2026-01-01T00:00:00Z\"\n---"]

compare("the Surfboard app's catalog", catalog: catalogText, items: items, trashed: trashed)
compare("no _catalog.md", catalog: nil, items: items, trashed: trashed)

// Edited in Search: renamed, thrown away, brought back, and added to with
// titles and notes that need quoting.
let edited = Catalog(catalog: catalogText, items: items, trashed: trashed)
edited.change(id: "items/spi.md") { $0.title = "Swift Package Index: \"the\" [place]" }
edited.throwAway(edited.root.children[0].children[0], at: Frontmatter.date("2026-10-01T00:00:00Z")!)
edited.restore(edited.trash.children.last!)
var added = CatalogConcept.new(type: CatalogConcept.websiteType, title: "#1 — yes: no?", resource: "https://example.com/a?b=c#d")
added.summary = "Line one\nline two"
added.tags = ["a, b", "true", "42"]
added.body = "Some **notes**.\n\n- a list"
edited.root.children[1].append(CatalogNode(concept: added))
edited.root.append(CatalogNode(section: "A section, only text"))
edited.root.children.last!.append(CatalogNode(concept: .new(type: "Place", title: "Somewhere")))
roundTrip("an edited catalog", edited)
roundTrip("the Surfboard app's catalog", Catalog(catalog: catalogText, items: items, trashed: trashed))

// Bundles on disk.
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let folder = try? FileWrapper(url: url) else { print("✗ can't read \(path)"); failures += 1; continue }
    let catalog = Catalog(bundle: folder)
    var items: [String: String] = [:]
    var trashed: [String: String] = [:]
    let hasItems = folder.fileWrappers?["items"]?.isDirectory == true
    for (file, wrapper) in Catalog.files(in: folder) where file.hasSuffix(".md") {
        guard !Catalog.reserved.contains((file as NSString).lastPathComponent),
              let text = wrapper.regularFileContents.flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
        if file.hasPrefix("trash/") {
            let inside = String(file.dropFirst(6))
            trashed[!inside.contains("/") && hasItems ? "items/\(inside)" : inside] = text
        } else {
            items[file] = text
        }
    }
    let text = folder.fileWrappers?[Catalog.catalogFile]?.regularFileContents.flatMap { String(data: $0, encoding: .utf8) }
        ?? folder.fileWrappers?[Catalog.indexFile]?.regularFileContents.flatMap { String(data: $0, encoding: .utf8) }
    compare(url.lastPathComponent, catalog: text, items: items, trashed: trashed)
    roundTrip(url.lastPathComponent, catalog)
}

print(failures == 0 ? "✓ Search and OKFFormat agree" : "\(failures) disagreement(s)")
exit(failures == 0 ? 0 : 1)
