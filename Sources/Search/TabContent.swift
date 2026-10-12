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
// SPIKE: one kind of document (text: Markdown, JSON, plain text), edited as
// text. Rendered Markdown, a JSON tree, SQLite and spreadsheets would each be
// another conformer.

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
        guard url.isFileURL, !url.hasDirectoryPath, let type = type(of: url) else { return false }
        if type.conforms(to: .html) || type.conforms(to: .svg) || type.conforms(to: .xml) { return false }
        return type.conforms(to: .json)
            || type.conforms(to: .markdown)
            || type.conforms(to: .plainText)
    }

    static func open(_ url: URL) throws -> TabContent {
        let document = try TextDocument(contentsOf: url, ofType: (type(of: url) ?? .plainText).identifier)
        // Told when another app changes the file. A document with a window
        // of its own is put on the list by AppKit; one in a tab isn't.
        NSFileCoordinator.addFilePresenter(document)
        return document
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

/// A text file, edited as text.
final class TextDocument: NSDocument, TabContent, NSTextViewDelegate {
    private let scroll = NSTextView.scrollableTextView()
    private let editor = DocumentTextView()
    /// The file's own encoding, written back the way it was read.
    private var encoding: String.Encoding = .utf8

    var onDirty: ((Bool) -> Void)?

    var view: NSView { scroll }
    var focus: NSView { editor }
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
    }

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { false }
    // Its types are whatever the file was, not ones the app declares.
    override class func isNativeType(_ type: String) -> Bool { true }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        fileType.map { [$0] } ?? []
    }
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        fileURL?.pathExtension
    }

    /// Where NSDocument puts its questions: the window the tab is in.
    override var windowForSheet: NSWindow? { scroll.window ?? NSApp.keyWindow }

    override func read(from data: Data, ofType typeName: String) throws {
        // Not UTF-8: Latin-1 reads anything, which beats refusing the file,
        // and it is written back as Latin-1.
        if let text = String(data: data, encoding: .utf8) {
            encoding = .utf8
            editor.string = text
        } else {
            encoding = .isoLatin1
            editor.string = String(data: data, encoding: .isoLatin1) ?? ""
        }
        editor.font = UTType(typeName)?.conforms(to: .json) == true
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 14)
        undoManager?.removeAllActions()
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
        NSPrintOperation(view: editor, printInfo: printInfo)
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

    // MARK: - TabContent

    var zoom: CGFloat {
        get { scroll.magnification }
        set { scroll.magnification = newValue }
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.window?.makeFirstResponder(editor)
        editor.performTextFinderAction(item)
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
