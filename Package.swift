// swift-tools-version:6.2
import Foundation
import PackageDescription

let package = Package(
    name: "fmgrep",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "fmgrep",
            path: "Sources/fmgrep",
            linkerSettings: [
                // Embed a bundle identifier so the on-device Apple Foundation
                // Model will serve requests from a plain command-line binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/Info.plist",
                ]),
            ]
        )
    ]
)
