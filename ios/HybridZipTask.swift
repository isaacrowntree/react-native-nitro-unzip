import Foundation
import NitroModules
import SSZipArchive
import UIKit

/**
 * A single zip creation operation as a proper HybridObject instance.
 *
 * Each call to `HybridUnzip.zip()` creates one of these.
 * The caller can observe progress, cancel, or await the result.
 */
class HybridZipTask: HybridZipTaskSpec {
  // MARK: - HybridObject requirements

  var hybridContext = margelo.nitro.HybridContext()
  var memorySize: Int { return getSizeOf(self) }

  // MARK: - Spec properties

  let taskId: String

  // MARK: - Internal state

  private let sourcePath: String
  private let destinationZipPath: String
  private let password: String?
  private var progressCallback: ((_ progress: ZipProgress) -> Void)?
  private var shouldCancel = false
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private let lock = NSLock()
  private let progressThrottle: TimeInterval = 1.0

  private var resolvePromise: ((ZipResult) -> Void)?
  private var rejectPromise: ((Error) -> Void)?
  private var hasStarted = false

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
    shouldCancel = true
    lock.unlock()
  }

  func await() throws -> Promise<ZipResult> {
    return Promise.async { [self] resolve, reject in
      self.lock.lock()
      self.resolvePromise = resolve
      self.rejectPromise = reject

      guard !self.hasStarted else {
        self.lock.unlock()
        return
      }
      self.hasStarted = true
      self.lock.unlock()

      self.startCompression()
    }
  }

  // MARK: - Compression

  private func startCompression() {
    beginBackgroundTask()

    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do {
        let result = try self.compress()
        self.endBackgroundTask()
        self.lock.lock()
        let resolve = self.resolvePromise
        self.lock.unlock()
        resolve?(result)
      } catch {
        self.endBackgroundTask()
        self.lock.lock()
        let reject = self.rejectPromise
        self.lock.unlock()
        reject?(error)
      }
    }
  }

  private func compress() throws -> ZipResult {
    let startTime = Date()
    let fileManager = FileManager.default

    let cleanSource = sourcePath.replacingOccurrences(of: "file://", with: "")
    let cleanDest = destinationZipPath.replacingOccurrences(of: "file://", with: "")

    guard fileManager.fileExists(atPath: cleanSource) else {
      throw NSError(
        domain: "NitroUnzip",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Source path not found: \(cleanSource)"]
      )
    }

    // Collect all files to compress for progress tracking
    var allFiles: [String] = []
    if var enumerator = fileManager.enumerator(atPath: cleanSource) {
      while let file = enumerator.nextObject() as? String {
        let fullPath = (cleanSource as NSString).appendingPathComponent(file)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
          allFiles.append(file)
        }
      }
    }

    let totalFiles = allFiles.count
    var compressedCount = 0
    var lastProgressUpdate = Date()

    // SSZipArchive createZipFile with progress
    let success: Bool
    if let password = password {
      success = SSZipArchive.createZipFile(
        atPath: cleanDest,
        withContentsOfDirectory: cleanSource,
        keepParentDirectory: false,
        withPassword: password,
        andProgressHandler: { [weak self] entryNumber, total in
          self?.handleZipProgress(
            entryNumber: entryNumber,
            total: total,
            startTime: startTime,
            compressedCount: &compressedCount,
            lastProgressUpdate: &lastProgressUpdate
          )
        }
      )
    } else {
      success = SSZipArchive.createZipFile(
        atPath: cleanDest,
        withContentsOfDirectory: cleanSource,
        keepParentDirectory: false,
        compressionLevel: -1,
        password: nil,
        aes: false,
        progressHandler: { [weak self] entryNumber, total in
          self?.handleZipProgress(
            entryNumber: entryNumber,
            total: total,
            startTime: startTime,
            compressedCount: &compressedCount,
            lastProgressUpdate: &lastProgressUpdate
          )
        }
      )
    }

    lock.lock()
    let wasCancelled = shouldCancel
    lock.unlock()

    if wasCancelled {
      // Clean up partial zip file
      try? fileManager.removeItem(atPath: cleanDest)
      throw NSError(
        domain: "NitroUnzip",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Zip creation cancelled"]
      )
    }

    guard success else {
      throw NSError(
        domain: "NitroUnzip",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "SSZipArchive zip creation failed"]
      )
    }

    let duration = Date().timeIntervalSince(startTime) * 1000
    let finalCount = totalFiles
    let averageSpeed = duration > 0 ? Double(finalCount) / (duration / 1000) : 0

    // Get output file size
    let attrs = try? fileManager.attributesOfItem(atPath: cleanDest)
    let totalBytes = (attrs?[.size] as? Double) ?? 0

    return ZipResult(
      success: true,
      compressedFiles: Double(finalCount),
      duration: duration,
      averageSpeed: averageSpeed,
      totalBytes: totalBytes
    )
  }

  private func handleZipProgress(
    entryNumber: UInt,
    total: UInt,
    startTime: Date,
    compressedCount: inout Int,
    lastProgressUpdate: inout Date
  ) {
    lock.lock()
    let cancelled = shouldCancel
    let callback = progressCallback
    lock.unlock()
    if cancelled { return }

    compressedCount = Int(entryNumber)

    let now = Date()
    let shouldUpdate = now.timeIntervalSince(lastProgressUpdate) >= progressThrottle
      || entryNumber == total
      || entryNumber == 1

    if shouldUpdate, let callback = callback {
      let progress = total > 0 ? Double(entryNumber) / Double(total) : 0
      let elapsed = now.timeIntervalSince(startTime)
      let speed = elapsed > 0 ? Double(entryNumber) / elapsed : 0

      callback(ZipProgress(
        compressedFiles: Double(entryNumber),
        totalFiles: Double(total),
        progress: progress,
        speed: speed
      ))
      lastProgressUpdate = now
    }
  }

  // MARK: - Background task management

  private func beginBackgroundTask() {
    let bgId = UIApplication.shared.beginBackgroundTask(withName: "NitroZip-\(taskId)") { [weak self] in
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
