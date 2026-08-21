import Darwin
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
// Sendable is asserted rather than derived: every mutable stored property
// (progressCallback, currentTask, awaitedPromise, backgroundTaskId) is read
// and written only inside the `lock` critical sections below, so instances
// are safe to share across the DispatchQueue workers that SSZipArchive and
// the background-task expiration handler call back on.
final class HybridUnzipTask: HybridUnzipTaskSpec, @unchecked Sendable {
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
    lock.withLockSync { currentTask = task }
    await beginBackgroundTask()
    do {
      let result = try await task.value
      await endBackgroundTask()
      return result
    } catch {
      await endBackgroundTask()
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
    // Track everything we wrote so we can roll back on a mid-stream
    // failure (corrupt entry, disk full, cancellation between entries).
    // CHANGELOG promises "zero partial state on rejection" — that was
    // only true for the pre-validation rejection path before; this
    // closes the gap for mid-extraction failures too.
    var extractedTargets: [URL] = []
    var createdDirTargets: [URL] = []

    do {
      for (entry, target) in validated {
        try Task.checkCancellation()

        switch entry.type {
        case .directory:
          if createdDirs.insert(target).inserted {
            try scope.verifyAncestryClean(of: target, verified: &verifiedAncestors)
            try createTrackedDirectory(
              at: target,
              scope: scope,
              fileManager: fileManager,
              createdDirs: &createdDirs,
              createdDirTargets: &createdDirTargets
            )
          }
        case .file:
          let parent = target.deletingLastPathComponent()
          if createdDirs.insert(parent).inserted {
            try scope.verifyAncestryClean(of: parent, verified: &verifiedAncestors)
            try createTrackedDirectory(
              at: parent,
              scope: scope,
              fileManager: fileManager,
              createdDirs: &createdDirs,
              createdDirTargets: &createdDirTargets
            )
          }
          // Stream-write via POSIX open(O_NOFOLLOW) so the kernel refuses
          // to follow a symlink that raced into the target path between
          // ancestry validation and this write.
          try writeEntryNoFollow(entry: entry, target: target, archive: archive)
          extractedTargets.append(target)
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
    } catch {
      // Mid-extraction failure — roll back so we don't leave a half-
      // extracted archive on disk that looks complete. Logic lives in
      // `PartialExtractionRollback` so it can be unit-tested directly.
      PartialExtractionRollback.rollback(
        files: extractedTargets,
        directories: createdDirTargets
      )
      throw error
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

    // SSZipArchive 2.6.0 removed `+filesInArchive:`. Use ZIPFoundation
    // to enumerate entries (it CAN read AES headers, it just can't
    // decrypt the data — decrypt is what SSZipArchive does below).
    let enumerateArchive: Archive
    do {
      enumerateArchive = try Archive(url: sourceURL, accessMode: .read)
    } catch {
      throw UnzipError.corruptArchive(underlying: error)
    }
    let entryNames = enumerateArchive.map { $0.path }
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
    // continuation. Mid-extraction cancel is best-effort — SSZipArchive
    // can't be aborted, but we observe cancellation via the captured
    // Task reference (NOT `Task.isCancelled`, which would always return
    // false inside a `DispatchQueue.global` closure that runs outside
    // any Task context).
    let extractedCount = LockedValue(0)
    let throttle = ProgressThrottle(interval: progressThrottle)
    let outerTask = lock.withLockSync { currentTask }

    let success: Bool = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        var error: NSError?
        // SSZipArchive 2.6.0 dropped the (preserve+overwrite+password
        // +error+delegate+progressHandler) variant. The closest stable
        // signature now requires `preserveAttributes` and
        // `nestedZipLevel` — flat extraction (nestedZipLevel: 0)
        // matches the unencrypted ZIPFoundation path's behaviour.
        let result = SSZipArchive.unzipFile(
          atPath: sourceURL.path,
          toDestination: scope.destDir.path,
          preserveAttributes: true,
          overwrite: true,
          nestedZipLevel: 0,
          password: password,
          error: &error,
          delegate: nil,
          progressHandler: { _, _, entryNumber, total in
            // Read cancellation from the captured Task — Task.isCancelled
            // is task-local and returns false on a DispatchQueue worker
            // thread. The Task instance's `isCancelled` works from any
            // thread.
            if outerTask?.isCancelled == true { return }
            // SSZipArchive's unzip progressHandler reports a ZERO-BASED index:
            // `currentFileNumber` starts at -1 and is incremented before the
            // callback, so the first entry arrives as 0 and the last as
            // total-1. Treating it as a count made `extractedFiles` report one
            // less than reality (0 for a single-entry archive) and, because
            // neither `count == 1` nor `count == total` ever matched,
            // suppressed every progress callback on that path.
            //
            // Note the zip-side handler in HybridZipTask is NOT zero-based --
            // SSZipArchive increments before calling there -- so it must not
            // get the same adjustment.
            let count = Int(entryNumber) + 1
            extractedCount.set(count)
            // First and last entry always emit; the rest are rate limited,
            // with the compare-and-record done atomically in the throttle.
            let force = count == 1 || count == Int(total)
            if throttle.shouldEmit(force: force) {
              self.forwardProgress(
                extractedCount: count,
                totalFiles: Int(total),
                startTime: startTime,
                processedBytes: 0
              )
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
      extractedFiles: extractedCount.value,
      totalFiles: totalFiles,
      startTime: startTime,
      totalBytes: sourceSize
    )
  }

  // MARK: - Helpers

  /// Stream-write an entry to `target` using POSIX `open(O_NOFOLLOW)` so
  /// the kernel refuses a symlink at the target. Decompression is driven
  /// by ZIPFoundation's consumer-style extract; bytes flow chunk-by-chunk
  /// into the FD without an intermediate URL-based write call.
  private func writeEntryNoFollow(
    entry: Entry,
    target: URL,
    archive: Archive
  ) throws {
    let fd = target.path.withCString { path -> Int32 in
      // O_CLOEXEC — don't leak the FD across exec().
      // O_NOFOLLOW — refuse to open if final component is a symlink (ELOOP).
      // 0o644 — same default mode FileManager / FileHandle use.
      return Darwin.open(path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
    }
    if fd < 0 {
      let err = errno
      if err == ELOOP {
        throw UnzipError.symlinkInAncestry(target)
      }
      throw UnzipError.corruptArchive(underlying: NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(err),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))]
      ))
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    defer {
      try? handle.close()
    }
    do {
      _ = try archive.extract(entry, bufferSize: 65536, skipCRC32: false) { data in
        // Propagate write failures (disk full, FD closed, ENOSPC) up
        // through ZIPFoundation's throwing consumer — the prior `try?`
        // silently dropped them and let extract think it succeeded,
        // committing a truncated file to disk and skipping rollback.
        try handle.write(contentsOf: data)
      }
    } catch let error as Archive.ArchiveError {
      // Clean up partial write on failure so a half-decompressed file
      // doesn't get mistaken for a complete extraction.
      try? FileManager.default.removeItem(at: target)
      throw UnzipError.corruptArchive(underlying: error)
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw UnzipError.corruptArchive(underlying: error)
    }
  }

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

  /// Create `target` plus every missing ancestor between it and
  /// `scope.destDir`, recording each newly-created level in
  /// `createdDirTargets` for rollback. The previous one-shot
  /// `createDirectory(withIntermediateDirectories: true)` call left
  /// intermediates untracked — a mid-stream failure would only rewind the
  /// leaf, leaving stranded empty dirs in dest. Order matters: each level
  /// is appended *before* `verifyInsideDest` runs against it, so a
  /// symlink-race that flunks `verifyInsideDest` still gets rolled back
  /// (rather than silently leaking the dir we just created).
  private func createTrackedDirectory(
    at target: URL,
    scope: ExtractionScope,
    fileManager: FileManager,
    createdDirs: inout Set<URL>,
    createdDirTargets: inout [URL]
  ) throws {
    // Walk from target upward, collecting ancestors that don't exist yet
    // and stop at destDir (we never delete destDir on rollback).
    var toCreate: [URL] = []
    var cursor = target.standardizedFileURL
    let destDir = scope.destDir.standardizedFileURL
    while cursor != destDir {
      var isDir: ObjCBool = false
      let exists = fileManager.fileExists(atPath: cursor.path, isDirectory: &isDir)
      if exists && isDir.boolValue {
        break
      }
      toCreate.append(cursor)
      let parent = cursor.deletingLastPathComponent().standardizedFileURL
      // Defensive: if deletingLastPathComponent stops making progress
      // (e.g. cursor already == "/"), break to avoid an infinite loop.
      // In practice safeURL guarantees `target` lives under destDir.
      if parent == cursor { break }
      cursor = parent
    }
    // Create deepest-first... actually shallowest-first so each level's
    // parent exists when we create the child.
    for level in toCreate.reversed() {
      try fileManager.createDirectory(at: level, withIntermediateDirectories: false)
      // Track BEFORE verifyInsideDest so a verify failure still triggers
      // rollback for this newly-created level.
      createdDirs.insert(level)
      createdDirTargets.append(level)
      try verifyInsideDest(level, scope: scope)
    }
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
  //
  // `UIApplication.shared` is `@MainActor` per the Swift overlay, so
  // any access from a non-Main context (these methods run inside the
  // Promise.async background Task) triggers strict-concurrency errors
  // in Swift 6. Wrap the calls in `MainActor.run` — runtime overhead
  // is one Main-thread hop per extraction (twice per extract: begin +
  // end), which is negligible vs the actual extraction work.

  private func beginBackgroundTask() async {
    let bgId = await MainActor.run {
      UIApplication.shared.beginBackgroundTask(withName: "NitroUnzip-\(taskId)") { [weak self] in
        // Expiration handler can fire on any thread; route cancellation
        // through the task pointer without re-entering the actor.
        guard let self = self else { return }
        self.lock.lock()
        let task = self.currentTask
        self.lock.unlock()
        task?.cancel()
        // End the bg task on Main without blocking the OS expiration
        // callback — fire-and-forget Task is fine here.
        Task { await self.endBackgroundTask() }
      }
    }
    lock.withLockSync { backgroundTaskId = bgId }
  }

  private func endBackgroundTask() async {
    let bgId = lock.withLockSync {
      let id = backgroundTaskId
      backgroundTaskId = .invalid
      return id
    }
    if bgId != .invalid {
      await MainActor.run {
        UIApplication.shared.endBackgroundTask(bgId)
      }
    }
  }
}
