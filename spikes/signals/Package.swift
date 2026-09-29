// swift-tools-version: 6.2
// Throwaway spike for issue #2 (SPEC.md §6.3, §9.3 items 5-7).
import PackageDescription

let package = Package(
    name: "SignalsSpike",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SignalsSpike", targets: ["SignalsSpike"]),
    ],
    targets: [
        .target(name: "SignalsKit"),
        .executableTarget(name: "SignalsSpike", dependencies: ["SignalsKit"]),
        .testTarget(name: "SignalsKitTests", dependencies: ["SignalsKit"]),
    ],
    swiftLanguageModes: [.v6]
)
