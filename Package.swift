// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        // Claude Code's status line command, shipped inside the app bundle.
        .executable(name: "usagebar-statusline", targets: ["StatusLine"]),
    ],
    targets: [
        // Pure usage engine: readings + clock in, snapshot out. No I/O.
        .target(name: "UsageCore"),
        // Thin app shell: status item, popover, snapshot mode, launch at login.
        .executableTarget(name: "UsageBar", dependencies: ["UsageCore"]),
        // Small command Claude Code runs after each reply: saves the rate
        // limits for the app and prints a compact line. Also installs itself.
        .executableTarget(name: "StatusLine", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
