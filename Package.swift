// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bloomin8",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Bloomin8Widget", targets: ["Bloomin8Widget"]),
        .executable(name: "Bloomin8App", targets: ["Bloomin8App"])
    ],
    targets: [
        // Everything that isn't tied to a particular presentation: the device
        // client, the photo/content controller, settings, BLE wake, and the
        // generated content sources. Shared verbatim by the menu bar widget
        // and the windowed app so fixes land once.
        .target(
            name: "Bloomin8Core",
            path: "Sources/Bloomin8Core"
        ),
        // The menu bar widget: status item + transient popover.
        .executableTarget(
            name: "Bloomin8Widget",
            dependencies: ["Bloomin8Core"],
            path: "Sources/Bloomin8Widget"
        ),
        // The full window app: sidebar + gallery grid.
        .executableTarget(
            name: "Bloomin8App",
            dependencies: ["Bloomin8Core"],
            path: "Sources/Bloomin8App"
        )
    ]
)
