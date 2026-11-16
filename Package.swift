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
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "llama"],
            path: "Sources/ScanReader",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Sparkle.framework кладётся в Contents/Frameworks бандла (scripts/make-app.sh)
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              // CLI из .build (--render и т.п.): Sparkle.framework лежит рядом с бинарником
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        // llama.cpp (Metal): локальная модель перевода TranslateGemma для языков, которых нет у системного переводчика
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12428/llama-b12428-xcframework.zip",
            checksum: "43d69839495547c9f449698b4ae29070a11b6b21ce71aa392e15bfa0b0128e1d"
        ),
        .testTarget(
            name: "ScanReaderTests",
            dependencies: ["ScanReader"],
            path: "Tests/ScanReaderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
