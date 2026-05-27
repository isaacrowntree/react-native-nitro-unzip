// swift-tools-version:5.9
//
// SPM manifest for the iOS test suite. The library product
// `NitroUnzipCore` re-exports the pure-Swift security surface
// (UnzipError + ExtractionScope) so it can be exercised via
// `swift test` without the Nitro Modules / CocoaPods toolchain.
//
// The full HybridUnzipTask + HybridZipTask integration is consumed
// only via the CocoaPods podspec — this manifest is test-only.

import PackageDescription

let package = Package(
  name: "react-native-nitro-unzip",
  platforms: [
    .iOS(.v15),
    .macOS(.v12)  // for `swift test` runs on dev machines
  ],
  products: [
    .library(name: "NitroUnzipCore", targets: ["NitroUnzipCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
  ],
  targets: [
    .target(
      name: "NitroUnzipCore",
      path: "ios",
      // Exclude the Nitro-coupled files; SPM compiles only the pure-Swift core.
      exclude: [
        "HybridUnzip.swift",
        "HybridUnzipTask.swift",
        "HybridZipTask.swift"
      ],
      sources: ["UnzipError.swift", "ExtractionScope.swift"]
    ),
    .testTarget(
      name: "NitroUnzipCoreTests",
      dependencies: [
        "NitroUnzipCore",
        .product(name: "ZIPFoundation", package: "ZIPFoundation")
      ],
      path: "ios/Tests"
    )
  ]
)
