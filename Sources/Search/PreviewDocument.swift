import AppKit
import Quartz
import UniformTypeIdentifiers

// A spreadsheet — Excel, Numbers, OpenDocument — shown the way the Finder's
// Quick Look shows it, sheets and all, in a tab (see TabContent.swift).
//
// Quick Look does the reading: no parser here for formats that are each a
// world of their own, and nothing added to the app's size. It shows; it
// doesn't edit. A file another app changes is shown again.

final class PreviewDocument: NSDocument, TabContent {
    private let preview: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)!

    var onDirty: ((Bool) -> Void)?
    var onLink: ((URL) -> Void)?
    var isReading: Bool { false }
    var view: NSView { preview }
    var focus: NSView { preview }
    /// Quick Look draws it; there is no text here to hand anyone.
    var text: String? { nil }
    var zoom: CGFloat = 1

    /// Spreadsheets, by what the system says they are.
    static func handles(_ type: UTType) -> Bool {
        type.conforms(to: .spreadsheet)
    }

    override init() {
        super.init()
        preview.autostarts = true
        preview.shouldCloseWithWindow = false
    }

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { false }
    override class func isNativeType(_ type: String) -> Bool { true }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [] }
    override var windowForSheet: NSWindow? { preview.window ?? NSApp.keyWindow }

    /// Not read here at all: Quick Look reads it, where it is.
    override func read(from url: URL, ofType typeName: String) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
        }
        preview.previewItem = url as NSURL
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.fileWriteNoPermission)
    }

    override func close() {
        NSFileCoordinator.removeFilePresenter(self)
        preview.close()
        super.close()
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        NSPrintOperation(view: preview, printInfo: printInfo)
    }

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.preview.refreshPreviewItem() }
    }

    // MARK: - TabContent

    func showFind() { NSSound.beep() }
    func setReading(_ on: Bool) -> Bool { false }

    /// For tests: the file Quick Look was given.
    var previewing: URL? { preview.previewItem?.previewItemURL }
}
