import Foundation
import NitroModules
import UIKit
import ZIPFoundation

/// A single extraction operation as a proper HybridObject instance.
///
/// 0.4.0 iOS migration:
/// - **Engine**: `ZIPFoundation` (pure Swift, iterable `Archive` type)
///   replaces SSZipArchive. Lets us pre-validate every entry's path BEFORE
///   writing any file and honour `Task.cancel()` between entries — neither
///   was possible with SSZipArchive's all-or-nothing `unzipFile` API.
/// - **Concurrency**: Swift `async/await` + `Task` + `Task.checkCancellation()`
///   replaces the `NSLock` + `shouldCancel` + `DispatchQueue.global` model.
///   No bridge code between the JS-side cancel and the in-flight extraction —
///   Task cancellation is the contract.
/// - **Errors**: typed `UnzipError` enum with stable `code` surfaced via
///   `NSError.userInfo[NitroUnzipErrorCodeKey]`. JS callers branch on
///   `err.userInfo.NitroUnzipErrorCode` instead of substring-matching
///   localised messages.
/// - **Paths**: Foundation `URL` throughout, not `String`. `ExtractionScope`
///   centralises path validation; `CharacterSet` catches unsafe filename
///   codepoints (BiDi, controls, NUL).
/// - **Symlink safety**: per-entry ancestry walk via
///   `URLResourceKey.isSymbolicLinkKey` before any mkdir/write, matching
///   the Android `createDirectoryAndVerify` guarantee.
///
/// This is parity with Android 0.4.0, implemented purely with
/// iOS/Foundation primitives — not a Java translation.
final class HybridUnzipTask: HybridUnzipTaskSpec {
  let taskId: String

  private let zipPath: String
  private let destinationPath: String
  private let password: String?

  /// `@Atomic`-equivalent via a serial queue on the instance. iOS-idiomatic
  /// for shared mutable state between the JS-bridge thread and the
  /// extraction Task.
  private let lock = NSLock()
  private var progressCallback: ((_ progress: UnzipProgress) -> Void)?
  private var currentTask: Task<UnzipResult, Error>?
  private var awaitedPromise: Promise<UnzipResult>?
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  private let progressThrottle: TimeInterval = 1.0

  init(zipPath: String, destinationPath: String, password: String? = nil) {
    // ProcessInfo.globallyUniqueString = UUID + boot-time prefix —
    // collision-free even across rapid construction on a single core.
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

  /// Cancel an in-flight extraction. No-op if `await()` hasn't been called
  /// (matches the Android contract: cancel-before-await must not poison
  /// the cached Promise — the next `await()` proceeds normally).
  func cancel() throws {
    lock.lock()
    let task = currentTask
    lock.unlock()
    task?.cancel()
  }

  /// Returns the cached `Promise<UnzipResult>` from the first call. Second
  /// and subsequent calls return the same Promise rather than launching a
  /// duplicate extraction that would race writes against the first.
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

  /// Top-level extraction driver. Captures a Task handle so `cancel()` can
  /// reach in and propagate cancellation, manages the background task for
  /// continued execution if the app backgrounds, and translates typed
  /// `UnzipError`s into the NSError shape Nitro expects.
  private func runExtraction() async throws -> UnzipResult {
    let task = Task { [weak self] () -> UnzipResult in
      guard let self = self else { throw UnzipError.cancelled.asNSError }
      do {
        return try await self.extractInner()
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

  private func extractInner() async throws -> UnzipResult {
    let startTime = Date()

    // 1. Validate scheme/empty/destination upfront. Throws typed errors
    //    that the bridge translates to JS error codes.
    try ExtractionScope.requireFilesystemPath(destinationPath, paramName: "destinationPath")
    try ExtractionScope.requireFilesystemPath(zipPath, paramName: "zipPath")

    let scope = try ExtractionScope(destinationPath: destinationPath)

    let cleanZip = ExtractionScope.cleanFilesystemPath(zipPath)
    let sourceURL = URL(fileURLWithPath: cleanZip)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw UnzipError.sourceNotFound(sourceURL)
    }

    // Cache source size BEFORE extraction — if the source is unlinked
    // between extraction completion and result construction (POSIX permits
    // this while our open Archive holds a reference), the cached size
    // still produces a valid UnzipResult instead of failing-after-success.
    let sourceSize: UInt64 = {
      guard let attrs = try? fileManager.attributesOfItem(atPath: sourceURL.path),
            let size = attrs[.size] as? UInt64
      else { return 0 }
      return size
    }()

    // 2. Open the archive. ZIPFoundation's `Archive` reads the central
    //    directory eagerly, so once construction succeeds we have an O(1)
    //    iterator over entries.
    let archive: Archive
    do {
      archive = try Archive(url: sourceURL, accessMode: .read)
    } catch {
      throw UnzipError.corruptArchive(underlying: error)
    }

    // 3. Pre-validation pass — collect resolved URLs while rejecting any
    //    malicious entry upfront. Same security contract as Android:
    //    archive is rejected as a whole; zero partial state on rejection.
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

    // 4. Extraction pass.
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
          // Backstop: post-mkdir, confirm the realised path is still inside
          // destDir (catches an injected symlink that raced the precheck).
          try verifyInsideDest(target, scope: scope)
        }
      case .file:
        let parent = target.deletingLastPathComponent()
        if createdDirs.insert(parent).inserted {
          try scope.verifyAncestryClean(of: parent, verified: &verifiedAncestors)
          try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
          try verifyInsideDest(parent, scope: scope)
        }
        // ZIPFoundation's `extract(_:to:)` writes the entry via an internal
        // buffered stream. If a symlink is injected at `target` between
        // ancestry-check and the write, the post-write check catches it
        // and we delete the bogus file.
        do {
          _ = try archive.extract(entry, to: target, skipCRC32: false)
        } catch let error as Archive.ArchiveError {
          if error == .invalidPassword {
            throw UnzipError.wrongPassword
          }
          throw UnzipError.corruptArchive(underlying: error)
        }
        try verifyInsideDest(target, scope: scope)
        extractedCount += 1

        // Throttle progress — matches the Android 1s throttle, with
        // first-and-last always firing.
        let now = Date()
        let shouldEmit = extractedCount == 1
          || extractedCount == totalFiles
          || now.timeIntervalSince(lastProgressUpdate) >= progressThrottle
        if shouldEmit {
          emitProgress(
            extractedCount: extractedCount,
            totalFiles: totalFiles,
            startTime: startTime,
            now: now,
            entry: entry
          )
          lastProgressUpdate = now
        }
      case .symlink:
        // Symlink entries in archives — never honour these; they're a
        // direct Zip-Slip vector. Treat as a security violation.
        throw UnzipError.entryUnsafeName(entry.path)
      }
    }

    let duration = Date().timeIntervalSince(startTime) * 1000 // ms
    let avgSpeed = duration > 0 ? Double(extractedCount) / (duration / 1000) : 0

    return UnzipResult(
      success: true,
      extractedFiles: Double(extractedCount),
      totalFiles: Double(totalFiles),
      duration: duration,
      averageSpeed: avgSpeed,
      totalBytes: Double(sourceSize)
    )
  }

  /// Resolves `url` against the filesystem (following any symlinks) and
  /// asserts the realised path is still under `scope.destDir`. Catches a
  /// symlink injected between the pre-mkdir ancestry walk and the actual
  /// syscall.
  private func verifyInsideDest(_ url: URL, scope: ExtractionScope) throws {
    let real = url.resolvingSymlinksInPath().standardizedFileURL
    if !real.path.hasPrefix(scope.destPrefix) && real != scope.destDir {
      // Pull the bogus write back — extraction is aborting and we don't
      // want to leave the symlink-redirected file on disk for an attacker
      // to reference.
      try? FileManager.default.removeItem(at: url)
      throw UnzipError.entryOutsideDestination(name: url.lastPathComponent, resolved: real)
    }
  }

  private func emitProgress(
    extractedCount: Int,
    totalFiles: Int,
    startTime: Date,
    now: Date,
    entry: Entry
  ) {
    lock.lock()
    let callback = progressCallback
    lock.unlock()
    guard let callback = callback else { return }

    let progress = totalFiles > 0 ? Double(extractedCount) / Double(totalFiles) : 0
    let elapsed = now.timeIntervalSince(startTime)
    let speed = elapsed > 0 ? Double(extractedCount) / elapsed : 0

    callback(UnzipProgress(
      extractedFiles: Double(extractedCount),
      totalFiles: Double(totalFiles),
      progress: progress,
      speed: speed,
      processedBytes: Double(entry.uncompressedSize)
    ))
  }

  // MARK: - Background task management

  private func beginBackgroundTask() {
    let bgId = UIApplication.shared.beginBackgroundTask(withName: "NitroUnzip-\(taskId)") { [weak self] in
      // OS is reclaiming our background time — cancel cleanly.
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
