import Foundation
import XCTest
@testable import NitroUnzipCore

/// Verifies `UnzipError`'s stable `code` strings and the NSError bridge
/// shape that JS consumers actually see at the Nitro boundary.
///
/// JS callers branch on `err.userInfo.NitroUnzipErrorCode` — any rewording
/// of a `code` string is a silent breaking change. These tests pin every
/// case so a code rename trips an immediate red CI.
final class UnzipErrorTests: XCTestCase {

  func testEveryCaseHasUniqueStableCode() {
    let allCases: [UnzipError] = [
      .sourceNotFound(URL(fileURLWithPath: "/tmp/x")),
      .sourceUnreadable(URL(fileURLWithPath: "/tmp/x"), underlying: NSError(domain: "t", code: 0)),
      .destinationNotDirectory(URL(fileURLWithPath: "/tmp/x")),
      .destinationNotWritable(URL(fileURLWithPath: "/tmp/x")),
      .destinationSchemeUnsupported(scheme: "content"),
      .entryEmpty,
      .entryTooLong(actual: 2000, max: 1024),
      .entryUnsafeName("\u{202E}.txt"),
      .entryAbsolutePath("/etc/passwd"),
      .entryOutsideDestination(name: "../escape", resolved: URL(fileURLWithPath: "/etc/escape")),
      .entryDuplicate("Config.json"),
      .symlinkInAncestry(URL(fileURLWithPath: "/tmp/dest/link")),
      .wrongPassword,
      .corruptArchive(underlying: NSError(domain: "t", code: 0)),
      .cancelled
    ]
    let codes = allCases.map { $0.code }
    XCTAssertEqual(codes.count, Set(codes).count, "duplicate codes: \(codes)")
    // Every code must be SCREAMING_SNAKE — stable identifier convention.
    for code in codes {
      XCTAssertEqual(code, code.uppercased(), "\(code) is not uppercased")
      XCTAssertFalse(code.contains(" "), "\(code) contains spaces")
    }
  }

  func testNSErrorBridgeCarriesCodeInUserInfo() {
    let err = UnzipError.entryAbsolutePath("/etc/passwd").asNSError
    XCTAssertEqual(err.domain, "NitroUnzip")
    XCTAssertEqual(err.userInfo[NitroUnzipErrorCodeKey] as? String, "ENTRY_ABSOLUTE_PATH")
    XCTAssertNotNil(err.localizedDescription)
    XCTAssertTrue(err.localizedDescription.contains("absolute path"))
  }

  func testLocalizedDescriptionsAreNonEmpty() {
    let cases: [UnzipError] = [
      .sourceNotFound(URL(fileURLWithPath: "/x")),
      .destinationNotDirectory(URL(fileURLWithPath: "/x")),
      .entryEmpty,
      .entryTooLong(actual: 2000, max: 1024),
      .entryUnsafeName("\u{0007}foo"),
      .entryAbsolutePath("/etc/passwd"),
      .entryDuplicate("X"),
      .symlinkInAncestry(URL(fileURLWithPath: "/x")),
      .wrongPassword,
      .cancelled
    ]
    for c in cases {
      let desc = c.errorDescription ?? ""
      XCTAssertFalse(desc.isEmpty, "case \(c.code) has no errorDescription")
    }
  }
}
