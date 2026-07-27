// swift-tools-version: 6.2
import PackageDescription

// Alternate SPM build entry for the iOS app. The production build path is the
// Xcode project generated from `apps/ios/project.yml` (see the Makefile iOS
// lanes), which links `libcodex_mobile_client.a` directly from
// `apps/ios/GeneratedRust/`. This manifest is kept so the Swift sources can
// also be compiled via SPM when a packaged `codex_mobile_client.xcframework`
// is present under `apps/ios/Frameworks/`.
let package = Package(
    name: "Litter",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "Litter", targets: ["Litter"])
    ],
    targets: [
        .binaryTarget(
            name: "codex_mobile_client",
            path: "apps/ios/Frameworks/codex_mobile_client.xcframework"
        ),
        .target(
            name: "Litter",
            dependencies: ["codex_mobile_client"],
            path: "apps/ios/Sources/Litter",
            publicHeadersPath: "Bridge"
        )
    ]
)
