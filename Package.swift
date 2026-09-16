// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "VromaCut",
    platforms: [.macOS(.v15)],
    products: [.library(name: "VromaCutCore", targets: ["VromaCutCore"]),
               .executable(name: "VromaCut", targets: ["VromaCutApp"])],
    targets: [
        .target(name: "CLibAVBridge", cSettings: [.unsafeFlags(["-I", root + "/.build/libav/include"])],
                linkerSettings: [.unsafeFlags(["-L", root + "/.build/libav/lib"]),
                                 .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"), .linkedLibrary("m")]),
        .target(name: "VromaCutCore", dependencies: ["CLibAVBridge"]),
        .executableTarget(name: "VromaCutApp", dependencies: ["VromaCutCore"]),
        .testTarget(name: "VromaCutCoreTests", dependencies: ["VromaCutCore"]),
        .testTarget(name: "VromaCutAppTests", dependencies: ["VromaCutApp"])])
