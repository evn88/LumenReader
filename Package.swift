// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScanReader",
    platforms: [.macOS(.v26)],
    dependencies: [
        // автообновление, как в PangoZip (та же версия)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "ScanReader",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ScanReader",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Sparkle.framework кладётся в Contents/Frameworks бандла (scripts/make-app.sh)
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              // CLI из .build (--render и т.п.): Sparkle.framework лежит рядом с бинарником
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        .testTarget(
            name: "ScanReaderTests",
            dependencies: ["ScanReader"],
            path: "Tests/ScanReaderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
