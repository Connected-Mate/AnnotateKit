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
                // binary) never contain the symbol. Without it SwiftUI may not
                // materialise its accessibility tree at all (observed on iOS 26
                // and 27 devices): capture then falls back to the UIKit view
                // chain plus render-tree fragments, losing element identity.
                .define("PRIVATE_AX", .when(configuration: .debug))
            ]
        )
    ]
)
