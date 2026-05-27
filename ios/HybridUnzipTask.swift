import Foundation
import NitroModules
import SSZipArchive
import UIKit
import ZIPFoundation

/// A single extraction operation as a proper HybridObject instance.
///
/// 0.4.0 iOS:
/// - Unencrypted archives use `ZIPFoundation` (pure Swift, iterable
///   `Archive` type) — gets per-entry validation via `ExtractionScope`
///   before any write, plus `Task.cancel()` honoured between entries.
/// - Password-protected archives fall back to `SSZipArchive` (the only
///   iOS ZIP library that supports AES read+write). Same path-safety
///   pre-validation via `ExtractionScope.safeURL`, then the actual
///   decrypt+extract delegates to SSZipArchive. SSZipArchive's
///   `unzipFile` is all-or-nothing so mid-extraction cancel is
///   best-effort here.
/// - `async`/`await` + `Task` + `Task.checkCancellation()` instead of
///   `NSLock` + `shouldCancel` + `DispatchQueue.global` flag machine.
/// - Typed `UnzipError` → `NSError.userInfo[NitroUnzipErrorCodeKey]`
///   so JS can `switch (err.userInfo.NitroUnzipErrorCode)`.
final class HybridUnzipTask: HybridUnzipTaskSpec {
  let taskId: String

  private let zipPath: String
  private let destinationPath: String
  private let password: String?

  private let lock = NSLock()
  private var progressCallback: ((_ progress: UnzipProgress) -> Void)?
  private var currentTask: Task<UnzipResult, Error>?
  private var awaitedPromise: Promise<UnzipResult>?
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  private let progressThrottle: TimeInterval = 1.0

  init(zipPath: String, destinationPath: String, password: String? = nil) {
    self.taskId = "unzip_\(ProcessInfo.processInfo.globallyUniqueString)"
    self.zipPath = zipPath
    self.destinationPath = destinationPath
    self.password = password
    super.init()
  }

  // MARK: - Spec methods

  func onProgress(callback: @escaping (_ progress: UnzipProgress) -> Void) throws {
    lock.lock()
    self.progressCallback = callback
    lock.unlock()
  }

  func cancel() throws {
    lock.lock()
    let task = currentTask
    lock.unlock()
    task?.cancel()
  }

  func await() throws -> Promise<UnzipResult> {
    lock.lock()
    if let cached = awaitedPromise {
      lock.unlock()
      return cached
    }
    let promise = Promise<UnzipResult>.async { [weak self] in
      guard let self = self else { throw UnzipError.cancelled.asNSError }
      return try await self.runExtraction()
    }
    awaitedPromise = promise
    lock.unlock()
    return promise
  }

  // MARK: - Extraction

  private func runExtraction() async throws -> UnzipResult {
    let task = Task { [weak self] () -> UnzipResult in
      guard let self = self else { throw UnzipError.cancelled.asNSError }
      do {
        if self.password != nil {
          return try await self.extractWithPassword()
        }
        return try await self.extractUnencrypted()
      } catch let error as UnzipError {
        throw error.asNSError
      } catch is CancellationError {
        throw UnzipError.cancelled.asNSError
      }
    }
    lock.lock()
    currentTask = task
    lock.unlock()
    beginBackgroundTask()
    defer { endBackgroundTask() }
    do {
      return try await task.value
    } catch {
      if Task.isCancelled || task.isCancelled {
        throw UnzipError.cancelled.asNSError
      }
      throw error
    }
  }

  /// ZIPFoundation path: per-entry validation + extraction, Task
  /// cancellation between entries.
  private func extractUnencrypted() async throws -> UnzipResult {
    let startTime = Date()
    let (scope, sourceURL, sourceSize) = try prepare()
    let fileManager = FileManager.default

    let archive: Archive
    do {
      archive = try Archive(url: sourceURL, accessMode: .read)
    } catch {
      throw UnzipError.corruptArchive(underlying: error)
    }

    var validated: [(entry: Entry, target: URL)] = []
    var seenDedupKeys = Set<String>()
    var totalFiles = 0

    for entry in archive {
      try Task.checkCancellation()
      let dedupKey = ExtractionScope.dedupKey(for: entry.path)
      if !seenDedupKeys.insert(dedupKey).inserted {
        throw UnzipError.entryDuplicate(entry.path)
      }
      let target = try scope.safeURL(forEntry: entry.path)
      validated.append((entry, target))
      if entry.type == .file {
        totalFiles += 1
      }
    }

    var extractedCount = 0
    var lastProgressUpdate = Date()
    var verifiedAncestors = Set<URL>()
    var createdDirs = Set<URL>()

    for (entry, target) in validated {
      try Task.checkCancellation()

      switch entry.type {
      case .directory:
        if createdDirs.insert(target).inserted {
          try scope.verifyAncestryClean(of: target, verified: &verifiedAncestors)
          try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
          try verifyInsideDest(target, scope: scope)
        }
      case .file:
        let parent = target.deletingLastPathComponent()
        if createdDirs.insert(parent).inserted {
          try scope.verifyAncestryClean(of: parent, verified: &verifiedAncestors)
          try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
          try verifyInsideDest(parent, scope: scope)
        }
        do {
          _ = try archive.extract(entry, to: target, skipCRC32: false)
        } catch let error as Archive.ArchiveError {
          throw UnzipError.corruptArchive(underlying: error)
        }
        try verifyInsideDest(target, scope: scope)
        extractedCount += 1
        emitIfDue(
          extractedCount: extractedCount,
          totalFiles: totalFiles,
          startTime: startTime,
          lastUpdate: &lastProgressUpdate,
          processedBytes: entry.uncompressedSize
        )
      case .symlink:
        // Symlink entries in archives are a direct Zip Slip vector.
        throw UnzipError.entryUnsafeName(entry.path)
      }
    }

    return buildResult(
      extractedFiles: extractedCount,
      totalFiles: totalFiles,
      startTime: startTime,
      totalBytes: sourceSize
    )
  }

  /// SSZipArchive path for AES-encrypted archives. Pre-validation goes
  /// through the same `ExtractionScope.safeURL` chain as the
  /// unencrypted path, so every path-safety guarantee holds identically
  /// here — only the decrypt+write step differs.
  private func extractWithPassword() async throws -> UnzipResult {
    let startTime = Date()
    let (scope, sourceURL, sourceSize) = try prepare()
    guard let password = password else {
      throw UnzipError.cancelled  // unreachable: caller checked
    }

    guard let entryNames = SSZipArchive.filesInArchive(atPath: sourceURL.path) as? [String] else {
      throw UnzipError.corruptArchive(underlying: NSError(
        domain: "NitroUnzip",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Could not enumerate ZIP entries"]
      ))
    }
    var seenDedupKeys = Set<String>()
    var totalFiles = 0
    for name in entryNames {
      try Task.checkCancellation()
      let dedupKey = ExtractionScope.dedupKey(for: name)
      if !seenDedupKeys.insert(dedupKey).inserted {
        throw UnzipError.entryDuplicate(name)
      }
      _ = try scope.safeURL(forEntry: name)
      if !name.hasSuffix("/") {
        totalFiles += 1
      }
    }

    // SSZipArchive's unzipFile is synchronous. Bridge to async via a
    // continuation. Mid-extraction cancel is best-effort — the closure
    // checks Task.isCancelled but SSZipArchive can't be aborted.
    var extractedCount = 0
    var lastProgressUpdate = Date()
    let throttle = progressThrottle

    let success: Bool = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        var error: NSError?
        let result = SSZipArchive.unzipFile(
          atPath: sourceURL.path,
          toDestination: scope.destDir.path,
          overwrite: true,
          password: password,
          error: &error,
          delegate: nil,
          progressHandler: { _, _, entryNumber, total in
            if Task.isCancelled { return }
            let count = Int(entryNumber)
            extractedCount = count
            let now = Date()
            let shouldEmit = count == 1
              || count == Int(total)
              || now.timeIntervalSince(lastProgressUpdate) >= throttle
            if shouldEmit {
              self.forwardProgress(
                extractedCount: count,
                totalFiles: Int(total),
                startTime: startTime,
                processedBytes: 0
              )
              lastProgressUpdate = now
            }
          },
          completionHandler: nil
        )
        if let error = error {
          // SSZipArchive's error messages are not stable but
          // "password" tends to appear in the wrong-password message.
          if error.localizedDescription.lowercased().contains("password") {
            continuation.resume(throwing: UnzipError.wrongPassword)
          } else {
            continuation.resume(throwing: UnzipError.corruptArchive(underlying: error))
          }
        } else {
          continuation.resume(returning: result)
        }
      }
    }

    try Task.checkCancellation()
    guard success else {
      throw UnzipError.corruptArchive(underlying: NSError(
        domain: "NitroUnzip",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Password-protected extraction failed"]
      ))
    }

    return buildResult(
      extractedFiles: extractedCount,
      totalFiles: totalFiles,
      startTime: startTime,
      totalBytes: sourceSize
    )
  }

  // MARK: - Helpers

  private func prepare() throws -> (ExtractionScope, URL, UInt64) {
    try ExtractionScope.requireFilesystemPath(destinationPath, paramName: "destinationPath")
    try ExtractionScope.requireFilesystemPath(zipPath, paramName: "zipPath")
    let scope = try ExtractionScope(destinationPath: destinationPath)
    let cleanZip = ExtractionScope.cleanFilesystemPath(zipPath)
    let sourceURL = URL(fileURLWithPath: cleanZip)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw UnzipError.sourceNotFound(sourceURL)
    }
    let sourceSize: UInt64 = {
      guard let attrs = try? fileManager.attributesOfItem(atPath: sourceURL.path),
            let size = attrs[.size] as? UInt64
      else { return 0 }
      return size
    }()
    return (scope, sourceURL, sourceSize)
  }

  /// Confirm `url` (and any symlinks in its ancestry) realises inside
  /// `scope.destDir`. Deletes the partial write on failure so a
  /// symlink-redirected file doesn't linger.
  private func verifyInsideDest(_ url: URL, scope: ExtractionScope) throws {
    let real = url.resolvingSymlinksInPath().standardizedFileURL
    if !real.path.hasPrefix(scope.destPrefix) && real != scope.destDir {
      try? FileManager.default.removeItem(at: url)
      throw UnzipError.entryOutsideDestination(name: url.lastPathComponent, resolved: real)
    }
  }

  private func emitIfDue(
    extractedCount: Int,
    totalFiles: Int,
    startTime: Date,
    lastUpdate: inout Date,
    processedBytes: UInt64
  ) {
    let now = Date()
    let shouldEmit = extractedCount == 1
      || extractedCount == totalFiles
      || now.timeIntervalSince(lastUpdate) >= progressThrottle
    guard shouldEmit else { return }
    forwardProgress(
      extractedCount: extractedCount,
      totalFiles: totalFiles,
      startTime: startTime,
      processedBytes: processedBytes
    )
    lastUpdate = now
  }

  private func forwardProgress(
    extractedCount: Int,
    totalFiles: Int,
    startTime: Date,
    processedBytes: UInt64
  ) {
    lock.lock()
    let callback = progressCallback
    lock.unlock()
    guard let callback = callback else { return }
    let progress = totalFiles > 0 ? Double(extractedCount) / Double(totalFiles) : 0
    let elapsed = Date().timeIntervalSince(startTime)
    let speed = elapsed > 0 ? Double(extractedCount) / elapsed : 0
    callback(UnzipProgress(
      extractedFiles: Double(extractedCount),
      totalFiles: Double(totalFiles),
      progress: progress,
      speed: speed,
      processedBytes: Double(processedBytes)
    ))
  }

  private func buildResult(
    extractedFiles: Int,
    totalFiles: Int,
    startTime: Date,
    totalBytes: UInt64
  ) -> UnzipResult {
    let duration = Date().timeIntervalSince(startTime) * 1000
    let avgSpeed = duration > 0 ? Double(extractedFiles) / (duration / 1000) : 0
    return UnzipResult(
      success: true,
      extractedFiles: Double(extractedFiles),
      totalFiles: Double(totalFiles),
      duration: duration,
      averageSpeed: avgSpeed,
      totalBytes: Double(totalBytes)
    )
  }

  // MARK: - Background task management

  private func beginBackgroundTask() {
    let bgId = UIApplication.shared.beginBackgroundTask(withName: "NitroUnzip-\(taskId)") { [weak self] in
      self?.lock.lock()
      let task = self?.currentTask
      self?.lock.unlock()
      task?.cancel()
      self?.endBackgroundTask()
    }
    lock.lock()
    backgroundTaskId = bgId
    lock.unlock()
  }

  private func endBackgroundTask() {
    lock.lock()
    let bgId = backgroundTaskId
    backgroundTaskId = .invalid
    lock.unlock()
    if bgId != .invalid {
      UIApplication.shared.endBackgroundTask(bgId)
    }
  }
}
