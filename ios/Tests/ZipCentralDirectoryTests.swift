import XCTest

@testable import NitroUnzipCore

/// Enumeration must work for EVERY archive we accept, including
/// password-protected ones.
///
/// This exists because ZIPFoundation silently yields zero entries for WinZip
/// AES archives (compression method 99). The password-protected extract path
/// enumerated with it and then looped over the result to run the Zip Slip and
/// duplicate-name checks — so on an AES archive that loop had nothing to
/// iterate and every path-safety check was skipped, while `totalFiles` was
/// reported as 0.
final class ZipCentralDirectoryTests: XCTestCase {
  private func fixture(_ name: String) throws -> URL {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "zip")
    return try XCTUnwrap(url, "missing fixture \(name).zip")
  }

  /// The regression test. ZIPFoundation returns [] here.
  func testEnumeratesAESEncryptedEntries() throws {
    let names = try ZipCentralDirectory.entryNames(at: fixture("aes-protected"))
    XCTAssertEqual(
      Set(names),
      ["secret.txt", "secret-1.txt", "secret-2.txt", "nested/deep.txt"],
      "AES (method 99) entries must enumerate; an empty result silently skips path validation"
    )
  }

  /// Directory entries are returned as-is; filtering them is the caller's job,
  /// because the path-safety checks must see them too.
  func testEnumeratesPlainArchiveIncludingDirectoryEntries() throws {
    let names = try ZipCentralDirectory.entryNames(at: fixture("plain"))
    XCTAssertEqual(names.count, 6, "expected 4 files + 2 directory entries")
    XCTAssertEqual(names.filter { $0.hasSuffix("/") }.count, 2)
    XCTAssertTrue(names.contains("test-data/subdir/nested.txt"))
  }

  /// Every entry must be seen, so a caller counting files gets the same answer
  /// the extractor will produce.
  func testFileOnlyCountMatchesArchiveContents() throws {
    let aes = try ZipCentralDirectory.entryNames(at: fixture("aes-protected"))
    XCTAssertEqual(aes.filter { !$0.hasSuffix("/") }.count, 4)

    let plain = try ZipCentralDirectory.entryNames(at: fixture("plain"))
    XCTAssertEqual(plain.filter { !$0.hasSuffix("/") }.count, 4)
  }

  func testRejectsNonZipData() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("not-a-zip-\(UUID().uuidString).bin")
    try Data(repeating: 0x41, count: 4096).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    XCTAssertThrowsError(try ZipCentralDirectory.entryNames(at: tmp))
  }
}
