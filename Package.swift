// swift-tools-version: 6.0
import Foundation
import PackageDescription

let cltTestingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingMacros)
    ? [.unsafeFlags(["-load-plugin-library", cltTestingMacros])]
    : []

let package = Package(
    name: "AgentBar",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .executable(name: "AgentBar", targets: ["AgentBar"])
    ],
    targets: [
        .target(
            name: "AgentBarCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentBar",
            dependencies: ["AgentBarCore"]
        ),
        .testTarget(
            name: "AgentBarCoreTests",
            dependencies: ["AgentBarCore"],
            swiftSettings: testSwiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
