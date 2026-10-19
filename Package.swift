// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shout",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Shout", targets: ["Shout"]),
        .executable(name: "shout-cli", targets: ["shout-cli"]),
    ],
    targets: [
        // Prebuilt ggml-org frameworks (macOS slice only), Metal-accelerated.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),

        // Speech-to-text engines (whisper.cpp: Whisper + Parakeet).
        .target(name: "ShoutASR", dependencies: ["whisper"]),
        // Local LLM engine (llama.cpp).
        .target(name: "ShoutLLM", dependencies: ["llama"]),
        // Shared, UI-free logic: pipeline, prompts, storage, models catalog.
        .target(name: "ShoutKit", dependencies: ["ShoutASR", "ShoutLLM"],
                linkerSettings: [.linkedLibrary("sqlite3")]),

        .executableTarget(name: "Shout", dependencies: ["ShoutKit"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "shout-cli", dependencies: ["ShoutKit"]),
        .testTarget(name: "ShoutKitTests", dependencies: ["ShoutKit"]),
    ],
    swiftLanguageModes: [.v5]
)
