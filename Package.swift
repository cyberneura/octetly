// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Octetly",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Octetly", targets: ["Octetly"])],
    targets: [
        .executableTarget(
            name: "Octetly",
            path: "Sources/octetly",
            resources: [.process("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
