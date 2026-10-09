// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SubtitleGen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SubGen", targets: ["SubtitleGen"])
    ],
    targets: [
        .executableTarget(
            name: "SubtitleGen",
            path: "SubtitleGen",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "SubtitleGenTests",
            dependencies: ["SubtitleGen"],
            path: "Tests"
        )
    ]
)
