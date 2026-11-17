// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OhMyOpenClaw",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "OhMyOpenClawCore", targets: ["OhMyOpenClawCore"])],
    targets: [
        .target(name: "OhMyOpenClawCore"),
        .target(name: "OhMyOpenClawState", dependencies: ["OhMyOpenClawCore"], path: "App", exclude: ["AppIcon.icon", "Assets.xcassets", "Input", "Views", "OhMyOpenClawApp.swift", "PrivacyInfo.xcprivacy"], sources: ["AppModel.swift", "CredentialStore.swift", "ChatLayout.swift"]),
        .target(name: "OhMyOpenClawInput", path: "App/Input", exclude: ["AttachmentLoader.swift", "DictationController.swift", "QRScannerView.swift"], sources: ["DictationCallbacks.swift", "DictationLanguage.swift"]),
        .testTarget(name: "OhMyOpenClawCoreTests", dependencies: ["OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawStateTests", dependencies: ["OhMyOpenClawState", "OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawInputTests", dependencies: ["OhMyOpenClawInput"]),
    ]
)
