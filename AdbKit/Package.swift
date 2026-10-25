// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AdbKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AdbKit", targets: ["AdbKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
    ],
    targets: [
        .target(
            name: "CAdbCrypto",
            dependencies: [.product(name: "NIOSSL", package: "swift-nio-ssl")]
        ),
        .target(name: "CAdbZlib", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "AdbKit", dependencies: ["CAdbCrypto", "CAdbZlib"]),
        .executableTarget(name: "adbkit-cli", dependencies: ["AdbKit"]),
    ]
)
