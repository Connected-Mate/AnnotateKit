// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnnotateKit",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17)
    ],
    products: [
        .library(name: "AnnotateKit", targets: ["AnnotateKit"])
    ],
    targets: [
        .target(
            name: "AnnotateKit",
            swiftSettings: [
                // The private accessibility-automation switch is compiled only
                // into debug builds — release builds (including any App Store
                // binary) never contain the symbol. iOS 26+ exposes the SwiftUI
                // accessibility tree without it.
                .define("PRIVATE_AX", .when(configuration: .debug))
            ]
        )
    ]
)
