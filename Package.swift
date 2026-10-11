// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RawView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RawView", targets: ["RawViewApp"]),
        .executable(name: "rawview-index", targets: ["RawViewIndexCLI"])
    ],
    targets: [
        .target(name: "RawViewCore"),
        .executableTarget(name: "RawViewApp", dependencies: ["RawViewCore"], resources: [.process("Resources")]),
        .executableTarget(name: "RawViewIndexCLI", dependencies: ["RawViewCore"]),
        .testTarget(name: "RawViewCoreTests", dependencies: ["RawViewCore"])
    ],
    swiftLanguageModes: [.v5]
)
