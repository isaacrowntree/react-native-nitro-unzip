package com.margelo.nitro.unzip

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip

/**
 * Factory HybridObject that creates extraction and compression tasks.
 */
@DoNotStrip
@Keep
class HybridUnzip : HybridUnzipSpec() {
  override fun extract(zipPath: String, destinationPath: String): HybridUnzipTaskSpec {
    return HybridUnzipTask(zipPath, destinationPath)
  }

  override fun extractWithPassword(zipPath: String, destinationPath: String, password: String): HybridUnzipTaskSpec {
    return HybridUnzipTask(zipPath, destinationPath, password)
  }

  override fun zip(sourcePath: String, destinationZipPath: String): HybridZipTaskSpec {
    return HybridZipTask(sourcePath, destinationZipPath)
  }

  override fun zipWithPassword(sourcePath: String, destinationZipPath: String, password: String): HybridZipTaskSpec {
    return HybridZipTask(sourcePath, destinationZipPath, password)
  }
}
