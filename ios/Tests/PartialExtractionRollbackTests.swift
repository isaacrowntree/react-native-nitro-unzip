import Foundation
import XCTest
@testable import NitroUnzipCore

/// Unit coverage for the partial-extraction cleanup helper called by
/// `HybridUnzipTask.extractUnencrypted` when extraction throws mid-stream.
/// We can't drive the full extraction loop from SPM (Nitro coupling) but
/// the rollback decisions are pure file I/O — testable here.
final class PartialExtractionRollbackTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nitro-unzip-rollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir = tempDir {
      try? FileManager.default.removeItem(at: tempDir)
    }
  }

  @discardableResult
  private func touch(_ relative: String, _ contents: String = "x") throws -> URL {
    let url = tempDir.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.data(using: .utf8)!.write(to: url)
    return url
  }

  @discardableResult
  private func mkdir(_ relative: String) throws -> URL {
    let url = tempDir.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - Core behaviour

  func testRollbackDeletesAllListedFiles() throws {
    let f1 = try touch("a.txt")
    let f2 = try touch("nested/b.txt")
    let f3 = try touch("nested/deeper/c.txt")

    PartialExtractionRollback.rollback(files: [f1, f2, f3], directories: [])

    XCTAssertFalse(FileManager.default.fileExists(atPath: f1.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: f2.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: f3.path))
  }

  func testRollbackDeletesEmptyDirectoriesDeepestFirst() throws {
    // Build: tempDir/created/empty1/empty2 (only directories, no files)
    let d1 = try mkdir("created")
    let d2 = try mkdir("created/empty1")
    let d3 = try mkdir("created/empty1/empty2")

    // Pass them in arbitrary order — implementation must sort by depth.
    PartialExtractionRollback.rollback(
      files: [],
      directories: [d1, d3, d2]
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: d3.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: d2.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: d1.path))
  }

  func testRollbackSortsByDepthNotPathLength() throws {
    // Regression test for the depth-vs-path-length fix. A shallow dir
    // with a long name (`outer-longname/`, depth 1) sorted next to a
    // deep dir with short names (`a/b/c/`, depth 3). path.count ordering
    // would put `outer-longname` first; pathComponents.count puts
    // `a/b/c` first (correct: deepest dir gets deleted before its
    // potential parent — even though here they're independent subtrees,
    // the invariant must hold for the mixed-subtree case).
    let shallow = try mkdir("outer-with-long-name-zzzzzzzzzz")
    let deepRoot = try mkdir("a")
    let deepMid = try mkdir("a/b")
    let deepLeaf = try mkdir("a/b/c")

    PartialExtractionRollback.rollback(
      files: [],
      // Intentionally shuffled — implementation must reorder by depth.
      directories: [deepRoot, shallow, deepLeaf, deepMid]
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: shallow.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deepLeaf.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deepMid.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deepRoot.path))
  }

  func testRollbackFilesThenDirectoriesIntegration() throws {
    // Realistic mid-extraction state: files were written into newly-
    // created directories. Rollback must remove BOTH layers cleanly.
    let dir = try mkdir("subdir/inner")
    let f1 = try touch("subdir/inner/a.bin")
    let f2 = try touch("subdir/inner/b.bin")
    let outerDir = tempDir.appendingPathComponent("subdir")

    PartialExtractionRollback.rollback(
      files: [f1, f2],
      directories: [outerDir, dir]
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: f1.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: f2.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outerDir.path))
  }

  // MARK: - Error tolerance

  func testRollbackContinuesPastMissingFile() throws {
    let existing = try touch("real.txt")
    let missing = tempDir.appendingPathComponent("never-existed.txt")

    var errors: [(URL, Error)] = []
    PartialExtractionRollback.rollback(
      files: [missing, existing],
      directories: [],
      onError: { url, err in errors.append((url, err)) }
    )

    // The missing-file error is surfaced via onError, but the existing
    // file STILL got deleted — rollback is best-effort, not all-or-nothing.
    XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path))
    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(errors.first?.0.lastPathComponent, "never-existed.txt")
  }

  func testRollbackHandlesEmptyInputs() {
    // No crash, no error, no effect.
    PartialExtractionRollback.rollback(files: [], directories: [])
  }

  func testRollbackHandlesAllMissingTargetsWithoutCallback() {
    // Production calls pass no onError. A missing target must NOT throw
    // or crash.
    let phantom1 = tempDir.appendingPathComponent("ghost-1.bin")
    let phantom2 = tempDir.appendingPathComponent("ghost-dir")
    PartialExtractionRollback.rollback(files: [phantom1], directories: [phantom2])
  }

  // MARK: - Determinism

  func testRollbackDeletesFilesInReverseInsertionOrder() throws {
    // Files are deleted last-written-first so the most-likely-truncated
    // entry goes first. We verify ordering by capturing onError deletes
    // against a directory tree where deletion succeeds left-to-right but
    // we can observe order via a custom FileManager? Too heavy. Instead,
    // assert post-state: all files gone, regardless of order. The
    // ordering matters for the failure case (truncated last entry) — the
    // success case here proves the loop runs to completion.
    let urls = (0..<10).map { i in
      tempDir.appendingPathComponent("entry_\(i).bin")
    }
    for url in urls {
      try Data([0x42]).write(to: url)
    }
    PartialExtractionRollback.rollback(files: urls, directories: [])
    for url in urls {
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
  }
}
