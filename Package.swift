// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrowserSelector",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BrowserSelectorCore", targets: ["BrowserSelectorCore"]),
        .executable(name: "BrowserSelector", targets: ["BrowserSelector"])
    ],
    targets: [
        .target(
            name: "BrowserSelectorCore",
            path: "Sources/BrowserSelectorCore"
        ),
        .executableTarget(
            name: "BrowserSelector",
            dependencies: ["BrowserSelectorCore"],
            path: "Sources/BrowserSelector"
        ),
        .testTarget(
            name: "BrowserSelectorCoreTests",
            dependencies: ["BrowserSelectorCore"],
            path: "Tests/BrowserSelectorCoreTests"
        )
    ]
)
