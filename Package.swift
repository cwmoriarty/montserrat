// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "montserrat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MontserratCore",
            targets: ["MontserratCore"]
        ),
        .library(
            name: "CExt2FS",
            targets: ["CExt2FS"]
        ),
        .library(
            name: "CLegacyFS",
            targets: ["CLegacyFS"]
        ),
        .library(
            name: "MontserratFSKit",
            targets: ["MontserratFSKit"]
        ),
        .executable(
            name: "montserrat",
            targets: ["montserrat"]
        ),
        .executable(
            name: "montserratd",
            targets: ["montserratd"]
        ),
        .executable(
            name: "MontserratApp",
            targets: ["MontserratApp"]
        ),
        .executable(
            name: "MontserratFSKitExtension",
            targets: ["MontserratFSKitExtension"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CExt2FS",
            dependencies: [],
            path: "Sources/CExt2FS",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../engines/out/include"),
                .headerSearchPath("../../engines/out/include/ext2fs")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + packageDir + "/engines/out/lib",
                    "-lext2fs",
                    "-lcom_err",
                    "-le2p"
                ])
            ]
        ),
        .target(
            name: "CLegacyFS",
            dependencies: [],
            path: "Sources/CLegacyFS",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../engines/out/include")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + packageDir + "/engines/out/lib",
                    "-llegacyfs",
                    "-lz"
                ])
            ]
        ),
        .target(
            name: "MontserratCore",
            dependencies: ["CLegacyFS"],
            path: "Sources/MontserratCore"
        ),
        .target(
            name: "MontserratFSKit",
            dependencies: ["MontserratCore", "CExt2FS", "CLegacyFS"],
            path: "Sources/MontserratFSKit",
            exclude: ["Resources/Info.plist"]
        ),
        .executableTarget(
            name: "montserrat",
            dependencies: ["MontserratCore"],
            path: "Sources/montserrat"
        ),
        .executableTarget(
            name: "montserratd",
            dependencies: ["MontserratCore"],
            path: "Sources/montserratd"
        ),
        .executableTarget(
            name: "MontserratApp",
            dependencies: ["MontserratCore"],
            path: "Sources/MontserratApp",
            exclude: ["Montserrat.entitlements"]
        ),
        .executableTarget(
            name: "MontserratFSKitExtension",
            dependencies: ["MontserratFSKit"],
            path: "Sources/MontserratFSKitExtension",
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "MontserratCoreTests",
            dependencies: ["MontserratCore", "MontserratFSKit"],
            path: "Tests/MontserratCoreTests"
        )
    ]
)
