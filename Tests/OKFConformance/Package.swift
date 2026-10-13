// swift-tools-version: 6.0
// Search's catalog code (Sources/Search/Surfboard/Catalog.swift, linked in
// here) against OKFFormat, the format's own implementation: whatever one
// writes, the other reads the same. Run ./run.sh. OKF_FORMAT_PATH points at a
// checkout to test against one that isn't pushed yet.
import PackageDescription

let okf: Package.Dependency = if let path = Context.environment["OKF_FORMAT_PATH"] {
    .package(path: path)
} else {
    .package(url: "https://github.com/wildthink/OKFFormat.git", branch: "main")
}

let package = Package(
    name: "OKFConformance",
    platforms: [.macOS(.v14)],
    dependencies: [okf],
    targets: [
        .executableTarget(
            name: "Conformance",
            dependencies: [.product(name: "OKFFormat", package: "OKFFormat")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
