// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Shiying",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "Shiying",
            targets: ["Shiying"]
        ),
        .library(
            name: "ShiyingShare",
            targets: ["ShiyingShare"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/YouTubeKit"),
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.68-f381f4b3"),
    ],
    targets: [
        .target(
            name: "Shiying",
            dependencies: [
                .product(name: "YouTubeKit", package: "YouTubeKit"),
                .product(name: "TDLibKit", package: "TDLibKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-headerpad_max_install_names",
                ]),
            ]
        ),
        .target(
            name: "ShiyingShare",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-headerpad_max_install_names",
                    "-Xlinker", "-all_load",
                ]),
            ]
        ),
    ]
)
