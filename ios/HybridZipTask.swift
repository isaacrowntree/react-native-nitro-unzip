import Foundation
import NitroModules
import UIKit
import ZIPFoundation

/// A single zip-creation operation as a proper HybridObject instance.
///
/// 0.4.0 iOS migration: same modernisation as `HybridUnzipTask`. Engine
/// swapped from SSZipArchive to ZIPFoundation for per-entry control, Swift
/// Concurrency for cancellation, typed errors, `URL`-based paths.
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

  // MARK: - Spec methods

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
        return try await self.compressInner()
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

  private func compressInner() async throws -> ZipResult {
    let startTime = Date()
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

    // NOTE: 0.4.0 leaves password-protected creation unsupported on iOS —
    // ZIPFoundation's password support is read-only. Surface a clear
    // error upfront rather than silently writing an unencrypted archive
    // that consumers would think is encrypted.
    if password != nil {
      throw UnzipError.corruptArchive(underlying: NSError(
        domain: "NitroUnzip",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Password-protected zip creation is not supported on iOS in 0.4.0"]
      ))
    }

    // Enumerate ALL files relative to source. We do this upfront so we
    // know the total count for accurate progress and so cancellation
    // can land between entries cleanly.
    let relativePaths = try collectRelativePaths(under: sourceURL)
    let totalFiles = relativePaths.count

    // Remove any pre-existing destination — ZIPFoundation's Archive
    // `.create` mode requires the file not to exist (or it'd append).
    if fileManager.fileExists(atPath: destURL.path) {
      try fileManager.removeItem(at: destURL)
    }

    let archive: Archive
    do {
      archive = try Archive(url: destURL, accessMode: .create)
    } catch {
      throw UnzipError.corruptArchive(underlying: error)
    }

    var compressedCount = 0
    var lastProgressUpdate = Date()

    for (index, relativePath) in relativePaths.enumerated() {
      try Task.checkCancellation()

      do {
        try archive.addEntry(
          with: relativePath,
          relativeTo: sourceURL,
          compressionMethod: .deflate
        )
      } catch {
        // On error mid-write, delete the partial archive so consumers
        // don't think the failure produced a valid file.
        try? fileManager.removeItem(at: destURL)
        throw UnzipError.corruptArchive(underlying: error)
      }
      compressedCount = index + 1

      let now = Date()
      let shouldEmit = compressedCount == 1
        || compressedCount == totalFiles
        || now.timeIntervalSince(lastProgressUpdate) >= progressThrottle
      if shouldEmit {
        emitProgress(
          compressedCount: compressedCount,
          totalFiles: totalFiles,
          startTime: startTime,
          now: now
        )
        lastProgressUpdate = now
      }
    }

    let duration = Date().timeIntervalSince(startTime) * 1000
    let avgSpeed = duration > 0 ? Double(compressedCount) / (duration / 1000) : 0
    let outAttrs = try? fileManager.attributesOfItem(atPath: destURL.path)
    let outSize = (outAttrs?[.size] as? UInt64).map(Double.init) ?? 0

    return ZipResult(
      success: true,
      compressedFiles: Double(compressedCount),
      totalFiles: Double(totalFiles),
      duration: duration,
      averageSpeed: avgSpeed,
      totalBytes: outSize
    )
  }

  /// Walk the source directory and return file paths relative to it.
  /// Skips directory entries — ZIPFoundation creates intermediate dirs as
  /// needed when entries are added.
  private func collectRelativePaths(under root: URL) throws -> [String] {
    let fileManager = FileManager.default
    var results: [String] = []
    let keys: [URLResourceKey] = [.isRegularFileKey]
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
      guard attrs.isRegularFile == true else { continue }
      let absPath = url.standardizedFileURL.path
      guard absPath.hasPrefix(rootPath) else { continue }
      results.append(String(absPath.dropFirst(rootPath.count)))
    }
    return results
  }

  private func emitProgress(
    compressedCount: Int,
    totalFiles: Int,
    startTime: Date,
    now: Date
  ) {
    lock.lock()
    let callback = progressCallback
    lock.unlock()
    guard let callback = callback else { return }

    let progress = totalFiles > 0 ? Double(compressedCount) / Double(totalFiles) : 0
    let elapsed = now.timeIntervalSince(startTime)
    let speed = elapsed > 0 ? Double(compressedCount) / elapsed : 0

    callback(ZipProgress(
      compressedFiles: Double(compressedCount),
      totalFiles: Double(totalFiles),
      progress: progress,
      speed: speed
    ))
  }

  // MARK: - Background task management

  private func beginBackgroundTask() {
    let bgId = UIApplication.shared.beginBackgroundTask(withName: "NitroZip-\(taskId)") { [weak self] in
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
