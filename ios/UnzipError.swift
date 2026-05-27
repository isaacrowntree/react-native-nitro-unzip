import Foundation

/// Typed errors thrown by `HybridUnzipTask`. Each case maps to a stable
/// string `code` exposed via `error.userInfo[NitroUnzipErrorCodeKey]` so
/// JS callers can branch programmatically instead of substring-matching
/// localised messages.
///
/// Replaces the 0.3 era `NSError` + `domain:"NitroUnzip", code:Int`
/// pattern, which forced consumers to memorise integer codes with no
/// type-safe surface in Swift.
enum UnzipError: LocalizedError {
  case sourceNotFound(URL)
  case sourceUnreadable(URL, underlying: Error)
  case destinationNotDirectory(URL)
  case destinationNotWritable(URL)
  case destinationSchemeUnsupported(scheme: String)
  case entryEmpty
  case entryTooLong(actual: Int, max: Int)
  case entryUnsafeName(String)
  case entryAbsolutePath(String)
  case entryOutsideDestination(name: String, resolved: URL)
  case entryDuplicate(String)
  case symlinkInAncestry(URL)
  case wrongPassword
  case corruptArchive(underlying: Error)
  case cancelled

  /// Stable, locale-independent identifier. JS bridge surfaces this via the
  /// Nitro error's userInfo so consumers can `switch (err.code)` without
  /// risking a message rewording or localisation breaking their handler.
  var code: String {
    switch self {
    case .sourceNotFound: return "SOURCE_NOT_FOUND"
    case .sourceUnreadable: return "SOURCE_UNREADABLE"
    case .destinationNotDirectory: return "DEST_NOT_DIRECTORY"
    case .destinationNotWritable: return "DEST_NOT_WRITABLE"
    case .destinationSchemeUnsupported: return "DEST_SCHEME_UNSUPPORTED"
    case .entryEmpty: return "ENTRY_EMPTY"
    case .entryTooLong: return "ENTRY_TOO_LONG"
    case .entryUnsafeName: return "ENTRY_UNSAFE_NAME"
    case .entryAbsolutePath: return "ENTRY_ABSOLUTE_PATH"
    case .entryOutsideDestination: return "ENTRY_OUTSIDE_DESTINATION"
    case .entryDuplicate: return "ENTRY_DUPLICATE"
    case .symlinkInAncestry: return "SYMLINK_IN_ANCESTRY"
    case .wrongPassword: return "WRONG_PASSWORD"
    case .corruptArchive: return "CORRUPT_ARCHIVE"
    case .cancelled: return "CANCELLED"
    }
  }

  var errorDescription: String? {
    switch self {
    case .sourceNotFound(let url):
      return "Source ZIP file not found: \(url.path)"
    case .sourceUnreadable(let url, let underlying):
      return "Could not open ZIP file at \(url.path): \(underlying.localizedDescription)"
    case .destinationNotDirectory(let url):
      return "Destination path is not a directory: \(url.path)"
    case .destinationNotWritable(let url):
      return "Destination directory is not writable: \(url.path)"
    case .destinationSchemeUnsupported(let scheme):
      return "destinationPath must be a filesystem path or file:// URL " +
        "(got `\(scheme)://...`). Resolve content:// or http(s):// URIs " +
        "to filesystem paths before passing them in."
    case .entryEmpty:
      return "Refusing to extract empty entry name"
    case .entryTooLong(let actual, let max):
      return "Refusing to extract entry name longer than \(max) chars (got \(actual))"
    case .entryUnsafeName(let name):
      return "Refusing to extract entry containing control or BiDi-override character: \(name)"
    case .entryAbsolutePath(let name):
      return "Refusing to extract entry with absolute path: \(name)"
    case .entryOutsideDestination(let name, let resolved):
      return "Refusing to extract entry outside destination: \(name) (resolves to \(resolved.path))"
    case .entryDuplicate(let name):
      return "Refusing to extract duplicate entry (case-insensitive collision): \(name)"
    case .symlinkInAncestry(let url):
      return "Refusing to extract: \(url.path) is a symlink in the destination ancestry"
    case .wrongPassword:
      return "Wrong password or unencrypted archive"
    case .corruptArchive(let underlying):
      return "Could not read ZIP file: \(underlying.localizedDescription)"
    case .cancelled:
      return "Extraction cancelled"
    }
  }
}

/// Userinfo key under which `UnzipError.code` is surfaced when bridged to
/// `NSError`. Stable string — safe for consumers to import.
let NitroUnzipErrorCodeKey = "NitroUnzipErrorCode"

extension UnzipError {
  /// Bridge to NSError so the Nitro Promise rejection carries our typed
  /// `code` in `userInfo[NitroUnzipErrorCodeKey]`. JS callers can branch
  /// on `err.userInfo.NitroUnzipErrorCode` rather than parsing messages.
  var asNSError: NSError {
    NSError(
      domain: "NitroUnzip",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: errorDescription ?? code,
        NitroUnzipErrorCodeKey: code
      ]
    )
  }
}
