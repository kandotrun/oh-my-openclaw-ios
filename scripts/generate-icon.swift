import Foundation

// Export previews with Apple's native renderer. App/AppIcon.icon is the source
// of truth; this script never draws or flattens the app's shipping icon assets.
@discardableResult
func run(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "IconPreview", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
}

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
let developerPath: String
if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
    developerPath = configured
} else {
    developerPath = try run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
let renderer = URL(fileURLWithPath: developerPath).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
guard FileManager.default.isExecutableFile(atPath: renderer.path) else {
    fatalError("Select an Xcode installation containing Icon Composer with xcode-select or DEVELOPER_DIR.")
}
let document = repository.appendingPathComponent("App/AppIcon.icon")
let directory = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? repository.appendingPathComponent("build/icon-previews")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let supportsGenerations = try run(renderer, ["--help"]).contains("--design-generation")
let generations: [String?] = supportsGenerations ? ["26", "27"] : [nil]
for generation in generations {
    for rendition in ["Default", "Dark", "TintedDark"] {
        let label = generation ?? "native"
        let output = directory.appendingPathComponent("AppIcon-\(label)-\(rendition).png")
        var arguments = [document.path, "--export-image", "--output-file", output.path,
                         "--platform", "iOS", "--rendition", rendition,
                         "--width", "1024", "--height", "1024", "--scale", "1"]
        if let generation { arguments += ["--design-generation", generation] }
        if rendition == "TintedDark" {
            arguments += ["--tint-color", "0.08", "--tint-strength", "0.75"]
        }
        try run(renderer, arguments)
        print(output.path)
    }
}
