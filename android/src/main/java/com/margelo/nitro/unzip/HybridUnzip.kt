package com.margelo.nitro.unzip

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip

/**
 * Factory HybridObject that creates `UnzipTask` instances.
 */
@DoNotStrip
@Keep
class HybridUnzip : HybridUnzipSpec() {
  override val memorySize: Long = 0L

  override fun extract(zipPath: String, destinationPath: String): HybridUnzipTaskSpec {
    return HybridUnzipTask(zipPath, destinationPath)
  }
}
