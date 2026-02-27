import Foundation
import NitroModules

/**
 * Factory HybridObject that creates `UnzipTask` instances.
 *
 * Usage from JS:
 * ```js
 * const unzip = NitroModules.createHybridObject('Unzip')
 * const task = unzip.extract(zipPath, destPath)
 * ```
 */
class HybridUnzip: HybridUnzipSpec {
  var hybridContext = margelo.nitro.HybridContext()
  var memorySize: Int { return getSizeOf(self) }

  func extract(zipPath: String, destinationPath: String) throws -> any HybridUnzipTaskSpec {
    return HybridUnzipTask(zipPath: zipPath, destinationPath: destinationPath)
  }
}
