// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "typeno-agent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TypeNoAgent", targets: ["TypeNoAgent"])
    ],
    targets: [
        .executableTarget(
            name: "TypeNoAgent",
            path: "Sources/Typeno",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "App/Info.plist"
                ])
            ]
        )
    ]
)
