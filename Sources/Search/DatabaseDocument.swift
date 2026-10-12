import AppKit
import SQLite3

// A SQLite database, read: its tables and views down the side, the rows of
// the one chosen beside them (see TabContent.swift).
//
// Read only. The file is opened read-only, queries only, and nothing the
// schema asks for trusted, so a database from anywhere can be looked at
// without it doing anything. A database another app holds
// locked — a browser's history, a running app's store — is read from a copy
// taken a moment ago instead, and says so.
//
// Rows are read a page at a time as they scroll into view, so a table of
// millions costs what is on screen.

final class DatabaseDocument: NSDocument, TabContent, NSTableViewDataSource, NSTableViewDelegate {
    private var db: OpaquePointer?
    /// Where the copy is, when the file itself couldn't be opened.
    private var copy: URL?

    private struct Table { let name: String; let isView: Bool; var count: Int? }
    private var tables: [Table] = []
    private var chosen: Int?
    private var columns: [String] = []
    /// Pages of rows, by page number.
    private var pages: [Int: [[Cell]]] = [:]
    private static let pageSize = 200

    private enum Cell {
        case null, integer(Int64), real(Double), text(String), blob(Int)
    }

    private let split = NSSplitView()
    private let sidebar = NSTableView()
    private let sideScroll = NSScrollView()
    private let grid = NSTableView()
    private let gridScroll = NSScrollView()
    private let note = NSTextField(labelWithString: "")

    var onDirty: ((Bool) -> Void)?
    var onLink: ((URL) -> Void)?
    var isReading: Bool { false }
    var view: NSView { split }
    var focus: NSView { grid }

    /// What the assistant is given: the schema, not the rows in it.
    var text: String? {
        guard let db else { return nil }
        var lines: [String] = []
        each(db, "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type DESC, name") { statement in
            if let sql = sqlite3_column_text(statement, 0) { lines.append(String(cString: sql) + ";") }
        }
        return lines.joined(separator: "\n\n")
    }

    override init() {
        super.init()
        let name = NSTableColumn(identifier: .init("table"))
        name.title = "Tables"
        sidebar.addTableColumn(name)
        sidebar.headerView = nil
        sidebar.style = .inset
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false

        grid.usesAlternatingRowBackgroundColors = true
        grid.style = .fullWidth
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.allowsColumnReordering = false
        grid.allowsMultipleSelection = true
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.dataSource = self
        grid.delegate = self
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.allowsMagnification = true
        gridScroll.minMagnification = 0.4
        gridScroll.maxMagnification = 3

        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.lineBreakMode = .byTruncatingMiddle
        // The side's own ground, under the list and the note alike.
        let side = NSBox()
        side.boxType = .custom
        side.borderWidth = 0
        side.contentViewMargins = .zero
        side.fillColor = .windowBackgroundColor
        let inside = NSView()
        side.contentView = inside
        for view in [sideScroll, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            inside.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sideScroll.topAnchor.constraint(equalTo: inside.topAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: inside.leadingAnchor),
            sideScroll.trailingAnchor.constraint(equalTo: inside.trailingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -6),
            note.leadingAnchor.constraint(equalTo: inside.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: inside.trailingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: inside.bottomAnchor, constant: -8),
        ])
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(side)
        split.addArrangedSubview(gridScroll)
        side.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        side.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { false }
    override class func isNativeType(_ type: String) -> Bool { true }
    /// Nothing is ever written back.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [] }
    override var windowForSheet: NSWindow? { split.window ?? NSApp.keyWindow }

    /// Opened where it is, never read into memory whole.
    override func read(from url: URL, ofType typeName: String) throws {
        shut()
        db = try open(url)
        loadTables()
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.fileWriteNoPermission)
    }

    override func close() {
        NSFileCoordinator.removeFilePresenter(self)
        shut()
        super.close()
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        NSPrintOperation(view: grid, printInfo: printInfo)
    }

    /// Another app wrote to it: what is shown is read again, the same table
    /// still chosen. Often, for a database in use, so at most once a second.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            guard let self, !refreshing else { return }
            refreshing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                refreshing = false
                guard let fileURL, let name = chosen.map({ self.tables[$0].name }) else { return }
                try? read(from: fileURL, ofType: fileType ?? "")
                if let again = tables.firstIndex(where: { $0.name == name }) { choose(again) }
            }
        }
    }
    private var refreshing = false

    // MARK: - opening

    private func open(_ url: URL) throws -> OpaquePointer {
        if let db = try? connect(url.path) {
            copy = nil
            return db
        }
        // Held by another app: a copy of it, its journal beside it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Search-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let into = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: into)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: into.path + suffix))
            }
        }
        copy = folder
        return try connect(into.path)
    }

    private func connect(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't be opened"
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedFailureReasonErrorKey: message])
        }
        // Looked at, never run: no writing, no trusting what the schema
        // asks for, nothing that could change the file or reach outside it.
        sqlite3_busy_timeout(db, 200)
        sqlite3_exec(db, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF;", nil, nil, nil)
        // A file that only looks like a database fails here, not later.
        var check: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &check, nil) == SQLITE_OK
            && sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard ok else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedFailureReasonErrorKey: message])
        }
        return db
    }

    private func shut() {
        if let db { sqlite3_close(db) }
        db = nil
        if let copy { try? FileManager.default.removeItem(at: copy) }
        copy = nil
    }

    // MARK: - reading

    private func loadTables() {
        tables = []
        guard let db else { return }
        each(db, "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name COLLATE NOCASE") { statement in
            guard let name = sqlite3_column_text(statement, 0), let type = sqlite3_column_text(statement, 1) else { return }
            tables.append(Table(name: String(cString: name), isView: String(cString: type) == "view", count: nil))
        }
        for index in tables.indices where !tables[index].isView {
            tables[index].count = count(tables[index].name)
        }
        let views = tables.filter(\.isView).count, plain = tables.count - views
        var counted = ["\(plain) \(plain == 1 ? "table" : "tables")"]
        if views > 0 { counted.append("\(views) \(views == 1 ? "view" : "views")") }
        note.stringValue = copy == nil
            ? counted.joined(separator: ", ") + " · read only"
            : "In use by another app: a copy from \(Date().formatted(date: .omitted, time: .shortened))"
        sidebar.reloadData()
        chosen = nil
        columns = []
        pages = [:]
        rebuildColumns()
        if !tables.isEmpty { choose(0) }
    }

    private func count(_ table: String) -> Int? {
        guard let db else { return nil }
        var result: Int?
        each(db, "SELECT count(*) FROM \(quoted(table))") { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    private func choose(_ index: Int) {
        guard tables.indices.contains(index), let db else { return }
        chosen = index
        pages = [:]
        columns = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT * FROM \(quoted(tables[index].name)) LIMIT 0", -1, &statement, nil) == SQLITE_OK {
            columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        }
        sqlite3_finalize(statement)
        // A view is counted only when chosen: it may be slow to run.
        if tables[index].count == nil { tables[index].count = count(tables[index].name) }
        rebuildColumns()
        grid.reloadData()
        grid.scrollRowToVisible(0)
        if sidebar.selectedRow != index { sidebar.selectRowIndexes([index], byExtendingSelection: false) }
        sidebar.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }

    private func rebuildColumns() {
        for column in grid.tableColumns { grid.removeTableColumn(column) }
        // Each as wide as its name and the first page of what is in it
        // need, within reason: an id narrow, an email wide.
        let sample = columns.isEmpty ? [] : (pages[0] ?? fetch(0))
        if !columns.isEmpty { pages[0] = sample }
        let font = NSFont.systemFont(ofSize: 12)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        for (index, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init("c\(index)"))
            column.title = name
            let widest = sample.prefix(100).reduce(width(name) + 12) { widest, row in
                guard index < row.count else { return widest }
                let text: String = switch row[index] {
                case .null: "NULL"
                case .integer(let value): "\(value)"
                case .real(let value): "\(value)"
                case .text(let value): value
                case .blob: "‹2.0 KB of data›"
                }
                return max(widest, width(text))
            }
            column.width = min(max(widest + 16, 48), 360)
            column.minWidth = 40
            grid.addTableColumn(column)
        }
    }

    private func row(_ index: Int) -> [Cell]? {
        let page = index / Self.pageSize
        if pages[page] == nil { pages[page] = fetch(page) }
        let rows = pages[page] ?? []
        let at = index % Self.pageSize
        return at < rows.count ? rows[at] : nil
    }

    private func fetch(_ page: Int) -> [[Cell]] {
        guard let db, let chosen else { return [] }
        let table = tables[chosen]
        // In the table's own order, so a page is the same rows each time.
        let order = table.isView ? "" : " ORDER BY rowid"
        var rows: [[Cell]] = []
        var statement: OpaquePointer?
        let sql = "SELECT * FROM \(quoted(table.name))\(order) LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)"
        // A table WITHOUT ROWID has no rowid to order by: as it stands, then.
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            let plain = "SELECT * FROM \(quoted(table.name)) LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)"
            guard sqlite3_prepare_v2(db, plain, -1, &statement, nil) == SQLITE_OK else { return [] }
        }
        defer { sqlite3_finalize(statement) }
        let width = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<width).map { cell(statement, $0) })
        }
        return rows
    }

    private func cell(_ statement: OpaquePointer?, _ column: Int32) -> Cell {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(statement, column)))
        default:
            guard let text = sqlite3_column_text(statement, column) else { return .null }
            // A long text is shown by its start: a cell is one line.
            let full = String(cString: text)
            return .text(full.count > 300 ? String(full.prefix(300)) + "…" : full)
        }
    }

    private func each(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    /// A name as SQL reads it, whatever is in it.
    private func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sidebar { return tables.count }
        guard let chosen else { return 0 }
        return tables[chosen].count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier(tableView === sidebar ? "dbTable" : "dbCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        guard let field = cell.textField else { return cell }

        if tableView === sidebar {
            let table = tables[row]
            let count = table.count.map { " \u{2009}\($0.formatted())" } ?? ""
            let text = NSMutableAttributedString(string: table.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            ])
            text.append(NSAttributedString(string: table.isView ? "  view" : count, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            field.attributedStringValue = text
            return cell
        }

        guard let column = tableColumn, let index = Int(column.identifier.rawValue.dropFirst()),
              let values = self.row(row), index < values.count else {
            field.stringValue = ""
            return cell
        }
        field.alignment = .left
        field.textColor = .labelColor
        field.font = .systemFont(ofSize: 12)
        switch values[index] {
        case .null:
            field.stringValue = "NULL"
            field.textColor = .tertiaryLabelColor
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .integer(let value):
            field.stringValue = "\(value)"
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .real(let value):
            field.stringValue = "\(value)"
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .text(let value):
            field.stringValue = value.replacingOccurrences(of: "\n", with: " ⏎ ")
        case .blob(let bytes):
            field.stringValue = "‹\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of data›"
            field.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === sidebar, sidebar.selectedRow >= 0, sidebar.selectedRow != chosen else { return }
        choose(sidebar.selectedRow)
    }

    // MARK: - TabContent

    var zoom: CGFloat {
        get { gridScroll.magnification }
        set { gridScroll.magnification = newValue }
    }

    func showFind() { NSSound.beep() }
    func setReading(_ on: Bool) -> Bool { false }

    /// For the bench and tests: the tables listed, and the rows of the one
    /// chosen as text, a row a line, cells by tabs.
    var listed: [String] { tables.map(\.name) }
    func show(table name: String) -> Bool {
        guard let index = tables.firstIndex(where: { $0.name == name }) else { return false }
        choose(index)
        return true
    }
    func rows(_ range: Range<Int>) -> [[String]] {
        range.compactMap { row($0) }.map { $0.map {
            switch $0 {
            case .null: "NULL"
            case .integer(let value): "\(value)"
            case .real(let value): "\(value)"
            case .text(let value): value
            case .blob(let bytes): "‹\(bytes) bytes›"
            }
        } }
    }
    var shownColumns: [String] { columns }
    var isCopy: Bool { copy != nil }
}
