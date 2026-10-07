// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiniNotes",
            path: "Sources/MiniNotes",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
