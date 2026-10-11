// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
    ],
    targets: [
        // Pure usage engine: readings + clock in, snapshot out. No I/O.
        .target(name: "UsageCore"),
        // Thin app shell: status item, popover, snapshot mode, launch at login.
        .executableTarget(name: "UsageBar", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
