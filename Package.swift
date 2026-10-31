// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Utter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UtterCore"),
        .target(name: "ObjCCatch"),
        .executableTarget(name: "Utter", dependencies: ["UtterCore", "ObjCCatch"]),
        .executableTarget(name: "utter-bench", dependencies: ["UtterCore"]),
        .executableTarget(name: "TestPad"),
        .testTarget(name: "UtterCoreTests", dependencies: ["UtterCore"]),
        .testTarget(name: "UtterAppTests", dependencies: ["Utter"]),
    ]
)
