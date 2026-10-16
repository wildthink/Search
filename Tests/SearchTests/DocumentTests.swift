import AppKit
import XCTest
@testable import Search

/// A file opened as a document rather than a page (TabContent.swift): which
/// files are, what is read and written back, and the edited mark.
@MainActor
final class DocumentTests: XCTestCase {
    private var folder: URL!
    private var opened: [TabContent] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        opened.forEach { $0.close() }
        opened = []
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        try file(name, Array(text.utf8))
    }

    private func open(_ url: URL) throws -> TabContent {
        let document = try Documents.open(url)
        opened.append(document)
        return document
    }

    func testTextFilesAreDocumentsAndPagesAreNot() {
        let local = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
        for name in ["notes.md", "notes.markdown", "data.json", "readme.txt"] {
            XCTAssertTrue(Documents.handles(local(name)), name)
        }
        for name in ["page.html", "page.xhtml", "drawing.svg", "feed.xml", "paper.pdf", "photo.png", "noextension"] {
            XCTAssertFalse(Documents.handles(local(name)), name)
        }
        XCTAssertFalse(Documents.handles(URL(string: "https://example.com/notes.md")!), "a page on the web stays a page")
        XCTAssertFalse(Documents.handles(URL(fileURLWithPath: "/tmp/folder.md/", isDirectory: true)), "a folder is not a file")
    }

    func testReadsTheFileAndWritesItBackUnchanged() throws {
        let url = try file("notes.md", "# Notes\n\nCafé ☕︎\n")
        let document = try open(url)
        XCTAssertEqual(document.text, "# Notes\n\nCafé ☕︎\n")
        XCTAssertEqual(document.url.standardizedFileURL, url.standardizedFileURL)
        XCTAssertFalse(document.dirty)
        XCTAssertEqual(try document.data(ofType: document.fileType ?? ""), try Data(contentsOf: url))
    }

    func testAFileThatIsNotUTF8IsWrittenBackInItsOwnEncoding() throws {
        // "café" in Latin-1: é is one byte, 0xE9, which is not UTF-8.
        let url = try file("latin.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A])
        let document = try open(url)
        XCTAssertEqual(document.text, "café\n")
        XCTAssertEqual(try document.data(ofType: document.fileType ?? ""), Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
    }

    func testTheEditedMarkFollowsTheChangeCountAndIsTold() throws {
        let document = try open(try file("notes.md", "# Notes\n"))
        var told: [Bool] = []
        document.onDirty = { told.append($0) }
        document.updateChangeCount(.changeDone)
        XCTAssertTrue(document.dirty)
        document.updateChangeCount(.changeUndone)
        XCTAssertFalse(document.dirty)
        XCTAssertEqual(told, [true, false])
    }

    func testSaveWritesWhatIsInTheViewAndClearsTheMark() throws {
        let url = try file("notes.md", "# Notes\n")
        let document = try open(url)
        // Markdown opens to read; its source is where typing goes.
        XCTAssertTrue(document.setReading(false))
        let editor = try XCTUnwrap(document.focus as? NSTextView)
        editor.string = "# Notes\nmore\n"
        document.updateChangeCount(.changeDone)

        let saved = expectation(description: "saved")
        document.save { ok in
            XCTAssertTrue(ok)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Notes\nmore\n")
        XCTAssertFalse(document.dirty)
    }

    func testRevertReadsTheFileAgainAndForgetsTheChanges() throws {
        let url = try file("data.json", "{}\n")
        let document = try open(url)
        (document.focus as? NSTextView)?.string = "{\"typed\": true}\n"
        document.updateChangeCount(.changeDone)
        try "{\"elsewhere\": 1}\n".write(to: url, atomically: true, encoding: .utf8)

        try document.revert()
        XCTAssertEqual(document.text, "{\"elsewhere\": 1}\n")
        XCTAssertFalse(document.dirty)
    }

    // MARK: - Markdown, read as it renders

    func testMarkdownAndJSONOpenToReadAndPlainTextDoesNot() throws {
        let markdown = try open(try file("notes.md", "# Notes\n"))
        XCTAssertTrue(markdown.isReading)
        XCTAssertTrue(markdown.setReading(false))
        XCTAssertFalse(markdown.isReading)

        let json = try open(try file("data.json", "{}\n"))
        XCTAssertTrue(json.isReading, "JSON opens as a tree")
        XCTAssertTrue(json.focus is NSOutlineView)

        let text = try open(try file("readme.txt", "plain\n"))
        XCTAssertFalse(text.isReading)
        XCTAssertFalse(text.setReading(true), "plain text has only its source")
        XCTAssertFalse(text.isReading)
    }

    // MARK: - JSON, read as a tree

    func testJSONShowsItsKeysAndSaysWhatEachBranchHolds() {
        let tree = JSONTree()
        tree.show(#"{"user": {"name": "Ada", "tags": ["a", "b"], "admin": true, "age": 36, "note": null}}"#)
        let outline = tree.outline
        // The top level open: user and what is in it.
        let user = outline.item(atRow: 0) as? JSONTree.Node
        XCTAssertEqual(user?.key, "user")
        XCTAssertEqual(user?.summary, "{ 5 keys }")
        XCTAssertTrue(outline.isItemExpanded(user))
        let rows = (1..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? JSONTree.Node }
        XCTAssertEqual(rows.map(\.key), ["name", "tags", "admin", "age", "note"], "in the file's order")
        XCTAssertEqual(rows.map(\.summary), ["“Ada”", "[ 2 items ]", "true", "36", "null"])

        let tags = rows[1]
        outline.expandItem(tags)
        let second = outline.child(1, ofItem: tags) as! JSONTree.Node
        XCTAssertEqual(tree.path(to: second), "user.tags[1]")
    }

    func testJSONThatIsNotValidSaysSoInsteadOfAHalfTree() {
        let tree = JSONTree()
        tree.show(#"{"user": "#)
        XCTAssertEqual(tree.outline.numberOfRows, 0)
        XCTAssertTrue(tree.outline.isHidden)
    }

    func testTheTreeKeepsWhatWasOpenWhenTheSourceChanges() {
        let tree = JSONTree()
        tree.show(#"{"a": {"b": {"c": 1}}}"#)
        let a = tree.outline.item(atRow: 0)
        let b = tree.outline.child(0, ofItem: a)
        tree.outline.expandItem(b)
        XCTAssertEqual(tree.outline.numberOfRows, 3)
        tree.show(#"{"a": {"b": {"c": 2, "d": 3}}}"#)
        XCTAssertEqual(tree.outline.numberOfRows, 4, "a and b still open, with b's new key")
    }

    func testMarkdownRendersItsBlocksAndKeepsItsLinks() {
        let source = "# Title\n\nSome **bold** text and a [link](other.md).\n\n- one\n- two\n\n1. first\n2. second\n"
        let base = URL(fileURLWithPath: "/tmp/docs/notes.md")
        let rendered = MarkdownRender.attributed(source, base: base)
        let text = rendered.string

        XCTAssertTrue(text.hasPrefix("Title\n"), "the heading's # is markup, not text")
        XCTAssertTrue(text.contains("•\tone"))
        XCTAssertTrue(text.contains("•\ttwo"))
        XCTAssertTrue(text.contains("1.\tfirst"))
        XCTAssertTrue(text.contains("2.\tsecond"))
        XCTAssertFalse(text.contains("**"))

        let heading = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let body = rendered.attribute(.font, at: (text as NSString).range(of: "Some").location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(heading?.pointSize ?? 0, body?.pointSize ?? .infinity)

        let link = rendered.attribute(.link, at: (text as NSString).range(of: "link").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteURL.path, "/tmp/docs/other.md", "a relative link is beside the file")
    }

    func testALinkClickedGoesToTheBrowserButOneToTheSameFileDoesNot() throws {
        let url = try file("notes.md", "[other](other.md) and [here](#top)\n")
        let document = try XCTUnwrap(try open(url) as? TextDocument)
        var opened: [URL] = []
        document.onLink = { opened.append($0) }
        let view = NSTextView()

        XCTAssertTrue(document.textView(view, clickedOnLink: URL(string: "https://example.com")!, at: 0))
        XCTAssertTrue(document.textView(view, clickedOnLink: folder.appendingPathComponent("other.md"), at: 0))
        XCTAssertTrue(document.textView(view, clickedOnLink: URL(string: "#top", relativeTo: url)!, at: 0))
        XCTAssertEqual(opened.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }, ["https://example.com", "other.md"])
    }

    // MARK: - large files

    func testATextFilePastTheLimitOpensToReadOnly() throws {
        let url = folder.appendingPathComponent("big.md")
        let line = Data("# heading and a line of text to fill the file\n".utf8)
        var data = Data()
        while data.count <= TextDocument.largest { data.append(line) }
        try data.write(to: url)

        let document = try XCTUnwrap(try open(url) as? TextDocument)
        XCTAssertTrue(document.isLarge)
        XCTAssertFalse(document.isReading, "not rendered: its source, to read")
        XCTAssertFalse(document.setReading(true))
        let editor = try XCTUnwrap(document.focus as? NSTextView)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(document.writableTypes(for: .saveOperation), [])
        XCTAssertEqual(document.text?.utf8.count, data.count)
    }

    func testATextFilePastTheCeilingStaysAPage() throws {
        // Sparse: as big as it says, without the disk writing it.
        let url = folder.appendingPathComponent("huge.log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(TextDocument.ceiling + 1))
        try handle.close()
        XCTAssertFalse(Documents.handles(url))
        let small = try file("small.txt", "small\n")
        XCTAssertTrue(Documents.handles(small))
    }

    // MARK: - spreadsheets, shown by Quick Look

    func testSpreadsheetsAreShownByQuickLookAndNeverWritten() throws {
        for name in ["sales.xlsx", "old.xls", "plan.numbers", "open.ods"] {
            XCTAssertTrue(Documents.handles(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        XCTAssertTrue(Documents.handles(URL(fileURLWithPath: "/tmp/table.csv")), "CSV opens too — as text, edited as text")

        let url = try file("sales.xlsx", [0x50, 0x4B, 0x03, 0x04])
        let before = try Data(contentsOf: url)
        let document = try XCTUnwrap(try open(url) as? PreviewDocument)
        XCTAssertEqual(document.previewing?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertFalse(document.dirty)
        XCTAssertFalse(document.setReading(true))
        XCTAssertNil(document.text, "nothing of it goes to the assistant")
        XCTAssertThrowsError(try document.data(ofType: document.fileType ?? ""))
        let saved = expectation(description: "saved")
        document.save { ok in
            XCTAssertTrue(ok)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
