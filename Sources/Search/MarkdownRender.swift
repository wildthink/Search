import AppKit

// Markdown, drawn the way it reads: for a .md tab's reading view (see
// TabContent.swift), with ⇧⌘R going between it and the source.
//
// Foundation parses it — the whole syntax, tables and all — into runs that
// each say what block they are in and what they are inline. Nothing draws
// those blocks on its own: a heading comes out the size of a paragraph and
// a list has no bullets. This gives each its look, as attributes a text view
// draws, so find, print, zoom and selection are the text view's own.

enum MarkdownRender {
    static func attributed(_ source: String, base: URL?) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options, baseURL: base) else {
            return NSAttributedString(string: source, attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        }

        let out = NSMutableAttributedString()
        var lastBlock: Int?
        var lastSection: Int?
        var listItemsSeen = Set<Int>()

        for run in parsed.runs {
            let blocks = run.presentationIntent?.components ?? []
            var text = String(parsed[run.range].characters)
            var opensSection = false

            // A new block starts on a line of its own; a cell after the
            // first in its row, after a tab.
            if let block = blocks.first?.identity, block != lastBlock {
                if lastBlock != nil {
                    out.append(NSAttributedString(string: cellIndex(blocks).map { $0 > 0 ? "\t" : "\n" } ?? "\n"))
                }
                lastBlock = block
                // The outermost block changed — a list after a paragraph, a
                // paragraph after a table: room above it, whatever is inside.
                let section = blocks.last?.identity
                opensSection = lastSection != nil && section != lastSection
                lastSection = section
                // A list item's marker, once, before its first paragraph.
                if let item = blocks.first(where: { if case .listItem = $0.kind { true } else { false } }),
                   listItemsSeen.insert(item.identity).inserted {
                    text = marker(for: item, in: blocks) + text
                }
            }
            let looks = attributes(blocks: blocks, run: run)
            // The room goes above the section's first line only: a code
            // block is one run of many lines, and each would get it.
            if opensSection, let style = (looks[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 12)
                var first = looks
                first[.paragraphStyle] = style
                let end = text.firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
                out.append(NSAttributedString(string: String(text[..<end]), attributes: first))
                text = String(text[end...])
            }
            out.append(NSAttributedString(string: text, attributes: looks))
        }
        return out
    }

    // MARK: - looks

    private static let body = NSFont.systemFont(ofSize: 14)
    private static let indentStep: CGFloat = 22

    private static func attributes(blocks: [PresentationIntent.IntentType], run: AttributedString.Runs.Run) -> [NSAttributedString.Key: Any] {
        var font = body
        var color = NSColor.labelColor
        var background: NSColor?
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        paragraph.lineHeightMultiple = 1.15

        var lists = 0
        for block in blocks {
            switch block.kind {
            case .header(let level):
                let sizes: [CGFloat] = [26, 21, 17, 15, 14, 13]
                font = .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .semibold)
                paragraph.paragraphSpacingBefore = level <= 2 ? 10 : 4
            case .codeBlock:
                font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                background = .quaternaryLabelColor.withAlphaComponent(0.12)
                paragraph.lineHeightMultiple = 1.05
                // Its lines are one block, not paragraphs of their own.
                paragraph.paragraphSpacing = 0
            case .blockQuote:
                color = .secondaryLabelColor
                paragraph.firstLineHeadIndent += 16
                paragraph.headIndent += 16
            case .orderedList, .unorderedList:
                lists += 1
            case .tableHeaderRow:
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            default:
                break
            }
        }
        if lists > 0 {
            // The marker hangs to the left of the item's text.
            paragraph.firstLineHeadIndent += indentStep * CGFloat(lists - 1)
            paragraph.headIndent += indentStep * CGFloat(lists)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            paragraph.paragraphSpacing = 4
        }
        if blocks.contains(where: { if case .tableCell = $0.kind { true } else { false } }) {
            paragraph.tabStops = (1...8).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 160) }
            paragraph.paragraphSpacing = 4
        }

        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if let inline = run.inlinePresentationIntent {
            let manager = NSFontManager.shared
            if inline.contains(.stronglyEmphasized) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            if inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                background = .quaternaryLabelColor.withAlphaComponent(0.12)
            }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.toolTip] = link.isFileURL ? link.path : link.absoluteString
        }
        attributes[.font] = font
        attributes[.foregroundColor] = color
        if let background { attributes[.backgroundColor] = background }
        return attributes
    }

    /// "• " for an unordered list, "3. " for an ordered one.
    private static func marker(for item: PresentationIntent.IntentType, in blocks: [PresentationIntent.IntentType]) -> String {
        guard case .listItem(let ordinal) = item.kind else { return "" }
        let ordered = blocks.first { block in
            switch block.kind {
            case .orderedList: true
            case .unorderedList: true
            default: false
            }
        }.map { if case .orderedList = $0.kind { true } else { false } } ?? false
        return ordered ? "\(ordinal).\t" : "•\t"
    }

    private static func cellIndex(_ blocks: [PresentationIntent.IntentType]) -> Int? {
        for block in blocks { if case .tableCell(let column) = block.kind { return column } }
        return nil
    }
}
