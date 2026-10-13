import Foundation

// WildThink's build of Search is Surfboard: the browser, plus catalogs —
// Surfboard's .surfboard bundles, opened in a tab of their own (Catalog.swift,
// CatalogDocument.swift). Everything that is the fork's own lives in this
// folder. Upstream's files are touched only where they have to be, each place
// marked with a comment that starts "Surfboard:", so `git grep -n Surfboard:`
// lists every one — FORK.md says why each is there and how upstream's changes
// come in.

enum Brand {
    /// What the app is called. The Info.plist's name comes from brand/brand.sh;
    /// this is for the places the app says it itself.
    static let name = "Surfboard"

    /// The bundle identifier the shipped app runs under (brand/brand.sh).
    /// A copy under any other is a test copy (Store.ownContainer).
    static let identifier = "com.wildthink.surfboard"

    /// ~/Library/Application Support/<folder>: the session, history, pins and
    /// bookmarks. Its own, not upstream Search's "Search", so the two can be
    /// installed side by side without writing over each other's tabs. Test
    /// worlds keep upstream's "Search (<world>)" names, which the bench and
    /// the scripts in Tests/ know.
    static let folder = "Surfboard"

    /// Where updates are announced. None yet: until WildThink signs and
    /// publishes its own builds, Surfboard doesn't update itself — upstream's
    /// feed offers Office Commun's builds, which the updater would refuse
    /// anyway (their bundle identifier isn't this one).
    static let feed: URL? = nil
}
