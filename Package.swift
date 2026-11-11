// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "MeetRec", path: "Sources/MeetRec")
    ],
    swiftLanguageModes: [.v5]
)
