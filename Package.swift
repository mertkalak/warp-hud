// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WarpHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WarpHUD",
            path: "WarpHUD"
        )
    ]
)
