// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Basset",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "Basset", targets: ["Basset"]),
        .library(name: "BassetAttached", targets: ["BassetAttached"]),
    ],
    targets: [
        .target(
            name: "BassetECS",
            path: "Sources/BassetECS"
        ),
        .target(
            name: "CBassetAtomics",
            path: "Sources/CBassetAtomics"
        ),
        .target(
            name: "Basset",
            dependencies: ["BassetECS", "CBassetAtomics"],
            path: "Sources/Basset",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "BassetAttached",
            dependencies: ["Basset"],
            path: "Sources/BassetAttached"
        ),
        .executableTarget(name: "BassetDemo", dependencies: ["Basset"], path: "Demo"),
        .testTarget(
            name: "BassetTests",
            dependencies: ["Basset", "BassetAttached", "BassetECS"],
            path: "Tests",
            exclude: ["ECS"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
