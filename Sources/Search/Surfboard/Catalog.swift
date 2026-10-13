import Foundation

// A Surfboard catalog: a .surfboard folder of Markdown files in the Open
// Knowledge Format (OKF). Each thing in it — a site, a file, a person, a place,
// a section — is a concept, one file under items/ with a block of frontmatter
// over notes. The tree they hang in is _catalog.md: a nested list of links to
// those files, and a "## Trash" list of what was deleted. index.md beside it
// is a listing written for other tools to read, and is never read back here.
//
// The format belongs to OKFFormat (WildThink's package, github.com/wildthink/
// OKFFormat), which the Surfboard app reads and writes catalogs with. Search
// doesn't link it: it would add 1.8 MB to a 6.3 MB app, and it reads about a
// millisecond a concept — 1.2 s to open a catalog of 1,000 sites, nearly all
// of it its general-purpose YAML (13 Oct 2026). This reads the part of the
// format a catalog uses, and keeps the rest as it found it: a key it doesn't
// know is written back line for line, and a file nothing changed is never
// written at all. Tests/OKFConformance reads what this writes with OKFFormat
// itself, so the two can't drift apart unnoticed.

/// One concept file.
struct CatalogConcept: Equatable {
    /// Where it lives in the bundle, "items/<uuid>.md" — its name in the
    /// catalog's links, kept even while the file is parked in trash/.
    var id: String
    var type: String
    var title: String?
    var summary: String?
    /// The address it stands for, as written: a web address or a file's.
    var resource: String?
    var tags: [String] = []
    var timestamp: Date?
    /// An SF Symbol's name, and a colour by name: how the row is drawn.
    var icon: String?
    var color: String?
    /// When it went to the trash, the clock save-time decay counts from.
    var deleted: Date?
    var body: String = ""
    /// Every other key in its frontmatter, as written: the key's own line
    /// and the lines under it. A person's address, a place's position, the
    /// provenance a newer OKF writes — kept, never rewritten.
    var others: [Field] = []

    struct Field: Equatable {
        let key: String
        var lines: [String]
    }

    static let sectionType = "Section"
    static let websiteType = "Website"
    static let fileType = "LocalFile"

    var isSection: Bool { type == CatalogConcept.sectionType }

    var url: URL? {
        guard let resource, !resource.isEmpty else { return nil }
        return URL(string: resource)
    }

    /// Its name in the outline: the title, else the address's host, else the
    /// file's name — as the Surfboard app shows it.
    var shownTitle: String {
        if let title, !title.isEmpty { return title }
        if let url {
            if url.isFileURL { return url.lastPathComponent }
            if let host = url.host { return host }
        }
        return id
    }

    /// A new concept with a file of its own.
    static func new(type: String, title: String? = nil, resource: String? = nil) -> CatalogConcept {
        CatalogConcept(id: "items/\(UUID().uuidString.lowercased()).md", type: type, title: title,
                       resource: resource, timestamp: Date())
    }
}

/// A row of the outline: a concept, or a section that is only a line of
/// text in _catalog.md. A class, so the outline view can tell rows apart.
final class CatalogNode {
    var concept: CatalogConcept?
    /// A plain section's text; a concept's row shows its own title.
    var text: String
    var children: [CatalogNode] = []
    weak var parent: CatalogNode?

    init(concept: CatalogConcept) {
        self.concept = concept
        self.text = concept.shownTitle
    }

    init(section text: String, children: [CatalogNode] = []) {
        self.text = text
        self.children = children
        children.forEach { $0.parent = self }
    }

    var title: String { concept?.shownTitle ?? text }

    /// Holds others, as OKF says: a section concept, a line of text, or any
    /// row something was nested under by hand.
    var isSection: Bool { concept?.isSection ?? true || !children.isEmpty }

    /// Every concept from here down, sections included.
    var concepts: [CatalogConcept] {
        (concept.map { [$0] } ?? []) + children.flatMap(\.concepts)
    }

    /// Every row from here down, this one first.
    var all: [CatalogNode] { [self] + children.flatMap(\.all) }

    func insert(_ node: CatalogNode, at index: Int) {
        node.parent = self
        children.insert(node, at: min(max(index, 0), children.count))
    }

    func append(_ node: CatalogNode) { insert(node, at: children.count) }

    /// This row and everything under it, anew.
    func copy() -> CatalogNode {
        let made = concept.map(CatalogNode.init(concept:)) ?? CatalogNode(section: text)
        made.text = text
        children.forEach { made.append($0.copy()) }
        return made
    }

    /// Taken out of whichever row holds it. Where it was, for undo.
    @discardableResult
    func detach() -> (parent: CatalogNode, index: Int)? {
        guard let parent, let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        parent.children.remove(at: index)
        self.parent = nil
        return (parent, index)
    }

    /// Whether `node` is this row or below it — where a row can't be moved to.
    func contains(_ node: CatalogNode) -> Bool {
        var at: CatalogNode? = node
        while let here = at {
            if here === self { return true }
            at = here.parent
        }
        return false
    }
}

/// A whole catalog: its title, its tree, its trash.
final class Catalog {
    static let catalogFile = "_catalog.md"
    static let indexFile = "index.md"
    static let catalogType = "Catalog"

    var title = "Catalog"
    /// The rest of _catalog.md's frontmatter — the Surfboard app's reading
    /// style, the OKF version — kept as it was.
    var style: [String: String] = [:]
    let root = CatalogNode(section: "")
    let trash = CatalogNode(section: "Trash")

    /// The text each concept file had when read, by id: a concept that
    /// still matches it is not written again.
    private(set) var read: [String: String] = [:]

    /// The concept files, by id, from their text.
    static func concepts(_ files: [String: String]) -> [String: CatalogConcept] {
        var found: [String: CatalogConcept] = [:]
        for (id, text) in files {
            if let concept = CatalogConcept(id: id, markdown: text) { found[id] = concept }
        }
        return found
    }

    /// A catalog from its files' text: _catalog.md (or, from before it
    /// existed, index.md), the concepts under items/, and those in the trash,
    /// both by their ids.
    init(catalog text: String?, items: [String: String], trashed: [String: String] = [:]) {
        let live = Catalog.concepts(items)
        var parked = Catalog.concepts(trashed)
        for id in parked.keys where live[id] != nil { parked[id] = nil }
        for (id, text) in items where live[id] != nil { read[id] = text }
        for (id, text) in trashed where parked[id] != nil { read[id] = text }

        var listed = Set<String>()
        if let text {
            let (front, body) = Frontmatter.split(text)
            for (key, value) in Frontmatter.pairs(front ?? []) {
                switch key {
                case "type": break
                case "title": title = value
                default: style[key] = value
                }
            }
            let everything = live.merging(parked) { kept, _ in kept }
            let (outline, trashed) = Outline.parse(body, concepts: everything)
            outline.forEach(root.append)
            trashed.forEach(trash.append)
            listed = Set((outline + trashed).flatMap(\.concepts).map(\.id))
        }
        // Files no line names: kept, newest first, where their folder says
        // they were. A section's file with nothing under it is structure
        // nobody can see, and is left out — unless there is no tree at all,
        // when every file is listed, as OKF lists them.
        let orphan = { (concept: CatalogConcept) in !listed.contains(concept.id) && (text == nil || !concept.isSection) }
        func newest(_ a: Date?, _ b: Date?, _ x: CatalogConcept, _ y: CatalogConcept) -> Bool {
            let (a, b) = (a ?? .distantPast, b ?? .distantPast)
            return a != b ? a > b : x.id < y.id
        }
        for concept in live.values.filter(orphan).sorted(by: { newest($0.timestamp, $1.timestamp, $0, $1) }) {
            root.append(CatalogNode(concept: concept))
        }
        for concept in parked.values.filter(orphan).sorted(by: { newest($0.deleted, $1.deleted, $0, $1) }) {
            trash.append(CatalogNode(concept: concept))
        }
        Catalog.pruneEmptySections(trash)
    }

    // MARK: - Undo

    /// The whole tree as it is now, for undo: rows and concepts copied, so
    /// what changes next doesn't change it.
    struct Snapshot {
        fileprivate let title: String
        fileprivate let rows: [CatalogNode]
        fileprivate let trashed: [CatalogNode]
    }

    func snapshot() -> Snapshot {
        Snapshot(title: title, rows: root.children.map { $0.copy() }, trashed: trash.children.map { $0.copy() })
    }

    func restore(_ snapshot: Snapshot) {
        title = snapshot.title
        root.children = []
        trash.children = []
        snapshot.rows.forEach { root.append($0.copy()) }
        snapshot.trashed.forEach { trash.append($0.copy()) }
    }

    // MARK: - Changes

    /// Into the trash, stamped now — sections and all under them.
    func throwAway(_ node: CatalogNode, at now: Date = Date()) {
        node.detach()
        for row in node.all where row.concept != nil && row.concept?.deleted == nil {
            row.concept?.deleted = now
        }
        trash.insert(node, at: 0)
    }

    /// Out of the trash, to the end of the catalog: where it was is gone.
    func restore(_ node: CatalogNode) {
        node.detach()
        for row in node.all { row.concept?.deleted = nil }
        root.append(node)
        Catalog.pruneEmptySections(trash)
    }

    /// Gone for good: its file goes at the next save.
    func purge(_ node: CatalogNode) {
        node.detach()
        Catalog.pruneEmptySections(trash)
    }

    /// The decay save applies: what has been in the trash since before
    /// `cutoff` goes, and any section that leaves empty.
    func decay(before cutoff: Date) {
        func sweep(_ node: CatalogNode) {
            for child in node.children {
                if let deleted = child.concept?.deleted, deleted < cutoff, child.children.isEmpty {
                    child.detach()
                } else {
                    sweep(child)
                }
            }
        }
        sweep(trash)
        Catalog.pruneEmptySections(trash)
    }

    private static func pruneEmptySections(_ node: CatalogNode) {
        for child in node.children {
            pruneEmptySections(child)
            if child.children.isEmpty, child.concept?.isSection ?? true { child.detach() }
        }
    }

    /// Every row showing a concept: one, unless it is listed twice.
    func nodes(id: String) -> [CatalogNode] {
        (root.all + trash.all).filter { $0.concept?.id == id }
    }

    /// A change to a concept, made wherever it is listed.
    func change(id: String, _ change: (inout CatalogConcept) -> Void) {
        for node in nodes(id: id) {
            guard var concept = node.concept else { continue }
            change(&concept)
            node.concept = concept
        }
    }

    // MARK: - Writing

    /// What a save writes: the catalog, the listing, and the text of each
    /// concept file, by where it goes in the bundle — items/… for live ones,
    /// trash/items/… for those in the trash. A concept whose text is what was
    /// read is left out unless it moved: there is nothing to write.
    struct Output {
        var catalog: String
        var index: String
        var files: [String: String]
        /// Every concept file the catalog still has, wherever it lives now.
        var kept: Set<String>
    }

    func output(onlyChanged: Bool = true) -> Output {
        var files: [String: String] = [:]
        var kept = Set<String>()
        let live = root.children.flatMap(\.concepts)
        let alive = Set(live.map(\.id))
        // A concept listed twice, once thrown away, is still in the catalog:
        // its file stays under items/.
        let thrown = trash.children.flatMap(\.concepts).filter { !alive.contains($0.id) }
        for (concepts, folder) in [(live, ""), (thrown, "trash/")] {
            for concept in concepts {
                let path = folder + concept.id
                kept.insert(path)
                let text = concept.markdown()
                if !onlyChanged || read[concept.id] != text || !wasRead(at: path) {
                    files[path] = text
                }
            }
        }
        return Output(catalog: catalogText(), index: indexText(), files: files, kept: kept)
    }

    /// Where each concept's file was when read, so one that moved in or out
    /// of the trash is written in its new place.
    var readFrom: [String: String] = [:]

    private func wasRead(at path: String) -> Bool {
        let id = path.hasPrefix("trash/") ? String(path.dropFirst(6)) : path
        return readFrom[id] == path
    }

    /// The texts are now what is on disk.
    func saved(_ output: Output) {
        for path in output.kept {
            let id = path.hasPrefix("trash/") ? String(path.dropFirst(6)) : path
            readFrom[id] = path
        }
        for concept in root.concepts + trash.concepts {
            read[concept.id] = concept.markdown()
        }
    }

    func catalogText() -> String {
        var front = ["type: \(Catalog.catalogType)", "title: \(Frontmatter.scalar(title))"]
        for key in style.keys.sorted() {
            front.append("\(key): \(Frontmatter.scalar(style[key] ?? ""))")
        }
        var lines = ["---"] + front + ["---", "", "# \(title)", ""]
        lines += Outline.lines(root.children)
        if !trash.children.isEmpty {
            lines += ["", "## Trash", ""] + Outline.lines(trash.children)
        }
        return lines.joined(separator: "\n")
    }

    /// The listing OKF's own tools read: a heading for each section at the
    /// top, its rows under it, and what stands alone under the catalog's own
    /// title. Written at every save, never read.
    func indexText() -> String {
        var lines: [String] = []
        if let version = style["okf_version"] {
            lines += ["---", "okf_version: \"\(version)\"", "---", ""]
        }
        let loose = root.children.filter { !$0.isSection }
        let sections = root.children.filter(\.isSection)
        func entries(_ node: CatalogNode, _ indent: String) -> [String] {
            var out: [String]
            if let concept = node.concept {
                let summary = concept.summary.map { " - \($0)" } ?? ""
                out = ["\(indent)* [\(Outline.escaped(concept.shownTitle))](\(concept.id))\(summary)"]
            } else {
                out = ["\(indent)* \(node.text)"]
            }
            if node.isSection { out += node.children.flatMap { entries($0, indent + "  ") } }
            return out
        }
        if !loose.isEmpty || sections.isEmpty {
            lines += ["# \(title)", ""] + loose.flatMap { entries($0, "") } + [""]
        }
        for section in sections {
            lines += ["# \(section.title)", ""] + section.children.flatMap { entries($0, "") } + [""]
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Concept files

extension CatalogConcept {
    /// The keys this reads, in the order OKF writes a concept's keys.
    static let order = ["type", "title", "description", "resource", "identifiers", "tags", "timestamp",
                        "generated", "verified", "status", "stale_after", "sources", "usage_window",
                        "icon", "color", "deleted"]
    private static let modelled: Set<String> = ["type", "title", "description", "resource", "tags",
                                                 "timestamp", "icon", "color", "deleted"]

    /// A concept from its file's text; nil for a file without frontmatter,
    /// which OKF doesn't count as a concept.
    init?(id: String, markdown text: String) {
        guard text.hasPrefix("---") else { return nil }
        let (front, body) = Frontmatter.split(text)
        guard let front, !front.isEmpty else { return nil }
        self.id = id
        self.type = CatalogConcept.websiteType
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var generatedAt: Date?
        for field in Frontmatter.fields(front) {
            let value = Frontmatter.value(field.lines)
            func text() -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            switch field.key {
            case "type": if let t = text() { type = t }
            case "title": title = text()
            case "description": summary = text()
            case "resource": resource = text()
            case "tags": tags = Frontmatter.list(field.lines)
            case "timestamp": timestamp = text().flatMap(Frontmatter.date)
            case "icon": icon = text()
            case "color": color = text()
            case "deleted": deleted = text().flatMap(Frontmatter.date)
            default:
                // OKF 0.2 keeps the time under generated: at:, and reads it
                // in place of timestamp — when the block says who, as it must.
                if field.key == "generated", let by = Frontmatter.nested("by", in: field.lines), !by.isEmpty {
                    generatedAt = Frontmatter.nested("at", in: field.lines).flatMap(Frontmatter.date)
                }
                others.append(field)
            }
        }
        if let generatedAt { timestamp = generatedAt }
    }

    /// The file's text, as OKF writes it: known keys in OKF's order, every
    /// other key as it was, then the notes.
    func markdown() -> String {
        var modelled: [String: [String]] = [:]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            modelled[key] = ["\(key): \(Frontmatter.scalar(value))"]
        }
        put("type", type)
        put("title", title)
        put("description", summary)
        put("resource", resource)
        if !tags.isEmpty { modelled["tags"] = ["tags: [" + tags.map(Frontmatter.scalar).joined(separator: ", ") + "]"] }
        // With a generated: block, the time is that block's.
        if let timestamp, !others.contains(where: { $0.key == "generated" }) {
            put("timestamp", Frontmatter.dateText(timestamp))
        }
        put("icon", icon)
        put("color", color)
        if let deleted { put("deleted", Frontmatter.dateText(deleted)) }

        var lines: [String] = []
        var placed = Set<String>()
        for key in CatalogConcept.order {
            if let mine = modelled[key] {
                lines += mine
            } else if let field = others.first(where: { $0.key == key }) {
                lines += field.lines
            }
            placed.insert(key)
        }
        for field in others where !placed.contains(field.key) && !CatalogConcept.modelled.contains(field.key) {
            lines += field.lines
        }
        var out = ["---"] + lines + ["---"]
        if !body.isEmpty { out += ["", body] }
        return out.joined(separator: "\n")
    }
}

// MARK: - Frontmatter

/// The YAML a concept's frontmatter is written in, as far as a catalog
/// needs it: a key per line, a value that is plain, quoted, a [list] or a
/// block of lines under it. Anything else is kept as lines.
enum Frontmatter {
    /// The lines between the opening and closing `---`, and what follows.
    /// Nil when the text doesn't open with a closed block.
    static func split(_ text: String) -> (front: [String]?, body: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return (nil, text) }
        let front = lines[1..<end].map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        return (Array(front), lines[(end + 1)...].joined(separator: "\n"))
    }

    /// Each top-level key with its line and the indented lines under it.
    static func fields(_ lines: [String]) -> [CatalogConcept.Field] {
        var fields: [CatalogConcept.Field] = []
        for line in lines {
            if let key = key(of: line) {
                fields.append(CatalogConcept.Field(key: key, lines: [line]))
            } else if !fields.isEmpty {
                fields[fields.count - 1].lines.append(line)
            }
        }
        return fields
    }

    /// The key a line starts, when it starts one at the left margin.
    private static func key(of line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t", first != "-", first != "#",
              let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty || key.contains(" ") && !key.hasPrefix("\"") ? nil : key
    }

    /// Simple key: value pairs, for _catalog.md's frontmatter.
    static func pairs(_ lines: [String]) -> [(String, String)] {
        fields(lines).compactMap { field in
            guard let value = value(field.lines), !value.isEmpty else { return nil }
            return (field.key, value)
        }
    }

    /// A field's value as one string: plain or quoted on its line, or a
    /// | or > block under it. Nil for a list or a mapping.
    static func value(_ lines: [String]) -> String? {
        guard let first = lines.first, let colon = first.firstIndex(of: ":") else { return nil }
        let raw = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("|") || raw.hasPrefix(">") {
            let block = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            return raw.hasPrefix("|") ? block.joined(separator: "\n") : block.filter { !$0.isEmpty }.joined(separator: " ")
        }
        // A list or a mapping, on the line or under it, is not one string.
        if raw.hasPrefix("[") || raw.hasPrefix("{") { return nil }
        if raw.isEmpty { return lines.count > 1 ? nil : "" }
        return scalarValue(raw)
    }

    /// A scalar as written, unquoted.
    static func scalarValue(_ raw: String) -> String {
        if raw.hasPrefix("\""), let close = closingQuote(raw) {
            var out = ""
            var escaping = false
            for ch in raw[raw.index(after: raw.startIndex)..<close] {
                if escaping {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if raw.hasPrefix("'"), raw.count >= 2, raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // A comment starts at a # after a space.
        if let hash = raw.range(of: " #") { return raw[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
        return raw
    }

    /// The closing double quote, skipping escaped ones.
    private static func closingQuote(_ raw: String) -> String.Index? {
        var escaping = false
        var at = raw.index(after: raw.startIndex)
        while at < raw.endIndex {
            let ch = raw[at]
            if escaping { escaping = false } else if ch == "\\" { escaping = true } else if ch == "\"" { return at }
            at = raw.index(after: at)
        }
        return nil
    }

    /// A list: [a, b] on the key's line, or "- a" lines under it, or a
    /// single plain value.
    static func list(_ lines: [String]) -> [String] {
        guard let first = lines.first, let colon = first.firstIndex(of: ":") else { return [] }
        let raw = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            var items: [String] = []
            var current = ""
            var quote: Character?
            for ch in raw.dropFirst().dropLast() {
                if let q = quote {
                    current.append(ch)
                    if ch == q { quote = nil }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                    current.append(ch)
                } else if ch == "," {
                    items.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            items.append(current)
            return items.map { scalarValue($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        }
        if !raw.isEmpty { return [scalarValue(raw)] }
        return lines.dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return scalarValue(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
    }

    /// `key: value` one level under a field: generated's at, say.
    static func nested(_ key: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return scalarValue(trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// A value written so YAML reads it back as the same string: quoted
    /// where it would otherwise mean something else. The same rule OKF's
    /// own writer follows.
    static func scalar(_ s: String) -> String {
        let special = CharacterSet(charactersIn: ":#{}[]|>&*!,?\"'\\").union(.newlines)
        let quoted = s.isEmpty
            || s.unicodeScalars.contains(where: { special.contains($0) })
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || ["true", "false", "null", "~"].contains(s.lowercased())
            || Double(s) != nil || Int(s) != nil
        guard quoted else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // ISO 8601 with or without fractions of a second, or a bare date at
    // midnight UTC: what OKF reads.
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        return plain.date(from: text) ?? fractional.date(from: text) ?? day.date(from: text)
    }

    static func dateText(_ date: Date) -> String { plain.string(from: date) }
}

// MARK: - The outline

/// _catalog.md's body: a nested list of `[title](items/….md)` lines, then
/// the trash's list under "## Trash".
enum Outline {
    /// The live tree and the trash's. The first list before "## Trash" is
    /// the catalog; the first after it, the trash; any other heading ends
    /// the trash. Lines that name no concept file are sections.
    static func parse(_ body: String, concepts: [String: CatalogConcept]) -> (live: [CatalogNode], trash: [CatalogNode]) {
        var live: [CatalogNode]?
        var trashed: [CatalogNode]?
        var inTrash = false
        // The list being read: its rows, and each open row's indent.
        var rows: [CatalogNode] = []
        var stack: [(indent: Int, node: CatalogNode)] = []
        var reading = false

        func finish() {
            guard reading else { return }
            if inTrash { if trashed == nil { trashed = rows } } else if live == nil { live = rows }
            rows = []
            stack = []
            reading = false
        }

        for raw in body.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                finish()
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                inTrash = hashes == 2 && text == "Trash"
                continue
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            guard let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " else {
                // Text that isn't a row: a paragraph ends the list, and one
                // indented under a row continues it.
                if indent == 0 { finish() }
                continue
            }
            let node = row(String(trimmed.dropFirst(2)), concepts: concepts)
            // Taken only from the first list in each region.
            if !reading {
                if inTrash ? trashed != nil : live != nil { continue }
                reading = true
            }
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if let parent = stack.last?.node { parent.append(node) } else { rows.append(node) }
            stack.append((indent, node))
        }
        finish()
        return (live ?? [], trashed ?? [])
    }

    /// One row's text: a link to a concept file — a [x] before it, as a
    /// checklist writes, allowed — or a section's words.
    private static func row(_ text: String, concepts: [String: CatalogConcept]) -> CatalogNode {
        var text = text.trimmingCharacters(in: .whitespaces)
        if let box = text.range(of: #"^\[[ xX]\]\s+"#, options: .regularExpression) { text.removeSubrange(box) }
        if text.hasPrefix("["), let link = link(in: text), let concept = concepts[link.path] {
            return CatalogNode(concept: concept)
        }
        if text.hasPrefix("["), let link = link(in: text) { return CatalogNode(section: link.title) }
        return CatalogNode(section: unescaped(text))
    }

    /// `[title](path)` at the start of the text.
    private static func link(in text: String) -> (title: String, path: String)? {
        var depth = 0
        var escaping = false
        var close: String.Index?
        for at in text.indices {
            let ch = text[at]
            if escaping { escaping = false; continue }
            if ch == "\\" { escaping = true; continue }
            if ch == "[" { depth += 1 }
            if ch == "]" { depth -= 1; if depth == 0 { close = at; break } }
        }
        guard let close else { return nil }
        let rest = text[text.index(after: close)...]
        guard rest.hasPrefix("("), let end = rest.firstIndex(of: ")") else { return nil }
        let title = String(text[text.index(after: text.startIndex)..<close])
        var path = String(rest[rest.index(after: rest.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        return (unescaped(title), path.removingPercentEncoding ?? path)
    }

    static func lines(_ nodes: [CatalogNode], indent: String = "") -> [String] {
        nodes.flatMap { node -> [String] in
            let line: String = if let concept = node.concept {
                "\(indent)- [\(escaped(concept.shownTitle))](\(concept.id))"
            } else {
                "\(indent)- \(node.text)"
            }
            return [line] + lines(node.children, indent: indent + "  ")
        }
    }

    static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unescaped(_ text: String) -> String {
        var out = ""
        var escaping = false
        for ch in text {
            if escaping { out.append(ch); escaping = false } else if ch == "\\" { escaping = true } else { out.append(ch) }
        }
        return out
    }
}

// MARK: - The bundle

extension Catalog {
    /// Names OKF keeps for itself: never a concept, wherever they are.
    static let reserved: Set<String> = [catalogFile, indexFile, "log.md"]

    /// A catalog read from its folder. A file it doesn't use — an image
    /// beside the notes, a log — stays where it is, untouched by saving.
    convenience init(bundle: FileWrapper) {
        var items: [String: String] = [:]
        var trashed: [String: String] = [:]
        var parkedAt: [String: String] = [:]
        let hasItems = bundle.fileWrappers?["items"]?.isDirectory == true
        for (path, wrapper) in Catalog.files(in: bundle) where path.hasSuffix(".md") {
            let name = (path as NSString).lastPathComponent
            guard !Catalog.reserved.contains(name),
                  let data = wrapper.regularFileContents, let text = String(data: data, encoding: .utf8) else { continue }
            if path.hasPrefix("trash/") {
                // Older catalogs parked items/<name> as trash/<name>.
                let inside = String(path.dropFirst(6))
                let id = !inside.contains("/") && hasItems ? "items/\(inside)" : inside
                trashed[id] = text
                parkedAt[id] = path
            } else {
                items[path] = text
            }
        }
        let text = Catalog.text(bundle.fileWrappers?[Catalog.catalogFile])
            ?? Catalog.text(bundle.fileWrappers?[Catalog.indexFile])
        self.init(catalog: text, items: items, trashed: trashed)
        for id in items.keys { readFrom[id] = id }
        for (id, path) in parkedAt where readFrom[id] == nil { readFrom[id] = path }
    }

    private static func text(_ wrapper: FileWrapper?) -> String? {
        wrapper?.regularFileContents.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Every file in the folder, by its path inside it.
    static func files(in folder: FileWrapper, under prefix: String = "") -> [(String, FileWrapper)] {
        guard let children = folder.fileWrappers else { return [] }
        return children.flatMap { name, wrapper -> [(String, FileWrapper)] in
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if wrapper.isDirectory { return files(in: wrapper, under: path) }
            return wrapper.isRegularFile ? [(path, wrapper)] : []
        }
    }

    /// `bundle` brought up to date with a save: the catalog and the listing
    /// written, changed concept files replaced, moved ones moved, and those
    /// gone from the catalog removed. Nothing else in it is touched.
    func update(_ bundle: FileWrapper, with output: Output) {
        Catalog.put(Data(output.catalog.utf8), at: Catalog.catalogFile, in: bundle)
        Catalog.put(Data(output.index.utf8), at: Catalog.indexFile, in: bundle)
        for (path, text) in output.files {
            Catalog.put(Data(text.utf8), at: path, in: bundle)
        }
        for path in Set(readFrom.values).subtracting(output.kept) {
            Catalog.remove(path, in: bundle)
        }
    }

    private static func put(_ data: Data, at path: String, in bundle: FileWrapper) {
        var parts = path.split(separator: "/").map(String.init)
        let name = parts.removeLast()
        var folder = bundle
        for part in parts {
            if let existing = folder.fileWrappers?[part], existing.isDirectory {
                folder = existing
            } else {
                if let existing = folder.fileWrappers?[part] { folder.removeFileWrapper(existing) }
                let made = FileWrapper(directoryWithFileWrappers: [:])
                made.preferredFilename = part
                folder.addFileWrapper(made)
                folder = made
            }
        }
        if let existing = folder.fileWrappers?[name] {
            if existing.regularFileContents == data { return }
            folder.removeFileWrapper(existing)
        }
        folder.addRegularFile(withContents: data, preferredFilename: name)
    }

    private static func remove(_ path: String, in bundle: FileWrapper) {
        var parts = path.split(separator: "/").map(String.init)
        let name = parts.removeLast()
        var folder = bundle
        for part in parts {
            guard let next = folder.fileWrappers?[part], next.isDirectory else { return }
            folder = next
        }
        if let existing = folder.fileWrappers?[name] { folder.removeFileWrapper(existing) }
    }
}
