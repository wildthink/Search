# Surfboard: WildThink's fork of Search

This repository is [Search](https://github.com/driceroland/Search), the browser,
as WildThink, LLC builds and ships it: **Surfboard**. It is Search, plus
Surfboard's catalogs — `.surfboard` bundles of sites, files, people and places,
opened in a tab of their own — under WildThink's name and bundle identifier.

The fork is laid out so upstream's work keeps coming in. Read this before
changing a file upstream owns.

## Remotes

| Remote     | Repository                                   | Role |
|------------|----------------------------------------------|------|
| `origin`   | `git@github.com:wildthink/Search.git`        | WildThink's fork; `main` is Surfboard |
| `upstream` | `https://github.com/driceroland/Search.git`  | Search itself |

## What is the fork's own

- **`Sources/Search/Surfboard/`** — everything Surfboard adds:
  - `Brand.swift` — the name, bundle identifier, data folder and update feed.
  - `Catalog.swift` — reading and writing catalogs (the OKF format).
  - `CatalogDocument.swift`, `CatalogDetail.swift` — the catalog's tab.
  - `SurfboardCommands.swift` — Bookmarks › Add Page to Catalog (⇧⌘D) and New Catalog…
  - `CatalogBench.swift` — `bench catalog ID …`.
- **`brand/`** — what `build.sh` builds Surfboard as: `brand.sh` (name,
  identifier, copyright) and the Info.plist additions for the `.surfboard` type.
  Delete the folder and `build.sh` builds upstream's Search unchanged.
- **`Tests/SearchTests/Catalog*.swift`** — the catalog's unit tests.
- **`Tests/OKFConformance/`** — Search's catalog code checked against
  [OKFFormat](https://github.com/wildthink/OKFFormat), the format's own
  implementation (see its README).
- **`FORK.md`** — this file.

New Surfboard features go in `Sources/Search/Surfboard/`, not into upstream's
files. Swift sees the folder as part of the same target, so nothing has to be
registered anywhere.

## Where upstream's files are touched

Each place is marked with a comment starting `Surfboard:`, and kept to a line or
two that calls into the fork's own code:

    git grep -n "Surfboard:"

| File | Why |
|------|-----|
| `build.sh` | The brand's name, identifier and copyright in the Info.plist; the `.surfboard` type merged in |
| `Sources/Search/Store.swift` | The brand's own data folder (`~/Library/Application Support/Surfboard`) and identifier |
| `Sources/Search/Updater.swift` | No update checks until the brand has a feed of its own |
| `Sources/Search/App.swift` | The window's name; the catalog items in the Bookmarks menu |
| `Sources/Search/Shortcuts.swift` | The fork's commands, listed with upstream's |
| `Sources/Search/TabContent.swift` | A `.surfboard` folder opens as a catalog |
| `Sources/Search/Browser.swift` | ⌘O offers catalogs |
| `Sources/Search/Bench.swift`, `bench` | `bench catalog` |
| `Sources/Search/AIClient.swift`, `Passkeys.swift` | Logged under the brand's identifier |
| `fresh.sh`, `Tests/split_view.py` | WebKit's folder is named for the bundle identifier |
| `Search.passkeys.entitlements` | WildThink's team (8S7Y6KVRU5) and identifier |

Names that are upstream's and stay so, on purpose: the `Search` target and
executable, `build/Search.app` (the bench and every script find the app
there), the test worlds' `Search (NAME)` folders, and `com.officecommun.search.*`
keychain service names (renaming them would lose saved keys).

## Taking upstream's changes

    git fetch upstream
    git switch -c upstream-sync main
    git merge upstream/main          # conflicts, if any, are at the Surfboard: lines
    ./build.sh debug && swift test && Tests/OKFConformance/run.sh
    # then merge upstream-sync into main

Merge rather than rebase: the fork's history is published, and a merge keeps
each upstream release visible as one step.

## Changes that could go back upstream

Some of the fork's work isn't Surfboard-specific and was written in upstream's
own style, in upstream's files, so it can be offered back as pull requests:

- Documents in tabs: Markdown, JSON, SQLite, spreadsheets (`TabContent.swift`, `DatabaseDocument.swift`, `PreviewDocument.swift`, `JSONTree.swift`)
- Local files opened from anywhere (`Browser.swift`, `Tab.swift`)
- Apple Intelligence as an AI provider (`AppleModel.swift`)
- The debug build for the bench, and the split of `Bench.handle`

Keep those free of `Brand` and of anything in `Surfboard/`, so they stay
offerable.

## Before shipping as Surfboard

- The prose still says "Search" in places: messages, Settings, permission
  prompts in `build.sh`'s Info.plist. Name them through `Brand.name` as they
  are touched.
- A Developer ID and a provisioning profile from WildThink's team, for signing
  and passkeys (`Search.passkeys.entitlements` already names the team).
- An update feed of WildThink's own (`Brand.feed`), and `build.sh`'s
  `SEARCH_DOWNLOAD_URL` pointed at it.
- Private Cloud Compute, if wanted: the entitlement request names
  `com.wildthink.surfboard`.
