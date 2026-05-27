import Foundation
import NitroModules
import SSZipArchive
import UIKit
import ZIPFoundation

/// A single zip-creation operation as a proper HybridObject instance.
///
/// 0.4.0 iOS:
/// - Unencrypted archives use `ZIPFoundation` — per-entry control,
///   Task cancellation between entries.
/// - Password-protected archives use `SSZipArchive` (the only iOS ZIP
///   library that supports AES-encrypted CREATE).
/// - `async`/`await` + `Task` for concurrency. Typed `UnzipError` for
///   the failure surface.
final class HybridZipTask: HybridZipTaskSpec {
  let taskId: String

  private let sourcePath: String
  private let destinationZipPath: String
  private let password: String?

  private let lock = NSLock()
  private var progressCallback: ((_ progress: ZipProgress) -> Void)?
  private var currentTask: Task<ZipResult, Error>?
  private var awaitedPromise: Promise<ZipResult>?
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  private let progressThrottle: TimeInterval = 1.0

  init(sourcePath: String, destinationZipPath: String, password: String? = nil) {
    self.taskId = "zip_\(ProcessInfo.processInfo.globallyUniqueString)"
    self.sourcePath = sourcePath
    self.destinationZipPath = destinationZipPath
    self.password = password
    super.init()
  }

  func onProgress(callback: @escaping (_ progress: ZipProgress) -> Void) throws {
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

  func await() throws -> Promise<ZipResult> {
    lock.lock()
    if let cached = awaitedPromise {
      lock.unlock()
      return cached
    }
    let promise = Promise<ZipResult>.async { [weak self] in
      guard let self = self else { throw UnzipError.cancelled.asNSError }
      return try await self.runCompression()
    }
    awaitedPromise = promise
    lock.unlock()
    return promise
  }

  // MARK: - Compression

  private func runCompression() async throws -> ZipResult {
    let task = Task { [weak self] () -> ZipResult in
      guard let self = self else { throw UnzipError.cancelled.asNSError }
      do {
        if self.password != nil {
          return try await self.compressWithPassword()
        }
        return try await self.compressUnencrypted()
      } catch let error as UnzipError {
        throw error.asNSError
      } catch is CancellationError {
        throw UnzipError.cancelled.asNSError
      }
    }
    lock.lock()
    currentTask = task
    lock.unlock()
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

  private func compressUnencrypted() async throws -> ZipResult {
    let startTime = Date()
    let (sourceURL, destURL, relativePaths) = try prepare()
    // `totalFiles` is the file-count contract — the unzip side gates on
    // `entry.type == .file`. Trailing-slash entries are directory
    // placeholders, not files, so they must NOT inflate this number.
    let totalFiles = relativePaths.reduce(into: 0) { acc, path in
      if !path.hasSuffix("/") { acc += 1 }
    }

    let archive: Archive
    do {
      archive = try Archive(url: destURL, accessMode: .create)
    } catch {
      throw UnzipError.corruptArchive(underlying: error)
    }

    var compressedCount = 0
    var lastProgressUpdate = Date()

    for relativePath in relativePaths {
      try Task.checkCancellation()
      do {
        try archive.addEntry(
          with: relativePath,
          relativeTo: sourceURL,
          compressionMethod: .deflate
        )
      } catch {
        try? FileManager.default.removeItem(at: destURL)
        throw UnzipError.corruptArchive(underlying: error)
      }
      if !relativePath.hasSuffix("/") {
        compressedCount += 1
        emitIfDue(
          compressedCount: compressedCount,
          totalFiles: totalFiles,
          startTime: startTime,
          lastUpdate: &lastProgressUpdate
        )
      }
    }

    return buildResult(
      compressedFiles: compressedCount,
      totalFiles: totalFiles,
      startTime: startTime,
      destURL: destURL
    )
  }

  private func compressWithPassword() async throws -> ZipResult {
    let startTime = Date()
    let (sourceURL, destURL, relativePaths) = try prepare()
    // Match the unzip-side contract: count only file entries, not the
    // trailing-slash directory placeholders collectRelativePaths emits.
    let totalFiles = relativePaths.reduce(into: 0) { acc, path in
      if !path.hasSuffix("/") { acc += 1 }
    }
    guard let password = password else {
      throw UnzipError.cancelled  // unreachable
    }

    var lastProgressUpdate = Date()
    let throttle = progressThrottle
    lock.lock()
    let outerTask = currentTask
    lock.unlock()

    let success: Bool = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        // Use SSZipArchive's AES-256 variant. The other overload
        // (`withPassword:`) writes traditional PKWARE encryption — broken,
        // crackable in minutes. AES: true matches the Android zip4j path
        // (AES-256) so cross-platform password archives have equivalent
        // crypto strength.
        let result = SSZipArchive.createZipFile(
          atPath: destURL.path,
          withContentsOfDirectory: sourceURL.path,
          keepParentDirectory: false,
          compressionLevel: -1,  // Z_DEFAULT_COMPRESSION
          password: password,
          aes: true,
          progressHandler: { entryNumber, total in
            // Same captured-Task pattern as the unzip side: Task.isCancelled
            // is task-local and returns false on the DispatchQueue worker.
            if outerTask?.isCancelled == true { return }
            let count = Int(entryNumber)
            let totalInt = Int(total)
            let now = Date()
            let shouldEmit = count == 1
              || count == totalInt
              || now.timeIntervalSince(lastProgressUpdate) >= throttle
            if shouldEmit {
              self.forwardProgress(
                compressedCount: count,
                totalFiles: totalInt,
                startTime: startTime
              )
              lastProgressUpdate = now
            }
          }
        )
        if result {
          continuation.resume(returning: result)
        } else {
          continuation.resume(throwing: UnzipError.corruptArchive(underlying: NSError(
            domain: "NitroUnzip",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Password-protected zip creation failed"]
          )))
        }
      }
    }

    try Task.checkCancellation()
    guard success else {
      try? FileManager.default.removeItem(at: destURL)
      throw UnzipError.corruptArchive(underlying: NSError(
        domain: "NitroUnzip",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Password-protected zip creation failed"]
      ))
    }

    return buildResult(
      compressedFiles: totalFiles,
      totalFiles: totalFiles,
      startTime: startTime,
      destURL: destURL
    )
  }

  // MARK: - Helpers

  private func prepare() throws -> (URL, URL, [String]) {
    try ExtractionScope.requireFilesystemPath(sourcePath, paramName: "sourcePath")
    try ExtractionScope.requireFilesystemPath(destinationZipPath, paramName: "destinationZipPath")
    let cleanSource = ExtractionScope.cleanFilesystemPath(sourcePath)
    let cleanDest = ExtractionScope.cleanFilesystemPath(destinationZipPath)
    let fileManager = FileManager.default
    let sourceURL = URL(fileURLWithPath: cleanSource)
    let destURL = URL(fileURLWithPath: cleanDest)
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw UnzipError.sourceNotFound(sourceURL)
    }
    if fileManager.fileExists(atPath: destURL.path) {
      try fileManager.removeItem(at: destURL)
    }
    let relativePaths = try collectRelativePaths(under: sourceURL)
    return (sourceURL, destURL, relativePaths)
  }

  /// Walk the source tree and return entries to add to the archive.
  /// Emits BOTH regular files AND directories (as trailing-slash entries)
  /// so empty placeholder directories — `cache/`, `logs/`, etc. — survive
  /// a zip+unzip round trip. The 0.3-era SSZipArchive path included
  /// these via `createZipFile(withContentsOfDirectory:)`; 0.4.0 keeps
  /// the contract intact.
  private func collectRelativePaths(under root: URL) throws -> [String] {
    let fileManager = FileManager.default
    var results: [String] = []
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: []
    ) else {
      return []
    }
    let rootPath = root.standardizedFileURL.path + "/"
    for case let url as URL in enumerator {
      let attrs = try url.resourceValues(forKeys: Set(keys))
      let absPath = url.standardizedFileURL.path
      guard absPath.hasPrefix(rootPath) else { continue }
      let relative = String(absPath.dropFirst(rootPath.count))
      if attrs.isRegularFile == true {
        results.append(relative)
      } else if attrs.isDirectory == true {
        // Directory entries get a trailing slash so the unzip side
        // recognises them as `.directory` entries (matches the ZIP spec
        // and what ZIPFoundation's iteration expects).
        results.append(relative + "/")
      }
    }
    return results
  }

  private func emitIfDue(
    compressedCount: Int,
    totalFiles: Int,
    startTime: Date,
    lastUpdate: inout Date
  ) {
    let now = Date()
    let shouldEmit = compressedCount == 1
      || compressedCount == totalFiles
      || now.timeIntervalSince(lastUpdate) >= progressThrottle
    guard shouldEmit else { return }
    forwardProgress(
      compressedCount: compressedCount,
      totalFiles: totalFiles,
      startTime: startTime
    )
    lastUpdate = now
  }

  private func forwardProgress(
    compressedCount: Int,
    totalFiles: Int,
    startTime: Date
  ) {
    lock.lock()
    let callback = progressCallback
    lock.unlock()
    guard let callback = callback else { return }
    let progress = totalFiles > 0 ? Double(compressedCount) / Double(totalFiles) : 0
    let elapsed = Date().timeIntervalSince(startTime)
    let speed = elapsed > 0 ? Double(compressedCount) / elapsed : 0
    callback(ZipProgress(
      compressedFiles: Double(compressedCount),
      totalFiles: Double(totalFiles),
      progress: progress,
      speed: speed
    ))
  }

  private func buildResult(
    compressedFiles: Int,
    totalFiles: Int,
    startTime: Date,
    destURL: URL
  ) -> ZipResult {
    let duration = Date().timeIntervalSince(startTime) * 1000
    let avgSpeed = duration > 0 ? Double(compressedFiles) / (duration / 1000) : 0
    let outAttrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
    let outSize = (outAttrs?[.size] as? UInt64) ?? 0
    return ZipResult(
      success: true,
      compressedFiles: Double(compressedFiles),
      totalFiles: Double(totalFiles),
      duration: duration,
      averageSpeed: avgSpeed,
      totalBytes: Double(outSize)
    )
  }

  // MARK: - Background task management

  private func beginBackgroundTask() async {
    let bgId = await MainActor.run {
      UIApplication.shared.beginBackgroundTask(withName: "NitroZip-\(taskId)") { [weak self] in
        guard let self = self else { return }
        self.lock.lock()
        let task = self.currentTask
        self.lock.unlock()
        task?.cancel()
        Task { await self.endBackgroundTask() }
      }
    }
    lock.lock()
    backgroundTaskId = bgId
    lock.unlock()
  }

  private func endBackgroundTask() async {
    lock.lock()
    let bgId = backgroundTaskId
    backgroundTaskId = .invalid
    lock.unlock()
    if bgId != .invalid {
      await MainActor.run {
        UIApplication.shared.endBackgroundTask(bgId)
      }
    }
  }
}
