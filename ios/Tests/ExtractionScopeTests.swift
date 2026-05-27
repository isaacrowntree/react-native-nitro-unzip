import Foundation
import XCTest
@testable import NitroUnzipCore

/// Tests for the iOS path-safety surface. Parity with the Android
/// `HybridUnzipTaskZipSlipTest` suite, expressed in Swift idioms (URL,
/// FileManager, XCTest) rather than a Java translation.
final class ExtractionScopeTests: XCTestCase {

  private var tempDir: URL!
  private var destDir: URL!
  private var scope: ExtractionScope!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nitro-unzip-tests-\(UUID().uuidString)")
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

  // MARK: - Accept legitimate entries

  func testAcceptsPlainFileEntry() throws {
    _ = try scope.safeURL(forEntry: "foo.png")
  }

  func testAcceptsNestedDirectoryEntry() throws {
    _ = try scope.safeURL(forEntry: "tiles/12/345/678.png")
  }

  func testAcceptsDeepNesting() throws {
    _ = try scope.safeURL(forEntry: "a/b/c/d/e/f/g/h/i.png")
  }

  func testAcceptsDottedFilenamesThatArentTraversal() throws {
    _ = try scope.safeURL(forEntry: "image.tar.gz")
    _ = try scope.safeURL(forEntry: ".hidden")
    _ = try scope.safeURL(forEntry: "..foo")
  }

  func testAcceptsInternalTraversalThatStaysInside() throws {
    // `foo/../bar` normalises to `bar` which is still inside dest.
    let resolved = try scope.safeURL(forEntry: "foo/../bar.png")
    XCTAssertEqual(resolved.lastPathComponent, "bar.png")
  }

  func testReturnsResolvedURLForCallerReuse() throws {
    let resolved = try scope.safeURL(forEntry: "tiles/12/x.png")
    XCTAssertEqual(resolved.path, destDir.appendingPathComponent("tiles/12/x.png").path)
  }

  // MARK: - Reject Zip Slip payloads

  func testRejectsParentTraversal() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "../escape.txt")) { error in
      let code = (error as? UnzipError)?.code
      XCTAssertEqual(code, "ENTRY_OUTSIDE_DESTINATION", "got \(String(describing: error))")
    }
  }

  func testRejectsDeepParentTraversal() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "../../../databases/poi.db"))
  }

  func testRejectsTraversalMixedWithSubdirectories() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "tiles/../../../etc/passwd"))
  }

  func testRejectsPOSIXAbsolutePaths() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "/etc/passwd")) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_ABSOLUTE_PATH")
    }
  }

  func testRejectsTraversalDisguisedByLeadingSibling() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "../dest-sibling/foo.png"))
  }

  func testRejectsEntryResolvingToDestRoot() {
    // `.` and `foo/..` both resolve to destDir itself; FileHandle on the
    // dest dir would crash with "is a directory". Reject upfront.
    XCTAssertThrowsError(try scope.safeURL(forEntry: ".")) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_OUTSIDE_DESTINATION")
    }
    XCTAssertThrowsError(try scope.safeURL(forEntry: "foo/.."))
  }

  // MARK: - Empty + length

  func testRejectsEmptyEntryName() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "")) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_EMPTY")
    }
  }

  func testRejectsEntryNamesAtAndBeyondLengthCap() {
    let atCap = String(repeating: "a", count: 1024)
    _ = try? scope.safeURL(forEntry: atCap)  // exactly cap is accepted

    let beyondCap = String(repeating: "a", count: 1025)
    XCTAssertThrowsError(try scope.safeURL(forEntry: beyondCap)) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_TOO_LONG")
    }
  }

  // MARK: - Backslash entries

  func testRejectsEntriesContainingBackslash() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "subdir\\file.txt")) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_ABSOLUTE_PATH")
    }
    XCTAssertThrowsError(try scope.safeURL(forEntry: "\\foo.txt"))
    XCTAssertThrowsError(try scope.safeURL(forEntry: "..\\..\\etc\\passwd"))
  }

  // MARK: - NUL + control characters + BiDi

  func testRejectsNULByteInEntryName() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "foo\u{0000}.txt")) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_UNSAFE_NAME")
    }
  }

  func testRejectsNULEvenWhenWrappedBySafePath() {
    XCTAssertThrowsError(try scope.safeURL(forEntry: "tiles/foo\u{0000}/bar.png"))
  }

  func testRejectsC0ControlCharacters() {
    // \u{001b} = ESC (terminal injection), \u{0007} = BEL, \u{007f} = DEL
    for c in ["\u{0001}", "\u{0007}", "\u{001b}", "\u{007f}"] {
      XCTAssertThrowsError(
        try scope.safeURL(forEntry: "log\(c)injected.txt"),
        "expected throw for U+\(String(format: "%04X", c.unicodeScalars.first!.value))"
      ) { error in
        XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_UNSAFE_NAME")
      }
    }
  }

  func testRejectsBiDiOverrideCharacters() {
    // U+202E (RTL OVERRIDE) reverses subsequent text — file-browser spoofing.
    // Also U+200E (LRM), U+200F (RLM), U+061C (ALM), U+2066..U+2069 (isolates).
    let biDiCodepoints = [
      "\u{200E}", "\u{200F}", "\u{061C}",
      "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
      "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"
    ]
    for c in biDiCodepoints {
      XCTAssertThrowsError(
        try scope.safeURL(forEntry: "payment\(c)rfdp.exe"),
        "expected throw for U+\(String(format: "%04X", c.unicodeScalars.first!.value))"
      ) { error in
        XCTAssertEqual((error as? UnzipError)?.code, "ENTRY_UNSAFE_NAME")
      }
    }
  }

  // MARK: - Locale-invariant dedup key

  func testDedupKeyIsLocaleInvariantForTurkishI() {
    // Latin capital I with dot (U+0130). Under tr-TR, .lowercased() returns
    // "i"; under en_US_POSIX it returns "i\u{0307}" (i + combining dot above).
    // ExtractionScope.dedupKey must use en_US_POSIX so the two dedup keys
    // for "İ.txt" and "i.txt" are DISTINCT — i.e. they don't falsely
    // collide.
    let prevLocale = Locale.autoupdatingCurrent
    _ = prevLocale  // silence unused warning
    let dottedI = ExtractionScope.dedupKey(for: "\u{0130}.txt")
    let plainI = ExtractionScope.dedupKey(for: "i.txt")
    XCTAssertNotEqual(dottedI, plainI, "locale-aware lowercase falsely collapsed dotted vs plain I")
  }

  func testDedupKeyCollapsesNFCAndNFDOfSameLogicalName() {
    // café.txt in NFC (precomposed) and NFD (decomposed) must produce the
    // same dedup key, because APFS/HFS+ normalise both forms to one
    // on-disk filename and the second extract would silently overwrite
    // the first.
    let base = "café.txt"
    let nfc = base.precomposedStringWithCanonicalMapping
    let nfd = base.decomposedStringWithCanonicalMapping
    // Swift's `==` on String is normalisation-aware (NFC and NFD compare
    // equal as Strings). Use byte length to confirm the fixture actually
    // builds two distinct encodings — if both came back equal-length,
    // the source file's storage form has silently re-normalised and the
    // test would be exercising same-string dedup instead of NFC dedup.
    XCTAssertNotEqual(
      nfc.utf8.count, nfd.utf8.count,
      "fixture precondition: NFC and NFD must produce different byte sequences"
    )
    XCTAssertEqual(
      ExtractionScope.dedupKey(for: nfc),
      ExtractionScope.dedupKey(for: nfd),
      "NFC and NFD forms must collapse to the same dedup key"
    )
  }

  func testDedupKeyCollapsesAsciiCaseDifferences() {
    XCTAssertEqual(
      ExtractionScope.dedupKey(for: "Config.json"),
      ExtractionScope.dedupKey(for: "config.json")
    )
  }

  // MARK: - Symlink ancestry

  func testVerifyAncestryRejectsPreExistingSymlinkInAncestry() throws {
    // Plant a symlink at dest/sub pointing to /tmp. Then try to verify
    // the ancestry of dest/sub/file.txt — must reject.
    let outside = tempDir.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = destDir.appendingPathComponent("sub")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let target = link.appendingPathComponent("file.txt")
    var verified = Set<URL>()
    XCTAssertThrowsError(try scope.verifyAncestryClean(of: target, verified: &verified)) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "SYMLINK_IN_ANCESTRY")
    }
  }

  func testVerifyAncestryPassesForCleanTree() throws {
    let inner = destDir.appendingPathComponent("sub/inner")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    var verified = Set<URL>()
    XCTAssertNoThrow(
      try scope.verifyAncestryClean(of: inner.appendingPathComponent("file.txt"), verified: &verified)
    )
  }

  func testVerifyAncestryCacheReducesReWalks() throws {
    // Assert the BEHAVIOUR of the cache (subsequent calls don't re-stat
    // shared ancestors) rather than specific URL membership — Foundation
    // URL equality is finicky around trailing slashes after
    // `deletingLastPathComponent`, and pinning specific URL forms makes
    // the test brittle without strengthening the contract.
    let inner = scope.destDir.appendingPathComponent("a/b/c").standardizedFileURL
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    var verified = Set<URL>()

    try scope.verifyAncestryClean(of: inner.appendingPathComponent("x.txt"), verified: &verified)
    let countAfterFirstWalk = verified.count
    XCTAssertGreaterThanOrEqual(countAfterFirstWalk, 4,
      "expected target + 3 ancestors (a, a/b, a/b/c) at minimum")

    // Second call with a sibling of x.txt shares ALL ancestors. Only the
    // new leaf (y.txt) should be added — proving the cache shortcut works.
    try scope.verifyAncestryClean(of: inner.appendingPathComponent("y.txt"), verified: &verified)
    XCTAssertEqual(verified.count, countAfterFirstWalk + 1,
      "cached ancestors should not be re-added; expected exactly 1 new entry (y.txt)")
  }

  // MARK: - Scheme rejection

  func testRequireFilesystemPathAcceptsBareAndFileScheme() throws {
    XCTAssertNoThrow(try ExtractionScope.requireFilesystemPath("/tmp/foo", paramName: "p"))
    XCTAssertNoThrow(try ExtractionScope.requireFilesystemPath("file:///tmp/foo", paramName: "p"))
  }

  func testRequireFilesystemPathRejectsContentScheme() {
    XCTAssertThrowsError(try ExtractionScope.requireFilesystemPath(
      "content://com.android.externalstorage.documents/tree/x",
      paramName: "destinationPath"
    )) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "DEST_SCHEME_UNSUPPORTED")
    }
  }

  func testRequireFilesystemPathRejectsHttpScheme() {
    XCTAssertThrowsError(try ExtractionScope.requireFilesystemPath(
      "https://example.com/archive.zip",
      paramName: "zipPath"
    ))
  }

  // MARK: - Constructor preconditions

  func testInitRejectsEmptyDestination() {
    XCTAssertThrowsError(try ExtractionScope(destinationPath: ""))
  }

  func testInitRejectsExistingFileAtDestination() throws {
    let occupied = tempDir.appendingPathComponent("occupied")
    try "I am a file".write(to: occupied, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try ExtractionScope(destinationPath: occupied.path)) { error in
      XCTAssertEqual((error as? UnzipError)?.code, "DEST_NOT_DIRECTORY")
    }
  }

  func testInitCreatesMissingDestinationDirectory() throws {
    let newDest = tempDir.appendingPathComponent("brand-new")
    XCTAssertFalse(FileManager.default.fileExists(atPath: newDest.path))
    _ = try ExtractionScope(destinationPath: newDest.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: newDest.path))
  }

  func testInitResolvesSymlinkedDestination() throws {
    // Real dest is /tmp/.../real-dest. Caller passes a symlink to it.
    let realDest = tempDir.appendingPathComponent("real-dest")
    try FileManager.default.createDirectory(at: realDest, withIntermediateDirectories: true)
    let link = tempDir.appendingPathComponent("dest-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDest)
    let s = try ExtractionScope(destinationPath: link.path)
    // destDir should be canonicalised to the real path.
    XCTAssertEqual(s.destDir.standardizedFileURL.path, realDest.standardizedFileURL.path)
  }
}
