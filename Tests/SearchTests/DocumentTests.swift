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
}
