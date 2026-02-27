import Foundation
import NitroModules

/**
 * Factory HybridObject that creates extraction and compression tasks.
 *
 * Usage from JS:
 * ```js
 * const unzip = NitroModules.createHybridObject('Unzip')
 * const task = unzip.extract(zipPath, destPath)
 * const zipTask = unzip.zip(sourcePath, destZipPath)
 * ```
 */
class HybridUnzip: HybridUnzipSpec {

  func extract(zipPath: String, destinationPath: String) throws -> any HybridUnzipTaskSpec {
    return HybridUnzipTask(zipPath: zipPath, destinationPath: destinationPath)
  }

  func extractWithPassword(zipPath: String, destinationPath: String, password: String) throws -> any HybridUnzipTaskSpec {
    return HybridUnzipTask(zipPath: zipPath, destinationPath: destinationPath, password: password)
  }

  func zip(sourcePath: String, destinationZipPath: String) throws -> any HybridZipTaskSpec {
    return HybridZipTask(sourcePath: sourcePath, destinationZipPath: destinationZipPath)
  }

  func zipWithPassword(sourcePath: String, destinationZipPath: String, password: String) throws -> any HybridZipTaskSpec {
    return HybridZipTask(sourcePath: sourcePath, destinationZipPath: destinationZipPath, password: password)
  }
}
