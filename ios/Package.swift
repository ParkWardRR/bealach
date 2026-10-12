// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bealach",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "BealachCore", targets: ["BealachCore"]),
        .library(name: "BealachRuntime", targets: ["BealachRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BealachCore",
            dependencies: []
        ),
        .target(
            name: "BealachRuntime",
            dependencies: [
                "BealachCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BealachCoreTests",
            dependencies: ["BealachCore"]
        ),
        .testTarget(
            name: "BealachRuntimeTests",
            dependencies: [
                "BealachRuntime",
                "BealachCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
