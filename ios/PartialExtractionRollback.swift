import Foundation

/// Best-effort cleanup of a partial extraction. Called from
/// `HybridUnzipTask.extractUnencrypted` when extraction throws
/// mid-stream — corrupt entry, disk full, cancellation between entries,
/// etc. Without this, a half-extracted archive would linger on disk and
/// could be mistaken for a complete extraction by the calling app.
///
/// Pulled out as a `public` helper on `NitroUnzipCore` so it has a stable
/// SPM-test surface independent of the Nitro-coupled Hybrid classes.
///
/// Deletion strategy:
/// - Files first, in reverse order so the LAST-written entries (most
///   likely partial/truncated) go first.
/// - Then directories sorted by descending path length so the deepest
///   leaves go before their parents — avoids `removeItem` returning a
///   stranded-non-empty-dir error on macOS's older POSIX layer.
/// - Everything is best-effort (`try?`); a failed delete is logged via
///   the optional `onError` callback but doesn't stop the rollback.
public enum PartialExtractionRollback {
  /// Roll back a set of partial writes. The `fileManager` parameter is
  /// injectable for testing — pass `.default` in production.
  public static func rollback(
    files: [URL],
    directories: [URL],
    fileManager: FileManager = .default,
    onError: ((URL, Error) -> Void)? = nil
  ) {
    for url in files.reversed() {
      do {
        try fileManager.removeItem(at: url)
      } catch {
        onError?(url, error)
      }
    }
    // Sort by descending path-component count so child dirs always go
    // before their parents — path *string* length is a fragile proxy
    // because two unrelated subtrees can have identical lengths at
    // different depths.
    let sortedDirs = directories.sorted { $0.pathComponents.count > $1.pathComponents.count }
    for url in sortedDirs {
      do {
        try fileManager.removeItem(at: url)
      } catch {
        onError?(url, error)
      }
    }
  }
}
