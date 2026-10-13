# WildThink's build of Search, shipped as Surfboard. build.sh reads this file
# when it is there; without it, build.sh builds upstream's Search unchanged.
# See FORK.md for what else differs and how upstream's changes come in.

# What the app is called in the menu bar, the Dock and the Finder's Get Info,
# and the identity macOS keeps its settings, its WebKit data and its keychain
# items under. The executable inside stays "Search", and so does the folder
# build.sh writes (build/Search.app): the bench, fresh.sh and Tests/*.py find
# the app there, and renaming it would make every upstream change to them a
# conflict here.
BRAND_NAME="Surfboard"
BRAND_ID="com.wildthink.surfboard"
BRAND_COPYRIGHT="© WildThink, LLC · Surfboard, from Search by Office Commun"

# Merged into the Info.plist build.sh writes: the .surfboard catalog type,
# declared here and opened by Sources/Search/Surfboard/CatalogDocument.swift.
BRAND_DOCUMENT_TYPES="brand/DocumentTypes.plist"
BRAND_EXPORTED_TYPES="brand/ExportedTypes.plist"
