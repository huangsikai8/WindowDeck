// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowDeck",
            path: "Sources/WindowDeck",
            // Language mode 5: the Accessibility API hands us C callbacks and
            // opaque AXUIElement refs that don't carry Sendable annotations.
            // Strict 6 concurrency fights that for no safety gain here — every
            // call site is already confined to the main actor.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
