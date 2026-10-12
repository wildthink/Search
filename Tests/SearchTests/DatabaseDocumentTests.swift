import AppKit
import SQLite3
import XCTest
@testable import Search

/// A SQLite database opened in a tab (DatabaseDocument.swift): which files
/// are, what is read, that nothing is ever written, and a locked one read
/// from a copy.
@MainActor
final class DatabaseDocumentTests: XCTestCase {
    private var folder: URL!
    private var opened: [TabContent] = []
    private var held: [OpaquePointer] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DatabaseDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        opened.forEach { $0.close() }
        opened = []
        held.forEach { sqlite3_close($0) }
        held = []
        try? FileManager.default.removeItem(at: folder)
    }

    /// A database made with `sql`, at `name` in the test's folder.
    private func database(_ name: String, _ sql: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            XCTFail(error.map { String(cString: $0) } ?? "sql failed")
        }
        return url
    }

    private func open(_ url: URL) throws -> DatabaseDocument {
        let document = try Documents.open(url)
        opened.append(document)
        return try XCTUnwrap(document as? DatabaseDocument)
    }

    private let people = """
        CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, height REAL, photo BLOB, note TEXT);
        INSERT INTO people VALUES (1, 'Ada', 1.65, x'00010203', NULL);
        INSERT INTO people VALUES (2, 'Grace', 1.7, NULL, 'line one
        line two');
        CREATE VIEW tall AS SELECT name FROM people WHERE height > 1.68;
        """

    func testADatabaseIsKnownByItsNameAndItsFirstBytes() throws {
        let real = try database("store.db", "CREATE TABLE t (x);")
        XCTAssertTrue(Documents.isDatabase(real))
        XCTAssertTrue(Documents.handles(real))

        let pretender = folder.appendingPathComponent("notes.db")
        try "not a database".write(to: pretender, atomically: true, encoding: .utf8)
        XCTAssertFalse(Documents.isDatabase(pretender), ".db is many things")

        let renamed = folder.appendingPathComponent("store.bin")
        try FileManager.default.copyItem(at: real, to: renamed)
        XCTAssertFalse(Documents.isDatabase(renamed), "a database by its bytes but not its name stays a download")
    }

    func testTablesAndViewsAreListedWithTheirRows() throws {
        let document = try open(try database("people.sqlite", people))
        XCTAssertEqual(document.listed, ["people", "tall"], "tables, then views")
        XCTAssertEqual(document.shownColumns, ["id", "name", "height", "photo", "note"])
        XCTAssertEqual(document.rows(0..<2), [
            ["1", "Ada", "1.65", "‹4 bytes›", "NULL"],
            ["2", "Grace", "1.7", "NULL", "line one\nline two"],
        ])
        XCTAssertTrue(document.show(table: "tall"))
        XCTAssertEqual(document.rows(0..<1), [["Grace"]])
        XCTAssertFalse(document.isCopy)
        XCTAssertFalse(document.dirty)
    }

    func testRowsPastTheFirstPageAreThereAndInOrder() throws {
        let url = try database("many.sqlite", """
            CREATE TABLE n (v INTEGER);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 450) INSERT INTO n SELECT x FROM c;
            """)
        let document = try open(url)
        XCTAssertEqual(document.rows(0..<1), [["1"]])
        XCTAssertEqual(document.rows(199..<202), [["200"], ["201"], ["202"]], "across a page")
        XCTAssertEqual(document.rows(449..<452), [["450"]], "and no further than there are")
    }

    func testNamesThatNeedQuotingAndTablesWithoutRowidsAreRead() throws {
        let url = try database("odd.sqlite", """
            CREATE TABLE "my ""odd"" table" (k TEXT PRIMARY KEY, v) WITHOUT ROWID;
            INSERT INTO "my ""odd"" table" VALUES ('a', 1), ('b', 2);
            """)
        let document = try open(url)
        XCTAssertEqual(document.listed, ["my \"odd\" table"])
        XCTAssertEqual(document.rows(0..<2), [["a", "1"], ["b", "2"]])
    }

    func testNothingIsEverWrittenBack() throws {
        let url = try database("people.sqlite", people)
        let before = try Data(contentsOf: url)
        let document = try open(url)
        let saved = expectation(description: "saved")
        document.save { ok in
            XCTAssertTrue(ok, "nothing to save is not a failure")
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertThrowsError(try document.data(ofType: "org.sqlite.sqlite3"))
        document.close()
        opened.removeAll()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testTheAssistantIsGivenTheSchemaNotTheRows() throws {
        let document = try open(try database("people.sqlite", people))
        let text = try XCTUnwrap(document.text)
        XCTAssertTrue(text.contains("CREATE TABLE people"))
        XCTAssertTrue(text.contains("CREATE VIEW tall"))
        XCTAssertFalse(text.contains("Grace"))
    }

    func testADatabaseHeldLockedByAnotherAppIsReadFromACopy() throws {
        let url = try database("locked.sqlite", people)
        // Another connection holding it exclusively, as a running app might.
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &other), SQLITE_OK)
        held.append(other!)
        XCTAssertEqual(sqlite3_exec(other, "PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        let document = try open(url)
        XCTAssertTrue(document.isCopy)
        XCTAssertEqual(document.listed, ["people", "tall"])
        XCTAssertEqual(document.rows(0..<1).first?.first, "1")
    }
}
