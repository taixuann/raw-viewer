// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RawView",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RawView", targets: ["RawViewApp"])],
    targets: [
        .target(name: "RawViewCore"),
        .executableTarget(name: "RawViewApp", dependencies: ["RawViewCore"], resources: [.process("Resources")]),
        .testTarget(name: "RawViewCoreTests", dependencies: ["RawViewCore"])
    ],
    swiftLanguageModes: [.v5]
)
