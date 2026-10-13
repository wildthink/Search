import AppKit

// The right side of a catalog's tab: what the chosen row is, edited where it
// shows. Title, description, address and tags are fields; the notes are the
// concept's Markdown, as written. What a person or a place carries besides —
// an address, a position, a telephone — is shown as its file has it, and
// kept as it is (CatalogConcept.others).

final class CatalogDetail: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    weak var document: CatalogDocument?
    let view = NSView()

    private let stack = NSStackView()
    private let kind = NSTextField(labelWithString: "")
    private let title = NSTextField()
    private let summary = NSTextField()
    private let address = NSTextField()
    private let opener = NSButton()
    private let tags = NSTextField()
    private let others = NSTextField(wrappingLabelWithString: "")
    private let notesLabel = NSTextField(labelWithString: "Notes")
    private let notesScroll = NSTextView.scrollableTextView()
    private var notes: NSTextView { notesScroll.documentView as! NSTextView }
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let emptyTrash = NSButton()

    /// The row on show; nil with none chosen, or several.
    private var node: CatalogNode?
    private var trashShown = false

    override init() {
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        kind.font = .systemFont(ofSize: 11, weight: .medium)
        kind.textColor = .secondaryLabelColor
        field(title, "Title", font: .systemFont(ofSize: 20, weight: .semibold))
        field(summary, "Description", font: .systemFont(ofSize: 13))
        field(address, "Address", font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        field(tags, "Tags, separated by commas", font: .systemFont(ofSize: 12))
        summary.textColor = .secondaryLabelColor

        opener.title = "Open"
        opener.bezelStyle = .push
        opener.controlSize = .small
        opener.target = self
        opener.action = #selector(openShown(_:))
        let addressRow = NSStackView(views: [address, opener])
        addressRow.orientation = .horizontal
        addressRow.spacing = 8

        others.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        others.textColor = .secondaryLabelColor
        others.isSelectable = true
        notesLabel.font = .systemFont(ofSize: 11, weight: .medium)
        notesLabel.textColor = .secondaryLabelColor

        for each in [kind, title, summary, addressRow, tags, others, notesLabel] as [NSView] {
            stack.addArrangedSubview(each)
            each.translatesAutoresizingMaskIntoConstraints = false
            if each !== kind, each !== notesLabel {
                each.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        stack.setCustomSpacing(2, after: kind)
        stack.setCustomSpacing(14, after: tags)

        notes.isRichText = false
        notes.allowsUndo = true
        notes.font = .systemFont(ofSize: 13)
        notes.textContainerInset = NSSize(width: 2, height: 6)
        notes.isAutomaticQuoteSubstitutionEnabled = false
        notes.isAutomaticDashSubstitutionEnabled = false
        notes.delegate = self
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notesScroll)

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 13)
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        emptyTrash.title = "Empty Trash"
        emptyTrash.bezelStyle = .push
        emptyTrash.target = self
        emptyTrash.action = #selector(emptyTrashNow(_:))
        emptyTrash.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyTrash)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            notesScroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 2),
            notesScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            notesScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            notesScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            emptyTrash.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: 12),
            emptyTrash.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func field(_ field: NSTextField, _ placeholder: String, font: NSFont) {
        field.placeholderString = placeholder
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
    }

    /// The chosen rows, shown: one to edit, or a word about several, none,
    /// or the trash.
    func show(chosen: [CatalogNode], in catalog: Catalog) {
        guard let document else { return }
        let one = chosen.count == 1 ? chosen[0] : nil
        trashShown = one === catalog.trash
        node = trashShown ? nil : one
        let editing = node != nil
        stack.isHidden = !editing
        notesScroll.isHidden = !editing || node?.concept == nil
        empty.isHidden = editing
        emptyTrash.isHidden = !trashShown
        if trashShown {
            let count = catalog.trash.all.count - 1
            empty.stringValue = "\(count == 1 ? "One row is" : "\(count) rows are") in the trash. Saving lets go of what has been there more than \(CatalogDocument.keepDays) days."
            return
        }
        guard let node else {
            let count = catalog.root.all.count - 1
            empty.stringValue = chosen.isEmpty
                ? "\(catalog.title)\n\(count == 1 ? "One row" : "\(count) rows")\n\nPaste an address, or drop a link here, to add it."
                : "\(chosen.count) rows chosen"
            return
        }
        let trashed = document.isTrashed(node)
        let concept = node.concept
        kind.stringValue = (concept.map { $0.isSection ? "SECTION" : $0.type.uppercased() } ?? "SECTION")
            + (trashed ? " · IN THE TRASH" : "")
        title.stringValue = concept?.title ?? (concept == nil ? node.text : "")
        title.placeholderString = concept?.shownTitle ?? "Section"
        summary.stringValue = concept?.summary ?? ""
        address.stringValue = concept?.resource ?? ""
        tags.stringValue = concept?.tags.joined(separator: ", ") ?? ""
        let lines = concept?.others.flatMap(\.lines) ?? []
        others.stringValue = lines.joined(separator: "\n")
        others.isHidden = lines.isEmpty
        // Where it is: for a site or a file always, for anything else once it has one.
        let isLink = concept.map { !$0.isSection && ([CatalogConcept.websiteType, CatalogConcept.fileType].contains($0.type) || $0.resource != nil) } ?? false
        summary.isHidden = concept == nil
        address.superview?.isHidden = !isLink
        opener.isEnabled = concept?.url != nil
        tags.isHidden = concept == nil
        notesLabel.isHidden = concept == nil
        if notes.string != concept?.body ?? "" { notes.string = concept?.body ?? "" }
        notes.undoManager?.removeAllActions(withTarget: notes.textStorage as Any)
        for each in [title, summary, address, tags] { each.isEditable = !trashed }
        notes.isEditable = !trashed
    }

    func editTitle() {
        view.window?.makeFirstResponder(title)
    }

    @objc private func openShown(_ sender: Any?) {
        guard let node else { return }
        document?.open([node])
    }

    @objc private func emptyTrashNow(_ sender: Any?) {
        document?.emptyTrash()
    }

    // MARK: - Typing

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node, let document else { return }
        let value = field.stringValue
        document.typed {
            guard let id = node.concept?.id else {
                // A section that is only a line: its words are its title.
                if field === title { node.text = value }
                return
            }
            document.catalog.change(id: id) { concept in
                let text = value.trimmingCharacters(in: .whitespaces)
                switch field {
                case title: concept.title = text.isEmpty ? nil : value
                case summary: concept.summary = text.isEmpty ? nil : value
                case address: concept.resource = text.isEmpty ? nil : text
                case tags: concept.tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                default: break
                }
            }
        }
        if field === address { opener.isEnabled = node.concept?.url != nil }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        document?.endTyping()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return in a field is done with it, back to the outline.
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            document?.endTyping()
            view.window?.makeFirstResponder(document?.outline)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard let node, let id = node.concept?.id, let document else { return }
        let body = notes.string
        document.typed { document.catalog.change(id: id) { $0.body = body } }
    }

    func textDidEndEditing(_ notification: Notification) {
        document?.endTyping()
    }
}
