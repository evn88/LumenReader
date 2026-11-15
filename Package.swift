// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScanReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScanReader",
            path: "Sources/ScanReader"
        ),
        .testTarget(
            name: "ScanReaderTests",
            dependencies: ["ScanReader"],
            path: "Tests/ScanReaderTests"
        ),
    ]
)
