// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextNote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ContextNote", targets: ["ContextNote"])],
    targets: [.executableTarget(name: "ContextNote")]
)
