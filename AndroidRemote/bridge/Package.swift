// swift-tools-version:5.9
import PackageDescription

// libAdbBridge.so: AdbKit for the Android app. Kotlin calls it through one JNI function
// (Native.call) with a JSON request; see Sources/AdbBridge/Bridge.swift.
let package = Package(
    name: "AdbBridge",
    products: [
        .library(name: "AdbBridge", type: .dynamic, targets: ["AdbBridge"]),
    ],
    dependencies: [
        .package(path: "../../AdbKit"),
    ],
    targets: [
        .target(name: "CAdbBridgeJNI"),
        .target(name: "AdbBridge", dependencies: ["CAdbBridgeJNI", .product(name: "AdbKit", package: "AdbKit")]),
    ]
)
