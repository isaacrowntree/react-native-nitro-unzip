// swift-tools-version:6.0
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
  dependencies: [],
  targets: [
    .target(
      name: "NitroUnzipCore",
      path: "ios",
      // Compile only the pure-Swift security surface for SPM testing.
      // The Hybrid classes that integrate Nitro + ZIPFoundation +
      // SSZipArchive are built via CocoaPods only — their orchestration
      // is intentionally tested via the consuming app, not via SPM.
      exclude: [
        "HybridUnzip.swift",
        "HybridUnzipTask.swift",
        "HybridZipTask.swift",
        // Owned by the NitroUnzipCoreTests target below; listing them here
        // silences SPM's "unhandled files" warning for the shared `ios` path.
        "Tests"
      ],
      sources: [
        "UnzipError.swift",
        "ExtractionScope.swift",
        "PartialExtractionRollback.swift",
        "Locking.swift"
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "NitroUnzipCoreTests",
      dependencies: ["NitroUnzipCore"],
      path: "ios/Tests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    )
  ]
)
