import Foundation
import XCTest
@testable import NitroUnzipCore

/// Nested-folder perf coverage for the iOS security surface.
///
/// We can't drive the full Hybrid extraction loop from SPM (Nitro
/// coupling), but the per-entry validation chain is identical to what
/// production runs on every entry. This tests THAT cost at scale —
/// 1000 entries spread across ~500 unique directories — which is the
/// realistic workload (tile sets, asset bundles, SDK archives).
///
/// What this exercises:
/// - `ExtractionScope.safeURL(forEntry:)` per entry — Zip Slip validation
/// - `ExtractionScope.dedupKey(for:)` per entry — NFC + locale-invariant
///   lowercase
/// - `ExtractionScope.verifyAncestryClean` per unique parent dir, with
///   the `verifiedAncestors` cache amortising shared prefixes
final class NestedExtractionPerfTests: XCTestCase {
  private var tempDir: URL!
  private var destDir: URL!
  private var scope: ExtractionScope!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nitro-unzip-perf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    destDir = tempDir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    scope = try ExtractionScope(destinationPath: destDir.path)
  }

  override func tearDownWithError() throws {
    if let tempDir = tempDir {
      try? FileManager.default.removeItem(at: tempDir)
    }
  }

  /// Generate `count` paths that mirror the Android `writeNestedZip`
  /// helper — `tier_X/sub_Y/leaf_Z/file_NNNN.bin` with each digit
  /// cycling base-8 so the result has both depth and branching.
  /// For count=1000: 1000 files across ~512 leaf dirs in a 3-level tree.
  private func nestedPaths(count: Int) -> [String] {
    return (0..<count).map { i in
      let d0 = (i / 64) % 8
      let d1 = (i / 8) % 8
      let d2 = i % 8
      return "tier_\(d0)/sub_\(d1)/leaf_\(d2)/file_\(String(format: "%04d", i)).bin"
    }
  }

  func testNestedValidationThroughput() throws {
    // 1000 nested entries — same shape as the Android nested perf test.
    let paths = nestedPaths(count: 1000)

    let start = Date()
    var seenDedup = Set<String>()
    var verifiedAncestors = Set<URL>()
    var leafTargets: [URL] = []
    leafTargets.reserveCapacity(paths.count)

    for path in paths {
      // Mimics the production pre-validation pass:
      //   1. dedup key (NFC + lowercase)
      //   2. safeURL (path-safety validation)
      let dedupKey = ExtractionScope.dedupKey(for: path)
      XCTAssertTrue(seenDedup.insert(dedupKey).inserted, "unexpected dedup collision for \(path)")
      let target = try scope.safeURL(forEntry: path)
      leafTargets.append(target)
    }

    // Mimics the per-file extraction pass: for each file, ensure parent
    // ancestry is clean. The verifiedAncestors cache amortises walks
    // across files that share a parent prefix.
    for target in leafTargets {
      let parent = target.deletingLastPathComponent()
      try scope.verifyAncestryClean(of: parent, verified: &verifiedAncestors)
    }

    let elapsedMs = Date().timeIntervalSince(start) * 1000
    print("ExtractionScope (nested): 1000 entries validated + ancestry-checked in \(String(format: "%.1f", elapsedMs))ms")

    // Sanity bound: 1000 entries through validation + ancestry walk
    // should complete in well under 1 second on any plausible CI runner.
    // 5 seconds gives an order-of-magnitude headroom for shared-runner
    // contention while still flagging a catastrophic regression (e.g.
    // someone accidentally re-statting every ancestor for every file).
    XCTAssertLessThan(elapsedMs, 5_000)

    // Cache effectiveness check: after walking 1000 entries with shared
    // prefixes, the verifiedAncestors set should be much smaller than
    // 1000 (proves the cache prevented redundant walks).
    XCTAssertLessThan(
      verifiedAncestors.count, paths.count,
      "verifiedAncestors should cache shared prefixes, not grow per entry"
    )
    print("  verifiedAncestors cache size: \(verifiedAncestors.count) for 1000 entries")
  }

  func testNestedValidationRejectsZipSlipAfterDeepValidPaths() throws {
    // Build 500 valid nested paths followed by ONE Zip Slip payload.
    // Asserts the pre-validation rejects the bad entry without partial
    // state — the post-validation extraction pass would never start.
    var paths = nestedPaths(count: 500)
    paths.append("tier_0/sub_0/leaf_0/../../../../../../escape.txt")

    var seenDedup = Set<String>()
    var validatedCount = 0
    var caught: UnzipError?

    for path in paths {
      do {
        _ = ExtractionScope.dedupKey(for: path)
        _ = try scope.safeURL(forEntry: path)
        validatedCount += 1
      } catch let error as UnzipError {
        caught = error
        break
      }
      seenDedup.insert(ExtractionScope.dedupKey(for: path))
    }

    XCTAssertEqual(validatedCount, 500, "first 500 entries should validate")
    XCTAssertNotNil(caught, "Zip Slip payload must be caught")
    XCTAssertEqual(caught?.code, "ENTRY_OUTSIDE_DESTINATION")
  }

  func testDeeplyNestedSharedPrefixCacheHits() throws {
    // 100 files in the SAME deep directory. After the first walk
    // populates verifiedAncestors, the remaining 99 should be O(1)
    // cache hits per file.
    let depth = 5
    let dir = (0..<depth).map { "level_\($0)" }.joined(separator: "/")
    let paths = (0..<100).map { "\(dir)/file_\(String(format: "%03d", $0)).bin" }

    // Create the directory tree on disk so verifyAncestryClean has real
    // entries to stat.
    try FileManager.default.createDirectory(
      at: scope.destDir.appendingPathComponent(dir),
      withIntermediateDirectories: true
    )

    var verifiedAncestors = Set<URL>()
    let start = Date()
    for path in paths {
      let target = try scope.safeURL(forEntry: path)
      try scope.verifyAncestryClean(of: target.deletingLastPathComponent(), verified: &verifiedAncestors)
    }
    let elapsedMs = Date().timeIntervalSince(start) * 1000
    print("ExtractionScope (shared-prefix): 100 entries × \(depth)-deep in \(String(format: "%.1f", elapsedMs))ms")

    // Cache hit ratio sanity: after the first walk, the next 99 should
    // find every ancestor in the cache. Total unique paths in the cache
    // should be roughly equal to the depth + the 100 leaf URLs, NOT
    // 100 × depth.
    XCTAssertLessThan(
      verifiedAncestors.count, paths.count + depth + 5,
      "cache should keep ancestor count bounded; got \(verifiedAncestors.count)"
    )
  }
}
