// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "COpus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Opus", targets: ["Opus"]),
        .library(name: "COpus", targets: ["COpus"]),
    ],
    targets: [
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: [],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("libopusenc"),
                .define("HAVE_CONFIG_H", to: "1"),
                .unsafeFlags([
                    "-Wno-shorten-64-to-32",
                    "-Wno-unused-function",
                    "-Wno-deprecated-declarations",
                    "-Wno-unused-but-set-variable",
                    "-Wno-implicit-function-declaration",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("m"),
            ]
        ),
        .target(
            name: "Opus",
            dependencies: ["COpus"],
            path: "Sources/Opus"
        ),
    ]
)
