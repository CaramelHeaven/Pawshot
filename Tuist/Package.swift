// swift-tools-version: 6.0
import PackageDescription

/// Third-party code, fetched by `tuist install` (the Makefile's `generate` runs it). Sparkle is
/// the one dependency: updates from GitHub Releases, so a new build arrives without Gatekeeper.
let package = Package(
    name: "Pawshot",
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ]
)
