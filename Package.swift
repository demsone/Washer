// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Washer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Washer", targets: ["Washer"])],
    targets: [.executableTarget(name: "Washer")]
)
