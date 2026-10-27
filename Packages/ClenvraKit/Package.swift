// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "ClenvraKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ClenvraKit", targets: ["ClenvraKit"])
    ],
    targets: [
        .target(
            name: "ClenvraKit",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ClenvraKitTests",
            dependencies: ["ClenvraKit"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
