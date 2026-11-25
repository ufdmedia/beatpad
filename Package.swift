// swift-tools-version: 5.9
import PackageDescription
import Foundation

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "beatpad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "beatpad", linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                          "-Xlinker", "__info_plist", "-Xlinker", directory + "/Support/Info.plist"])
        ])
    ]
)
