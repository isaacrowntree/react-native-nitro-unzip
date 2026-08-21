import XCTest

@testable import NitroUnzipCore

/// End-to-end guard for the password-protected extract path.
///
/// The two halves have to work together: enumeration must SEE every entry
/// (ZIPFoundation returned nothing for AES, which is what silently disabled
/// this), and ExtractionScope must then REJECT the hostile ones. Testing them
/// separately would have missed the original bug entirely — ExtractionScope
/// was always correct; it was simply never being called.
///
/// Fixture is a real WinZip AES-256 archive whose central directory contains
/// four traversal entries alongside one benign file.
///
/// Measured behaviour of SSZipArchive 2.6.0 on this exact fixture, called with
/// the same arguments the extract path uses (verified in isolation, outside
/// this package): it CONTAINS the archive but does so by *flattening* the
/// traversal components rather than refusing the entries --
///
///     ../escape-one.txt                        -> escape-one.txt
///     ../../escape-two.txt                     -> escape-two.txt
///     sub/../../escape-mixed.txt               -> escape-mixed.txt
///     ../../../../../../tmp/escape-abs-ish.txt -> tmp/escape-abs-ish.txt
///
/// Nothing landed outside the destination. That is why the pre-0.6.0 gap was a
/// defence-in-depth failure and not a traversal vulnerability -- it is measured,
/// not assumed.
///
/// It also shows why this layer still matters: flattening silently WRITES a
/// hostile entry under a rewritten name, whereas ExtractionScope rejects it, so
/// callers can tell a malicious archive from a benign one. SSZipArchive's
/// sanitisation also does not cover symlinked ancestors, duplicate names or
/// unicode-normalisation collisions, which ExtractionScope does.
final class AESZipSlipTests: XCTestCase {
  private var destination: URL!

  override func setUpWithError() throws {
    destination = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("aes-zipslip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: destination)
  }

  private func maliciousEntries() throws -> [String] {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "Fixtures/zipslip-aes", withExtension: "zip"))
    return try ZipCentralDirectory.entryNames(at: url)
  }

  /// Half one: the hostile names must be visible to the validation loop.
  func testTraversalEntriesAreEnumerated() throws {
    let names = try maliciousEntries()
    XCTAssertEqual(names.count, 5)
    XCTAssertTrue(names.contains("../escape-one.txt"))
    XCTAssertTrue(names.contains("../../escape-two.txt"))
    XCTAssertTrue(names.contains("sub/../../escape-mixed.txt"))
  }

  /// Half two: every one of them must be REFUSED, not silently rewritten.
  /// SSZipArchive would flatten these into the destination under mangled
  /// names; rejecting is what lets a caller distinguish attack from accident.
  func testEveryTraversalEntryIsRejected() throws {
    let scope = try ExtractionScope(destinationPath: destination.path)
    let hostile = try maliciousEntries().filter { $0 != "benign.txt" }
    XCTAssertEqual(hostile.count, 4, "fixture should carry 4 hostile entries")

    for name in hostile {
      XCTAssertThrowsError(
        try scope.safeURL(forEntry: name),
        "entry \(name) escaped the destination"
      )
    }
  }

  /// The benign entry must still resolve, inside the destination — a guard
  /// that rejects everything is not a guard, it is a broken extractor.
  func testBenignEntryStillResolvesInsideDestination() throws {
    let scope = try ExtractionScope(destinationPath: destination.path)
    let url = try scope.safeURL(forEntry: "benign.txt")
    XCTAssertTrue(
      url.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path))
  }

  /// Nothing may exist outside the destination after validation.
  func testNoFileEscapedDuringValidation() throws {
    let scope = try ExtractionScope(destinationPath: destination.path)
    for name in try maliciousEntries() {
      _ = try? scope.safeURL(forEntry: name)
    }
    let parent = destination.deletingLastPathComponent()
    let stray = (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?
      .filter { $0.hasPrefix("escape-") } ?? []
    XCTAssertTrue(stray.isEmpty, "files escaped: \(stray)")
  }
}
