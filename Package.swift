// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScanReader",
    platforms: [.macOS(.v14)],
    dependencies: [
        // автообновление, как в PangoZip (та же версия)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "ScanReader",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ScanReader",
            linkerSettings: [
                // Sparkle.framework кладётся в Contents/Frameworks бандла (scripts/make-app.sh)
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "ScanReaderTests",
            dependencies: ["ScanReader"],
            path: "Tests/ScanReaderTests"
        ),
    ]
)
