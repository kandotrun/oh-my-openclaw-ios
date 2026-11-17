// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OhMyOpenClaw",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "OhMyOpenClawCore", targets: ["OhMyOpenClawCore"])],
    targets: [
        .target(name: "OhMyOpenClawCore"),
        .target(name: "OhMyOpenClawState", dependencies: ["OhMyOpenClawCore"], path: "App", exclude: ["Assets.xcassets", "Input", "Views", "OhMyOpenClawApp.swift", "PrivacyInfo.xcprivacy"], sources: ["AppModel.swift", "CredentialStore.swift", "ChatLayout.swift"]),
        .testTarget(name: "OhMyOpenClawCoreTests", dependencies: ["OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawStateTests", dependencies: ["OhMyOpenClawState", "OhMyOpenClawCore"]),
    ]
)
