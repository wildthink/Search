import XCTest
@testable import Search

/// Surfboard catalogs (Surfboard/Catalog.swift): reading one as the Surfboard
/// app writes it, writing back only what changed, the trash, and how long a
/// big one takes to open. Tests/OKFConformance checks the same writing
/// against OKFFormat itself.
final class CatalogTests: XCTestCase {
    /// A catalog the way the Surfboard app leaves one: sections with files of
    /// their own and one that is only a line, a site listed twice, a line
    /// naming a file that isn't there, a person whose frontmatter Search
    /// doesn't model, and the trash.
    static let catalog = """
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

    static let items: [String: String] = [
        "items/s1.md": "---\ntype: Section\ntitle: From Browser\nicon: star\ncolor: yellow\n---",
        "items/s2.md": "---\ntype: Section\ntitle: Reading List\n---",
        "items/hn.md": "---\ntype: Website\ntitle: Hacker News\ndescription: Links for the curious\nresource: \"https://news.ycombinator.com\"\ntags: [tech, news]\ntimestamp: \"2026-07-01T12:00:00Z\"\n---",
        "items/spi.md": "---\ntype: Website\nresource: \"https://swiftpackageindex.com/nodes-app/swift-markdown-engine\"\n---",
        "items/jane.md": """
        ---
        type: Person
        title: Jane Smith
        email: [jane@rustyflagon.example]
        address:
            addressLocality: Evermore
            postalCode: 94016
        givenName: Jane
        ---

        Jane has run The Rusty Flagon for thirty years.
        """,
        "items/loose.md": "---\ntype: Website\nresource: \"https://loose.example\"\ntimestamp: \"2026-08-01T00:00:00Z\"\n---",
    ]

    static let trashed: [String: String] = [
        "items/old.md": "---\ntype: Website\ntitle: Old\nresource: \"https://old.example\"\ndeleted: \"2026-01-01T00:00:00Z\"\n---",
    ]

    private func make() -> Catalog {
        Catalog(catalog: Self.catalog, items: Self.items, trashed: Self.trashed)
    }

    func testItReadsTheTreeAsTheSurfboardAppWroteIt() {
        let catalog = make()
        XCTAssertEqual(catalog.title, "Reading")
        XCTAssertEqual(catalog.style, ["fontSize": "22", "theme": "system"])
        let top = catalog.root.children
        XCTAssertEqual(top.map(\.title), ["From Browser", "Basic Stuff", "Reading List", "loose.example"],
                       "a file no line names is kept, at the end")
        XCTAssertTrue(top[0].isSection)
        XCTAssertEqual(top[0].concept?.icon, "star")
        XCTAssertEqual(top[0].children.map(\.title), ["Hacker News"])
        XCTAssertNil(top[1].concept, "a section that is only a line")
        XCTAssertEqual(top[1].children.map(\.title), ["swiftpackageindex.com", "items/gone.md", "Jane Smith"],
                       "the file's own title wins over the link's; a line naming no file reads as text")
        XCTAssertEqual(top[2].children.first?.concept?.id, "items/spi.md", "listed twice, shown twice")
        XCTAssertEqual(catalog.trash.children.map(\.title), ["Old"])
        XCTAssertNotNil(catalog.trash.children.first?.concept?.deleted)

        let hn = top[0].children[0].concept!
        XCTAssertEqual(hn.summary, "Links for the curious")
        XCTAssertEqual(hn.tags, ["tech", "news"])
        XCTAssertEqual(hn.url, URL(string: "https://news.ycombinator.com"))
        XCTAssertEqual(hn.timestamp, Frontmatter.date("2026-07-01T12:00:00Z"))
    }

    func testWhatItDoesNotModelIsWrittenBackAsItWas() {
        let jane = make().nodes(id: "items/jane.md")[0].concept!
        XCTAssertEqual(jane.type, "Person")
        XCTAssertEqual(jane.others.map(\.key), ["email", "address", "givenName"])
        let written = jane.markdown()
        XCTAssertTrue(written.contains("address:\n    addressLocality: Evermore\n    postalCode: 94016"), written)
        XCTAssertTrue(written.hasSuffix("\n\nJane has run The Rusty Flagon for thirty years."))
        XCTAssertEqual(CatalogConcept(id: jane.id, markdown: written), jane, "read back, the same")
    }

    func testOnlyWhatChangedIsWritten() {
        let catalog = make()
        let first = catalog.output()
        // Nothing read from a folder yet: every file is new to it.
        XCTAssertEqual(Set(first.files.keys), first.kept)
        catalog.saved(first)
        XCTAssertTrue(catalog.output().files.isEmpty, "saved, and nothing changed since")

        catalog.change(id: "items/spi.md") { $0.title = "Swift Package Index" }
        let next = catalog.output()
        XCTAssertEqual(Array(next.files.keys), ["items/spi.md"])
        XCTAssertTrue(next.catalog.contains("  - [Swift Package Index](items/spi.md)"))
        XCTAssertEqual(catalog.nodes(id: "items/spi.md").map(\.title), ["Swift Package Index", "Swift Package Index"],
                       "a change to a concept shows wherever it is listed")
    }

    func testTheTrashMovesFilesAndDecays() throws {
        let folder = FileWrapper(directoryWithFileWrappers: [:])
        let catalog = make()
        let first = catalog.output(onlyChanged: false)
        catalog.update(folder, with: first)
        catalog.saved(first)
        XCTAssertNotNil(read(folder, "trash/items/old.md"))
        XCTAssertNotNil(read(folder, "items/hn.md"))

        let hn = catalog.root.children[0].children[0]
        catalog.throwAway(hn)
        XCTAssertTrue(catalog.root.children[0].children.isEmpty)
        let thrown = catalog.output()
        XCTAssertEqual(Array(thrown.files.keys), ["trash/items/hn.md"])
        catalog.update(folder, with: thrown)
        catalog.saved(thrown)
        XCTAssertNil(read(folder, "items/hn.md"), "parked, not copied")
        XCTAssertTrue(read(folder, "trash/items/hn.md")?.contains("deleted: \"") == true)
        XCTAssertTrue(thrown.catalog.contains("## Trash\n\n- [Hacker News](items/hn.md)"), thrown.catalog)

        catalog.restore(hn)
        XCTAssertNil(hn.concept?.deleted)
        XCTAssertEqual(catalog.root.children.last?.title, "Hacker News", "to the end: where it was is gone")
        let back = catalog.output()
        catalog.update(folder, with: back)
        catalog.saved(back)
        XCTAssertNotNil(read(folder, "items/hn.md"))
        XCTAssertNil(read(folder, "trash/items/hn.md"))

        catalog.decay(before: Frontmatter.date("2026-02-01T00:00:00Z")!)
        XCTAssertTrue(catalog.trash.children.isEmpty, "in the trash since January")
        let decayed = catalog.output()
        catalog.update(folder, with: decayed)
        XCTAssertNil(read(folder, "trash/items/old.md"))
        XCTAssertFalse(decayed.catalog.contains("## Trash"))
    }

    func testAFolderReadsBackTheSameAndKeepsFilesItDoesNotUse() throws {
        let folder = FileWrapper(directoryWithFileWrappers: [:])
        let catalog = make()
        let out = catalog.output(onlyChanged: false)
        catalog.update(folder, with: out)
        folder.addRegularFile(withContents: Data("a picture".utf8), preferredFilename: "cover.png")
        // The way older catalogs parked a thrown-away file: flat in trash/.
        let trashFolder = folder.fileWrappers!["trash"]!
        trashFolder.removeFileWrapper(trashFolder.fileWrappers!["items"]!)
        trashFolder.addRegularFile(withContents: Data(Self.trashed["items/old.md"]!.utf8), preferredFilename: "old.md")

        let again = Catalog(bundle: folder)
        XCTAssertEqual(again.root.children.map(\.title), catalog.root.children.map(\.title))
        XCTAssertEqual(again.trash.children.first?.concept?.id, "items/old.md")
        let saved = again.output()
        XCTAssertEqual(Array(saved.files.keys), ["trash/items/old.md"], "moved to where it is parked now")
        again.update(folder, with: saved)
        XCTAssertNil(read(folder, "trash/old.md"))
        XCTAssertNotNil(read(folder, "cover.png"))
    }

    func testFrontmatterValues() {
        XCTAssertEqual(Frontmatter.scalar("https://a.example"), "\"https://a.example\"")
        XCTAssertEqual(Frontmatter.scalar("22"), "\"22\"")
        XCTAssertEqual(Frontmatter.scalar("plain words"), "plain words")
        XCTAssertEqual(Frontmatter.scalar("say \"hi\"\n"), "\"say \\\"hi\\\"\\n\"")
        XCTAssertEqual(Frontmatter.scalarValue("\"say \\\"hi\\\"\\n\""), "say \"hi\"\n")
        XCTAssertEqual(Frontmatter.scalarValue("'it''s'"), "it's")
        XCTAssertEqual(Frontmatter.scalarValue("value # a comment"), "value")
        XCTAssertEqual(Frontmatter.list(["tags: [a, \"b, c\", 'd']"]), ["a", "b, c", "d"])
        XCTAssertEqual(Frontmatter.list(["tags:", "  - one", "  - two"]), ["one", "two"])
        XCTAssertEqual(Frontmatter.value(["description: >", "  folded", "  lines"]), "folded lines")
        let concept = CatalogConcept(id: "items/x.md", markdown: "---\ntype: Note\ngenerated:\n  at: 2026-05-01T10:00:00Z\n  by: someone\n---\nbody")
        XCTAssertEqual(concept?.timestamp, Frontmatter.date("2026-05-01T10:00:00Z"), "OKF 0.2's time")
        XCTAssertNil(CatalogConcept(id: "items/x.md", markdown: "no frontmatter"))
    }

    /// The reason this isn't OKFFormat: a catalog of 1,000 sites, which
    /// OKFFormat took 1.2 s to read in a release build.
    func testAThousandSitesOpenQuickly() {
        var items: [String: String] = [:]
        var lines = ["---", "type: Catalog", "title: Big", "---", "", "# Big", ""]
        for s in 0..<20 {
            items["items/s\(s).md"] = "---\ntype: Section\ntitle: Section \(s)\n---\n"
            lines.append("- [Section \(s)](items/s\(s).md)")
            for i in 0..<50 {
                let id = "items/\(s)-\(i).md"
                items[id] = "---\ntype: Website\ntitle: Site \(s)-\(i)\ndescription: A site about things number \(i)\nresource: \"https://example.com/\(s)/\(i)\"\ntags: [a, b]\ntimestamp: \"2026-07-01T12:00:00Z\"\n---\n\nSome notes.\n"
                lines.append("  - [Site \(s)-\(i)](\(id))")
            }
        }
        let text = lines.joined(separator: "\n")
        let start = Date()
        let catalog = Catalog(catalog: text, items: items)
        let took = Date().timeIntervalSince(start)
        XCTAssertEqual(catalog.root.all.count - 1, 1_020)
        // A debug build, on any Mac the tests run on; a release build is
        // several times quicker.
        XCTAssertLessThan(took, 0.5, "took \(took) s")
    }

    private func read(_ folder: FileWrapper, _ path: String) -> String? {
        var at = folder
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            guard let next = at.fileWrappers?[part] else { return nil }
            at = next
        }
        return at.fileWrappers?[parts.last!]?.regularFileContents.flatMap { String(data: $0, encoding: .utf8) }
    }
}
