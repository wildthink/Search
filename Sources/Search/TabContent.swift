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
// SPIKE: one kind of document (text: Markdown, JSON, plain text), edited as
// text. Rendered Markdown, a JSON tree, SQLite and spreadsheets would each be
// another conformer; NSDocument would take over save, autosave and versions.

/// What a tab shows instead of a web page.
protocol TabContent: AnyObject {
    /// The file, which is also the tab's address.
    var url: URL { get }
    /// What goes on the stage where the page would be.
    var view: NSView { get }
    /// What should have the keyboard when the tab comes to the front.
    var focus: NSView { get }
    /// Changed since it was opened or last saved.
    var dirty: Bool { get }
    /// Told whenever `dirty` changes, so the tab can say so.
    var onDirty: ((Bool) -> Void)? { get set }
    /// Its text, for find, reading and the assistant — nil where it has none.
    var text: String? { get }

    func save() throws
    /// The file read again, whatever was typed since.
    func revert() throws
    func printOperation() -> NSPrintOperation
    /// ⌘F: its own way of finding, since Search's find bar searches pages.
    func showFind()
    /// ⌘+ and ⌘-: how big it is drawn, 1 for as it is.
    var zoom: CGFloat { get set }
}

enum Documents {
    /// Files Search shows in a view of its own rather than handing to WebKit.
    /// HTML and its kin are pages, and stay WebKit's, as do SVG and PDF.
    static func handles(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath,
              let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        if type.conforms(to: .html) || type.conforms(to: .svg) || type.conforms(to: .xml) { return false }
        return type.conforms(to: .json)
            || type.conforms(to: .markdown)
            || type.conforms(to: .plainText)
    }

    static func open(_ url: URL) throws -> TabContent {
        try TextDocument(url: url)
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
final class TextDocument: NSObject, TabContent, NSTextViewDelegate {
    let url: URL
    private let scroll: NSScrollView
    private let editor: NSTextView
    /// What is on disk, as last read or written — dirty is anything else.
    private var saved: String

    var onDirty: ((Bool) -> Void)?
    private(set) var dirty = false {
        didSet { if dirty != oldValue { onDirty?(dirty) } }
    }

    var view: NSView { scroll }
    var focus: NSView { editor }
    var text: String? { editor.string }

    init(url: URL) throws {
        self.url = url
        saved = try TextDocument.read(url)
        scroll = NSTextView.scrollableTextView()
        editor = scroll.documentView as! NSTextView
        super.init()

        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 24, height: 20)
        editor.font = UTType(filenameExtension: url.pathExtension)?.conforms(to: .json) == true
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 14)
        editor.string = saved
        editor.delegate = self
        scroll.drawsBackground = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.4
        scroll.maxMagnification = 3
    }

    func textDidChange(_ notification: Notification) {
        dirty = editor.string != saved
    }

    func save() throws {
        let now = editor.string
        var failure: Error?
        var coordinated: NSError?
        // Coordinated, so another app holding the file (an editor, iCloud
        // Drive) hears about the write rather than finding it underneath.
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinated) { at in
            do { try now.write(to: at, atomically: true, encoding: .utf8) } catch { failure = error }
        }
        if let error = coordinated ?? failure { throw error }
        saved = now
        dirty = false
    }

    func revert() throws {
        saved = try TextDocument.read(url)
        editor.string = saved
        editor.undoManager?.removeAllActions()
        dirty = false
    }

    func printOperation() -> NSPrintOperation {
        NSPrintOperation(view: editor)
    }

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

    private static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // Not UTF-8: Latin-1 reads anything, which beats refusing the file.
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
