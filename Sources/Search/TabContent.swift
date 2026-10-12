import AppKit
import UniformTypeIdentifiers

// A tab that isn't a web page: a file on this Mac, shown in a view of
// Search's own, which can change it and put it back.
//
// A tab's page is lazy already — `Tab.built` is nil until someone asks, and
// nil again once the tab sleeps — so a tab that never builds one is a state
// the rest of the app has always had to live with. What a document adds is a
// view of its own for the stage, and something typed that mustn't be lost.
//
// Each kind is an NSDocument, which does what a file needs and a page never
// did: the write coordinated with every other app holding the file, a warning
// when the file changed underneath, the edited mark kept by the undo manager,
// and the file read again when another app changes it while nothing here has.
// Not autosaved in place: a file opened in a browser is usually being looked
// at, and is written only when you say so.
//
// Three kinds: text — Markdown, JSON, plain text — edited as text, with
// Markdown read as it renders (MarkdownRender.swift) and JSON as a tree
// (JSONTree.swift); SQLite databases, read only (DatabaseDocument.swift);
// and spreadsheets, shown by Quick Look (PreviewDocument.swift).

/// What a tab shows instead of a web page.
protocol TabContent: NSDocument {
    /// What goes on the stage where the page would be.
    var view: NSView { get }
    /// What should have the keyboard when the tab comes to the front.
    var focus: NSView { get }
    /// Told whenever the edited mark changes, so the tab can say so.
    var onDirty: ((Bool) -> Void)? { get set }
    /// Its text, for find, reading and the assistant — nil where it has none.
    var text: String? { get }
    /// ⌘F: its own way of finding, since Search's find bar searches pages.
    func showFind()
    /// ⌘+ and ⌘-: how big it is drawn, 1 for as it is.
    var zoom: CGFloat { get set }
    /// Showing the file as it reads — rendered Markdown — rather than as
    /// it is written.
    var isReading: Bool { get }
    /// ⇧⌘R: to the reading view or back to the source. False, and nothing
    /// changes, for a kind of file that has only the one.
    func setReading(_ on: Bool) -> Bool
    /// A link clicked in it, for the browser to open.
    var onLink: ((URL) -> Void)? { get set }
}

extension TabContent {
    /// The file, which is also the tab's address.
    var url: URL { fileURL ?? URL(fileURLWithPath: "/") }
    /// Changed since it was opened or last saved.
    var dirty: Bool { isDocumentEdited }

    /// Written back to its own file. `done` says whether it was; a failure
    /// has already been put in front of you.
    ///
    /// Through NSDocument's own Save, not its lower-level write: that is
    /// where it asks before writing over a file another app changed since,
    /// and where a failure is put up as a sheet on the tab's window.
    func save(then done: @escaping (Bool) -> Void) {
        // Nothing changed, nothing written: ⌘S on a document as it was
        // opened, or on one that can't be changed (a database).
        guard isDocumentEdited else { return done(true) }
        let saved = Saved { [weak self] ok in
            if let self { onDirty?(isDocumentEdited) }
            done(ok)
        }
        save(withDelegate: saved, didSave: #selector(Saved.document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    /// The file read again, whatever was typed since.
    func revert() throws {
        guard let fileURL, let fileType else { return }
        try revert(toContentsOf: fileURL, ofType: fileType)
        onDirty?(isDocumentEdited)
    }
}

/// NSDocument's Save answers a selector, not a closure: this holds the
/// closure until it does.
private final class Saved: NSObject {
    private static var waiting = Set<Saved>()
    private let done: (Bool) -> Void

    init(_ done: @escaping (Bool) -> Void) {
        self.done = done
        super.init()
        Saved.waiting.insert(self)
    }

    @objc func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Saved.waiting.remove(self)
        done(didSave)
    }
}

enum Documents {
    /// Files Search shows in a view of its own rather than handing to WebKit.
    /// HTML and its kin are pages, and stay WebKit's, as do SVG and PDF.
    static func handles(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        if isDatabase(url) { return true }
        guard let type = type(of: url) else { return false }
        if PreviewDocument.handles(type) { return true }
        if type.conforms(to: .html) || type.conforms(to: .svg) || type.conforms(to: .xml) { return false }
        guard type.conforms(to: .json) || type.conforms(to: .markdown) || type.conforms(to: .plainText) else { return false }
        // Text past what memory should hold at once stays WebKit's, as before.
        return (size(of: url) ?? 0) <= TextDocument.ceiling
    }

    /// The file's size in bytes, when it has one to tell.
    static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    static func open(_ url: URL) throws -> TabContent {
        let type = type(of: url)
        let document: TabContent = if isDatabase(url) {
            try DatabaseDocument(contentsOf: url, ofType: "org.sqlite.sqlite3")
        } else if let type, PreviewDocument.handles(type) {
            try PreviewDocument(contentsOf: url, ofType: type.identifier)
        } else {
            try TextDocument(contentsOf: url, ofType: (type ?? .plainText).identifier)
        }
        // Told when another app changes the file. A document with a window
        // of its own is put on the list by AppKit; one in a tab isn't.
        NSFileCoordinator.addFilePresenter(document)
        // Opened in a browser, Markdown and JSON are for reading first —
        // rendered, and as a tree; ⇧⌘R for the source.
        _ = document.setReading(true)
        return document
    }

    /// A SQLite database: named as one, and starting the way every one
    /// does. The system knows no type for them, and .db is many things.
    static func isDatabase(_ url: URL) -> Bool {
        guard ["sqlite", "sqlite3", "db", "db3", "s3db", "sl3"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\u{0}".utf8)
    }

    private static func type(of url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    /// The tab, in any window, already holding the file at `url` — one tab
    /// per file, so two editors never write over each other.
    @MainActor static func holder(of url: URL, except: Tab? = nil) -> (browser: Browser, tab: Tab)? {
        let wanted = url.standardizedFileURL.resolvingSymlinksInPath()
        for browser in Browsers.all where browser.extensionPopup == nil {
            if let tab = browser.tabs.first(where: {
                $0 !== except && $0.document?.url.standardizedFileURL.resolvingSymlinksInPath() == wanted
            }) { return (browser, tab) }
        }
        return nil
    }
}

private extension UTType {
    static let markdown = UTType("net.daringfireball.markdown") ?? .plainText
}

/// A text file, edited as text — Markdown read as it renders, and JSON as
/// a tree.
final class TextDocument: NSDocument, TabContent, NSTextViewDelegate {
    /// The stage's view: the source and, for Markdown and JSON, the reading
    /// view over it, one shown at a time.
    private let page = NSView()
    private let scroll = NSTextView.scrollableTextView()
    private let editor = DocumentTextView()
    private let reading = NSTextView.scrollableTextView()
    private var reader: NSTextView { reading.documentView as! NSTextView }
    private let tree = JSONTree()
    private(set) var isReading = false
    /// Too big to edit, or to render or draw as a tree, without the window
    /// stopping while it does: shown as its source, to read.
    private(set) var isLarge = false

    /// Past this a text file opens read-only (`isLarge`), past `ceiling` not
    /// at all: a log of a few hundred megabytes is WebKit's, as it was.
    static let largest = 20 << 20
    static let ceiling = 256 << 20

    /// What reading it means, by the kind of file.
    private enum Kind { case markdown, json, text }
    private var kind = Kind.text
    var onLink: ((URL) -> Void)?
    /// The file's own encoding, written back the way it was read.
    private var encoding: String.Encoding = .utf8

    var onDirty: ((Bool) -> Void)?

    var view: NSView { page }
    var focus: NSView { shown }
    /// The view on show, for the keyboard and print.
    private var shown: NSView {
        guard isReading else { return editor }
        return kind == .json ? tree.outline : reader
    }
    var text: String? { editor.string }

    override init() {
        super.init()
        // The scrollable view's own text view, swapped for one that undoes
        // with the document's undo manager (see DocumentTextView).
        let stock = scroll.documentView as! NSTextView
        editor.frame = stock.frame
        editor.minSize = stock.minSize
        editor.maxSize = stock.maxSize
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = stock.autoresizingMask
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 24, height: 20)
        editor.font = .systemFont(ofSize: 14)
        editor.delegate = self
        scroll.drawsBackground = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.4
        scroll.maxMagnification = 3

        reader.isEditable = false
        reader.isSelectable = true
        reader.usesFindBar = true
        reader.isIncrementalSearchingEnabled = true
        reader.textContainerInset = NSSize(width: 40, height: 28)
        reader.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        reader.delegate = self
        reading.drawsBackground = true
        reading.allowsMagnification = true
        reading.minMagnification = 0.4
        reading.maxMagnification = 3
        reading.isHidden = true

        tree.scroll.isHidden = true

        for each in [scroll, reading, tree.scroll] {
            each.frame = page.bounds
            each.autoresizingMask = [.width, .height]
            page.addSubview(each)
        }
    }

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { false }
    // Its types are whatever the file was, not ones the app declares.
    override class func isNativeType(_ type: String) -> Bool { true }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        isLarge ? [] : fileType.map { [$0] } ?? []
    }
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        fileURL?.pathExtension
    }

    /// Where NSDocument puts its questions: the window the tab is in.
    override var windowForSheet: NSWindow? { page.window ?? NSApp.keyWindow }

    override func read(from data: Data, ofType typeName: String) throws {
        let type = UTType(typeName)
        isLarge = data.count > TextDocument.largest
        kind = isLarge ? .text
            : type?.conforms(to: .json) == true ? .json
            : type?.conforms(to: .markdown) == true ? .markdown
            : .text
        // The view made ready before the text goes in: set afterwards, each
        // of these lays the whole file out again.
        editor.isEditable = !isLarge
        // Laid out as it is scrolled to, not all of it before it shows.
        editor.layoutManager?.allowsNonContiguousLayout = isLarge
        editor.font = type?.conforms(to: .json) == true || isLarge
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 14)
        // Not UTF-8: Latin-1 reads anything, which beats refusing the file,
        // and it is written back as Latin-1.
        if let text = String(data: data, encoding: .utf8) {
            encoding = .utf8
            editor.string = text
        } else {
            encoding = .isoLatin1
            editor.string = String(data: data, encoding: .isoLatin1) ?? ""
        }
        undoManager?.removeAllActions()
        // Read again — another app changed it, or Revert — and shown again.
        if isReading { render() }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = editor.string.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Typing after a save is a change of its own. Left coalesced into
        // the typing before it, it never closes an undo group, and the
        // document never learns it was edited again.
        editor.breakUndoCoalescing()
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func close() {
        NSFileCoordinator.removeFilePresenter(self)
        super.close()
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        onDirty?(isDocumentEdited)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        NSPrintOperation(view: shown, printInfo: printInfo)
    }

    /// Another app wrote the file. With nothing typed here, what it wrote is
    /// shown; with something typed, NSDocument asks at the next save.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            guard let self, !isDocumentEdited, let fileURL, let fileType,
                  let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date != fileModificationDate
            else { return }
            try? revert(toContentsOf: fileURL, ofType: fileType)
        }
    }

    // MARK: - NSTextViewDelegate

    /// The document's own undo manager, so every change typed is a change
    /// NSDocument counts — and undoing back to the saved text clears the mark.
    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    /// A link in the reading view goes to the browser, not to whichever app
    /// the system would pick: another .md beside it opens in Search too.
    /// One to a heading in this same file has nowhere else to go.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0, relativeTo: fileURL) }
        guard let url = url?.absoluteURL else { return true }
        if url.isFileURL, url.path == fileURL?.path { return true }
        onLink?(url)
        return true
    }

    // MARK: - TabContent

    var zoom: CGFloat {
        get { scroll.magnification }
        set {
            scroll.magnification = newValue
            reading.magnification = newValue
            tree.scroll.magnification = newValue
        }
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        // A tree has no find bar of its own: the source does.
        if isReading, kind == .json { _ = setReading(false) }
        guard let text = shown as? NSTextView else { return }
        text.window?.makeFirstResponder(text)
        text.performTextFinderAction(item)
    }

    func setReading(_ on: Bool) -> Bool {
        guard kind != .text else { return false }
        isReading = on
        // Rendered from what is in the editor, changes not yet saved included.
        if on { render() }
        reading.isHidden = !(on && kind == .markdown)
        tree.scroll.isHidden = !(on && kind == .json)
        scroll.isHidden = on
        if let window = page.window { window.makeFirstResponder(shown) }
        return true
    }

    private func render() {
        switch kind {
        case .markdown: reader.textStorage?.setAttributedString(MarkdownRender.attributed(editor.string, base: fileURL))
        case .json: tree.show(editor.string)
        case .text: break
        }
    }
}

/// A text view that undoes with its document. ⌘Z goes to the window, whose
/// undo manager is its own unless a window controller hands it the
/// document's — and a tab has no window controller. Answered here, first in
/// line, it is the document's.
final class DocumentTextView: NSTextView {
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return undoManager?.canUndo ?? false
        case #selector(redo(_:)): return undoManager?.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
