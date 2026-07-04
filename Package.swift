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
        .target(name: "AnnotateKit")
    ]
)
