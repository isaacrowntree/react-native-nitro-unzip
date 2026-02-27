package com.margelo.nitro.unzip

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import kotlinx.coroutines.*
import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.model.ZipParameters
import net.lingala.zip4j.model.enums.AesKeyStrength
import net.lingala.zip4j.model.enums.CompressionLevel
import net.lingala.zip4j.model.enums.CompressionMethod
import net.lingala.zip4j.model.enums.EncryptionMethod
import java.io.File

/**
 * A single zip creation operation as a proper HybridObject instance.
 *
 * Uses zip4j for both standard and password-protected zip creation.
 * AES-256 encryption when password is provided.
 */
@DoNotStrip
@Keep
class HybridZipTask(
  private val sourcePath: String,
  private val destinationZipPath: String,
  private val password: String? = null
) : HybridZipTaskSpec() {

  override val memorySize: Long = 0L

  override val taskId: String = "zip_${System.nanoTime()}_${(Math.random() * 1e9).toLong()}"

  private var progressCallback: ((ZipProgress) -> Unit)? = null
  private var compressionJob: Job? = null

  @Volatile
  private var shouldCancel = false

  override fun onProgress(callback: (progress: ZipProgress) -> Unit) {
    progressCallback = callback
  }

  override fun cancel() {
    shouldCancel = true
    compressionJob?.cancel()
  }

  override fun await(): Promise<ZipResult> {
    return Promise.async { resolve, reject ->
      try {
        val result = compress()
        resolve(result)
      } catch (e: CancellationException) {
        reject(Exception("Zip creation cancelled"))
      } catch (e: Exception) {
        reject(e)
      }
    }
  }

  private suspend fun compress(): ZipResult = withContext(Dispatchers.IO) {
    compressionJob = coroutineContext[Job]

    val startTime = System.currentTimeMillis()

    val cleanSource = sourcePath.replace("file://", "")
    val cleanDest = destinationZipPath.replace("file://", "")

    val sourceDir = File(cleanSource)
    if (!sourceDir.exists()) {
      throw Exception("Source path not found: $cleanSource")
    }

    // Collect all files for progress tracking
    val allFiles = mutableListOf<File>()
    sourceDir.walkTopDown().forEach { file ->
      if (file.isFile) {
        allFiles.add(file)
      }
    }

    val totalFiles = allFiles.size
    var compressedCount = 0
    var lastProgressUpdate = System.currentTimeMillis()

    val zipFile = ZipFile(cleanDest)

    val zipParams = ZipParameters().apply {
      compressionMethod = CompressionMethod.DEFLATE
      compressionLevel = CompressionLevel.NORMAL
    }

    if (password != null) {
      zipFile.setPassword(password.toCharArray())
      zipParams.isEncryptFiles = true
      zipParams.encryptionMethod = EncryptionMethod.AES
      zipParams.aesKeyStrength = AesKeyStrength.KEY_STRENGTH_256
    }

    // Add files one by one for progress tracking
    for (file in allFiles) {
      if (!isActive || shouldCancel) break

      val relativePath = file.relativeTo(sourceDir).parent
      val params = ZipParameters(zipParams)
      if (relativePath != null) {
        params.rootFolderNameInZip = relativePath
      }

      zipFile.addFile(file, params)
      compressedCount++

      val now = System.currentTimeMillis()
      val shouldUpdate = (now - lastProgressUpdate >= PROGRESS_THROTTLE_MS)
        || (compressedCount == totalFiles)
        || (compressedCount == 1)

      if (shouldUpdate) {
        val progress = if (totalFiles > 0) compressedCount.toDouble() / totalFiles else 0.0
        val elapsed = (now - startTime) / 1000.0
        val speed = if (elapsed > 0) compressedCount / elapsed else 0.0

        progressCallback?.invoke(
          ZipProgress(
            compressedFiles = compressedCount.toDouble(),
            totalFiles = totalFiles.toDouble(),
            progress = progress,
            speed = speed
          )
        )
        lastProgressUpdate = now
      }
    }

    if (shouldCancel) {
      // Clean up partial zip file
      File(cleanDest).delete()
      throw CancellationException("Zip creation cancelled")
    }

    val durationMs = (System.currentTimeMillis() - startTime).toDouble()
    val avgSpeed = if (durationMs > 0) compressedCount / (durationMs / 1000.0) else 0.0
    val totalBytes = File(cleanDest).length().toDouble()

    ZipResult(
      success = true,
      compressedFiles = compressedCount.toDouble(),
      totalFiles = totalFiles.toDouble(),
      duration = durationMs,
      averageSpeed = avgSpeed,
      totalBytes = totalBytes
    )
  }

  companion object {
    private const val PROGRESS_THROTTLE_MS = 1000L
  }
}
