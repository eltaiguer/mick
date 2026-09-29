// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PanelSpike",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PanelSpikeKit", targets: ["PanelSpikeKit"]),
        .executable(name: "panel-spike", targets: ["panel-spike"]),
    ],
    targets: [
        .target(name: "PanelSpikeKit"),
        .executableTarget(name: "panel-spike", dependencies: ["PanelSpikeKit"]),
        .testTarget(name: "PanelSpikeKitTests", dependencies: ["PanelSpikeKit"]),
    ],
    swiftLanguageModes: [.v6]
)
