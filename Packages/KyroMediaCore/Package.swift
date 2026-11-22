// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KyroMediaCore",
    platforms: [.iOS(.v18), .macOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "KyroFoundation", targets: ["KyroFoundation"]),
        .library(name: "KyroIdentity", targets: ["KyroIdentity"]),
        .library(name: "KyroLedger", targets: ["KyroLedger"]),
        .library(name: "KyroCatalog", targets: ["KyroCatalog"]),
        .library(name: "KyroMatching", targets: ["KyroMatching"]),
        .library(name: "KyroSources", targets: ["KyroSources"]),
        .library(name: "KyroPlayback", targets: ["KyroPlayback"]),
        .library(name: "KyroCapabilities", targets: ["KyroCapabilities"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "KyroFoundation", dependencies: ["CSQLite"]),
        .target(name: "KyroIdentity", dependencies: ["KyroFoundation"]),
        .target(name: "KyroLedger", dependencies: ["KyroFoundation"]),
        .target(name: "KyroCatalog", dependencies: ["KyroFoundation"]),
        .target(name: "KyroMatching", dependencies: ["KyroFoundation", "KyroCatalog"]),
        .target(name: "KyroSources", dependencies: ["KyroFoundation", "KyroCatalog"]),
        .target(name: "KyroPlayback", dependencies: ["KyroFoundation"]),
        .target(name: "KyroCapabilities", dependencies: ["KyroFoundation"]),
        .testTarget(name: "KyroMediaCoreTests", dependencies: ["KyroFoundation", "KyroIdentity", "KyroLedger", "KyroCatalog", "KyroMatching", "KyroSources", "KyroPlayback", "KyroCapabilities"], path: "Tests/KyroMediaCoreTests")
    ],
    swiftLanguageModes: [.v6]
)
