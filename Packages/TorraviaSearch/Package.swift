// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TorraviaSearch", platforms: [.macOS(.v14)],
    products: [.library(name: "TorraviaSearchCore", targets: ["TorraviaSearchCore"])],
    targets: [.target(name: "TorraviaSearchCore", swiftSettings: [.defaultIsolation(MainActor.self)])],
    swiftLanguageModes: [.v5])
