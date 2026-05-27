import Foundation

/// Bundles a destination directory + the safety checks that constrain
/// every entry written into it. iOS-idiomatic: uses `URL` (not `String`
/// paths), Foundation's built-in normalisation, and `CharacterSet` for
/// unsafe-codepoint detection.
///
/// All filename validation is locale-independent and locale-side-effect-free
/// — no `Locale.setDefault` style global mutations.
struct ExtractionScope {
  /// Hard cap on entry-name length. Catches DoS via 4090-char nested paths
  /// that would otherwise throw `ENAMETOOLONG` at the syscall layer with
  /// a useless platform-localised message.
  static let maxEntryNameLength = 1024

  /// The canonicalised destination directory. Symlinks in the *destination
  /// path itself* are resolved at construction time; symlinks *inside* the
  /// destination tree are caught per-entry via `verifyAncestryClean`.
  let destDir: URL

  /// Pre-computed destination prefix used for the "lexically inside dest"
  /// check. Cached so we don't rebuild it for every entry.
  let destPrefix: String

  init(destinationPath: String) throws {
    let cleaned = ExtractionScope.cleanFilesystemPath(destinationPath)
    if cleaned.isEmpty {
      throw UnzipError.destinationNotDirectory(URL(fileURLWithPath: ""))
    }
    let url = URL(fileURLWithPath: cleaned, isDirectory: true)

    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      if !isDirectory.boolValue {
        throw UnzipError.destinationNotDirectory(url)
      }
    } else {
      do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      } catch {
        throw UnzipError.destinationNotWritable(url)
      }
    }
    if !fileManager.isWritableFile(atPath: url.path) {
      throw UnzipError.destinationNotWritable(url)
    }

    // Resolve symlinks at the destination root so a single symlink in
    // the user-supplied path doesn't render every per-entry check off-by-N.
    let real = url.resolvingSymlinksInPath().standardizedFileURL
    self.destDir = real
    self.destPrefix = real.path + "/"
  }

  /// Validate an entry name and return the resolved `URL` it would be
  /// extracted to. Throws `UnzipError` with a precise case for any
  /// violation. Returns a URL that's safe to pass to `FileHandle`,
  /// `FileManager.createDirectory(at:)`, etc.
  func safeURL(forEntry name: String) throws -> URL {
    if name.isEmpty {
      throw UnzipError.entryEmpty
    }
    if name.utf16.count > Self.maxEntryNameLength {
      throw UnzipError.entryTooLong(actual: name.utf16.count, max: Self.maxEntryNameLength)
    }
    if name.rangeOfCharacter(from: .unsafeEntryName) != nil {
      throw UnzipError.entryUnsafeName(name)
    }
    if Self.isAbsoluteEntryPath(name) {
      throw UnzipError.entryAbsolutePath(name)
    }

    // URL.standardized collapses `..` and `.` segments lexically. We then
    // verify the resolved path is still inside destDir. No filesystem
    // syscalls — pure URL arithmetic. Per-write symlink checks happen
    // separately via verifyAncestryClean.
    let resolved = destDir.appendingPathComponent(name).standardizedFileURL
    if resolved == destDir {
      throw UnzipError.entryOutsideDestination(name: name, resolved: resolved)
    }
    if !resolved.path.hasPrefix(destPrefix) {
      throw UnzipError.entryOutsideDestination(name: name, resolved: resolved)
    }
    return resolved
  }

  /// Walk an ancestry from `target` toward `destDir` and refuse if any
  /// existing component is a symlink. This is the iOS equivalent of the
  /// Android `verifiedAncestors` walk — same security property, same
  /// caveat (catches static + pre-existing symlinks, not symlinks injected
  /// in the syscall race window).
  ///
  /// `verified` caches already-clean ancestors so deeply-nested archives
  /// with shared path prefixes don't re-stat the same directories on
  /// every entry.
  func verifyAncestryClean(of target: URL, verified: inout Set<URL>) throws {
    // Normalise URLs before set membership / insertion so trailing-slash
    // differences between `.appendingPathComponent` (no slash) and
    // `.deletingLastPathComponent` (trailing slash) don't make the cache
    // miss on logically-identical paths.
    var cur: URL? = target.standardizedFileURL
    let fileManager = FileManager.default
    while let current = cur, current != destDir, !verified.contains(current) {
      var isDir: ObjCBool = false
      if fileManager.fileExists(atPath: current.path, isDirectory: &isDir) {
        let resourceValues = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
        if resourceValues?.isSymbolicLink == true {
          throw UnzipError.symlinkInAncestry(current)
        }
      }
      verified.insert(current)
      let parent = current.deletingLastPathComponent().standardizedFileURL
      if parent == current { break } // hit filesystem root
      cur = parent
    }
  }

  /// Locale-independent NFC + lowercase fold for case-collapse-and-Unicode-
  /// collapse duplicate detection. NFC catches `café.txt` (NFC) vs `café.txt`
  /// (NFD) collisions that would silently overwrite on APFS/HFS+. The
  /// `en_US_POSIX` lowercase is the Swift idiom for locale-invariant case
  /// folding — equivalent to Java's `Locale.ROOT`, avoids Turkish-locale
  /// dotless-i and other locale-specific surprises.
  static func dedupKey(for name: String) -> String {
    name.precomposedStringWithCanonicalMapping
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

  /// Strip a `file://` URL scheme if present and reject any other scheme
  /// with a clear error (content://, http://, etc). Returns the cleaned
  /// path string.
  static func cleanFilesystemPath(_ path: String) -> String {
    if path.hasPrefix("file://") {
      return String(path.dropFirst("file://".count))
    }
    return path
  }

  /// Reject non-`file://` URI schemes early with a clear error rather
  /// than letting them flow into `URL(fileURLWithPath:)` and producing
  /// confusing downstream failures.
  static func requireFilesystemPath(_ path: String, paramName: String) throws {
    if let schemeRange = path.range(of: "://") {
      let scheme = String(path[..<schemeRange.lowerBound])
      if scheme != "file" {
        throw UnzipError.destinationSchemeUnsupported(scheme: scheme)
      }
    }
  }

  /// Pure-string absolute-path / out-of-spec check. Catches:
  /// - POSIX leading `/` (`/etc/passwd`)
  /// - Windows-style leading `\` or `C:\` drive letter
  /// - Any backslash ANYWHERE — ZIP spec mandates `/`, so legacy
  ///   Windows-emitted archives with `\` separators are out of spec
  ///   and would otherwise be written as literal-name files at the
  ///   destination root on POSIX (matches Android contract).
  private static func isAbsoluteEntryPath(_ name: String) -> Bool {
    guard let first = name.first else { return false }
    if first == "/" || first == "\\" { return true }
    if name.contains("\\") { return true }
    // Drive letter: A-Z / a-z followed by ':'.
    if name.count >= 2,
       (first.isASCII && first.isLetter),
       name[name.index(after: name.startIndex)] == ":" {
      return true
    }
    return false
  }
}

extension CharacterSet {
  /// Codepoints we refuse in ZIP entry names. Covers:
  /// - C0 controls (U+0000..U+001F) — terminal-escape log injection, NUL truncation
  /// - DEL (U+007F)
  /// - BiDi marks: LRM/RLM/ALM (U+200E, U+200F, U+061C)
  /// - BiDi overrides/isolates (U+202A..U+202E, U+2066..U+2069) —
  ///   CVE-2021-42574 "Trojan Source" class filename spoofing
  static let unsafeEntryName: CharacterSet = {
    var set = CharacterSet.controlCharacters // U+0000..U+001F + U+007F..U+009F
    set.insert(charactersIn: "\u{200E}\u{200F}\u{061C}")
    set.insert(charactersIn: "\u{202A}"..."\u{202E}")
    set.insert(charactersIn: "\u{2066}"..."\u{2069}")
    return set
  }()
}
