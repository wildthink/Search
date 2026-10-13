import XCTest
@testable import Search

final class CatalogDocumentTests: XCTestCase {
    func testAChangeMarksTheDocumentEditedAndUndoingClearsIt() {
        let document = CatalogDocument()
        let node = CatalogNode(concept: .new(type: CatalogConcept.websiteType, resource: "https://a.example"))
        document.change("Add") { document.catalog.root.append(node) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(document.isDocumentEdited)
        document.undoManager?.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(document.catalog.root.children.isEmpty)
    }
}

extension CatalogDocumentTests {
    /// Made with no event around it — a menu, a drop, the bench — a change
    /// counts at once, not when the next key ends the event's undo group.
    /// No key or click comes after it here, only the run loop going round
    /// as it does between them.
    func testAChangeCountsWithoutAnEvent() {
        let document = CatalogDocument()
        let turn = { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        document.change("Add") { document.catalog.root.append(CatalogNode(section: "A")) }
        turn()
        XCTAssertTrue(document.isDocumentEdited)
        document.undoManager?.undo()
        turn()
        XCTAssertFalse(document.isDocumentEdited)
        document.undoManager?.redo()
        turn()
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(document.catalog.root.children.map(\.title), ["A"])
    }
}
