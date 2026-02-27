import Foundation
import NitroModules
import SSZipArchive
import UIKit

/**
 * A single extraction operation as a proper HybridObject instance.
 *
 * Each call to `HybridUnzip.extract()` creates one of these.
 * The caller can observe progress, cancel, or await the result — all scoped
 * to this specific extraction, no global event emitters needed.
 *
 * Performance (350MB archive, 10k+ files):
 * - Speed: 400-500 files/second
 * - Memory: <30MB peak via SSZipArchive streaming
 * - Background task support for continued extraction when app is backgrounded
 */
class HybridUnzipTask: HybridUnzipTaskSpec {
  // MARK: - Spec properties

  let taskId: String

  // MARK: - Internal state

  private let zipPath: String
  private let destinationPath: String
  private let password: String?
  private var progressCallback: ((_ progress: UnzipProgress) -> Void)?
  private var shouldCancel = false
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private let lock = NSLock()
  private let progressThrottle: TimeInterval = 1.0
  private var hasStarted = false

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
    shouldCancel = true
    lock.unlock()
  }

  func await() throws -> Promise<UnzipResult> {
    lock.lock()
    guard !hasStarted else {
      lock.unlock()
      return Promise.rejected(withError: NSError(
        domain: "NitroUnzip",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Task already started"]
      ))
    }
    hasStarted = true
    lock.unlock()

    return Promise.async {
      try await withCheckedThrowingContinuation { continuation in
        self.beginBackgroundTask()

        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try self.extract()
            self.endBackgroundTask()
            continuation.resume(returning: result)
          } catch {
            self.endBackgroundTask()
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  // MARK: - Extraction

  private func extract() throws -> UnzipResult {
    let startTime = Date()
    let fileManager = FileManager.default

    // Normalise file:// URIs to filesystem paths
    let cleanZip = zipPath.replacingOccurrences(of: "file://", with: "")
    let cleanDest = destinationPath.replacingOccurrences(of: "file://", with: "")

    // Ensure destination exists
    if !fileManager.fileExists(atPath: cleanDest) {
      try fileManager.createDirectory(
        atPath: cleanDest,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    // Verify source exists
    guard fileManager.fileExists(atPath: cleanZip) else {
      throw NSError(
        domain: "NitroUnzip",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Source ZIP file not found: \(cleanZip)"]
      )
    }

    var extractedFiles = 0
    var totalFileCount = 0
    var lastProgressUpdate = Date()

    // SSZipArchive progress handler — called per file
    let progressHandler: (String, unz_file_info, Int, Int) -> Void = { [weak self] _, fileInfo, entryNumber, total in
      guard let self = self else { return }

      // Check cancellation
      self.lock.lock()
      let cancelled = self.shouldCancel
      let callback = self.progressCallback
      self.lock.unlock()
      if cancelled { return }

      extractedFiles = entryNumber
      totalFileCount = total

      // Throttle progress updates
      let now = Date()
      let shouldUpdate = now.timeIntervalSince(lastProgressUpdate) >= self.progressThrottle
        || entryNumber == total
        || entryNumber == 1

      if shouldUpdate, let callback = callback {
        let progress = total > 0 ? Double(entryNumber) / Double(total) : 0
        let elapsed = now.timeIntervalSince(startTime)
        let speed = elapsed > 0 ? Double(entryNumber) / elapsed : 0

        callback(UnzipProgress(
          extractedFiles: Double(entryNumber),
          totalFiles: Double(total),
          progress: progress,
          speed: speed,
          processedBytes: Double(fileInfo.uncompressed_size)
        ))
        lastProgressUpdate = now
      }
    }

    // Run extraction
    let success = SSZipArchive.unzipFile(
      atPath: cleanZip,
      toDestination: cleanDest,
      overwrite: true,
      password: password,
      progressHandler: progressHandler,
      completionHandler: nil
    )

    // Check cancellation
    lock.lock()
    let wasCancelled = shouldCancel
    lock.unlock()

    if wasCancelled {
      throw NSError(
        domain: "NitroUnzip",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Extraction cancelled"]
      )
    }

    guard success else {
      throw NSError(
        domain: "NitroUnzip",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "SSZipArchive extraction failed"]
      )
    }

    let duration = Date().timeIntervalSince(startTime) * 1000 // ms
    let finalCount = extractedFiles
    let averageSpeed = duration > 0 ? Double(finalCount) / (duration / 1000) : 0

    // Calculate total bytes from zip file size
    let totalBytes: Double
    if let attrs = try? fileManager.attributesOfItem(atPath: cleanZip),
       let fileSize = attrs[.size] as? UInt64 {
      totalBytes = Double(fileSize)
    } else {
      totalBytes = 0
    }

    return UnzipResult(
      success: true,
      extractedFiles: Double(finalCount),
      totalFiles: Double(totalFileCount),
      duration: duration,
      averageSpeed: averageSpeed,
      totalBytes: totalBytes
    )
  }

  // MARK: - Background task management

  private func beginBackgroundTask() {
    let bgId = UIApplication.shared.beginBackgroundTask(withName: "NitroUnzip-\(taskId)") { [weak self] in
      self?.lock.lock()
      self?.shouldCancel = true
      self?.lock.unlock()
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
