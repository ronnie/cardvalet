// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "CardValet",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "CardValet", path: "Sources/CardValet")]
)
