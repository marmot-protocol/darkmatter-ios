// swift-tools-version:6.0
import PackageDescription

// Keep the release identifier, immutable tag, checksum, and generated Swift
// source synchronized. `scripts/sync-bindings.sh` updates them together from a
// published MarmotKit release.
let marmotKitReleaseID = "snapshot-4e056e708afeb86fb4e62049b73c8ad4155ddf1a"
let marmotKitReleaseTag = "marmotkit-snapshot-4e056e708afeb86fb4e62049b73c8ad4155ddf1a"
let marmotKitChecksum = "2586d7b5d55b1fe8cbe7c3b39f00bf8d9cfa86180b12a9b497d86aa31c26df68"
let marmotKitBinaryURL = "https://github.com/marmot-protocol/mdk/releases/download/\(marmotKitReleaseTag)/MarmotKitFFI-\(marmotKitReleaseID).xcframework.zip"

let package = Package(
    name: "MarmotKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "MarmotKit", targets: ["MarmotKit"])
    ],
    targets: [
        .binaryTarget(
            name: "MarmotKitFFI",
            url: marmotKitBinaryURL,
            checksum: marmotKitChecksum
        ),
        .target(
            name: "MarmotKit",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/MarmotKit",
            // UniFFI's generated Swift relies on file-scope `let`/`var`
            // globals that don't satisfy Swift 6's strict concurrency
            // checking. The handle maps are protected internally by Rust-
            // side locks, so compiling this target as Swift 5 is safe and
            // doesn't infect the rest of the app.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
