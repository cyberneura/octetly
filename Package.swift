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
        // The parsing the app depends on, tested without launching it. A test
        // target may depend on an executable target since Swift 5.5.
        .testTarget(
            name: "OctetlyTests",
            dependencies: ["Octetly"],
            path: "Tests/OctetlyTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
