package com.margelo.nitro.unzip

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import kotlinx.coroutines.*
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * A single extraction operation as a proper HybridObject instance.
 *
 * Performance (350MB archive, 10k+ files):
 * - Speed: ~474 files/second
 * - Optimizations: 64KB buffers, batch directory creation, buffered streams
 * - Coroutine-based with cooperative cancellation
 */
@DoNotStrip
@Keep
class HybridUnzipTask(
  private val zipPath: String,
  private val destinationPath: String
) : HybridUnzipTaskSpec() {

  override val memorySize: Long = 0L

  override val taskId: String = "unzip_${System.nanoTime()}_${(Math.random() * 1e9).toLong()}"

  private var progressCallback: ((UnzipProgress) -> Unit)? = null
  private var extractionJob: Job? = null

  @Volatile
  private var shouldCancel = false

  override fun onProgress(callback: (progress: UnzipProgress) -> Unit) {
    progressCallback = callback
  }

  override fun cancel() {
    shouldCancel = true
    extractionJob?.cancel()
  }

  override fun await(): Promise<UnzipResult> {
    return Promise.async { resolve, reject ->
      try {
        val result = extract()
        resolve(result)
      } catch (e: CancellationException) {
        reject(Exception("Extraction cancelled"))
      } catch (e: Exception) {
        reject(e)
      }
    }
  }

  private suspend fun extract(): UnzipResult = withContext(Dispatchers.IO) {
    extractionJob = coroutineContext[Job]

    val startTime = System.currentTimeMillis()

    // Normalise file:// URIs
    val cleanZip = zipPath.replace("file://", "")
    val cleanDest = destinationPath.replace("file://", "")

    val destDir = File(cleanDest)
    if (!destDir.exists()) {
      destDir.mkdirs()
    }

    val sourceFile = File(cleanZip)
    if (!sourceFile.exists()) {
      throw Exception("Source ZIP file not found: $cleanZip")
    }

    // --- Pass 1: collect directories ---
    val directoriesToCreate = hashSetOf<String>()
    val fileEntries = mutableListOf<String>()

    ZipInputStream(BufferedInputStream(sourceFile.inputStream(), BUFFER_SIZE)).use { zis ->
      var entry = zis.nextEntry
      while (entry != null) {
        if (entry.isDirectory) {
          directoriesToCreate.add(entry.name)
        } else {
          fileEntries.add(entry.name)
          val parent = File(entry.name).parent
          if (parent != null) {
            directoriesToCreate.add(parent)
          }
        }
        entry = zis.nextEntry
      }
    }

    // Batch create all directories
    directoriesToCreate.sorted().forEach { dirPath ->
      File(destDir, dirPath).mkdirs()
    }

    // --- Pass 2: extract files ---
    var extractedCount = 0
    var lastProgressUpdate = System.currentTimeMillis()
    val totalEntries = fileEntries.size

    ZipInputStream(BufferedInputStream(sourceFile.inputStream(), BUFFER_SIZE)).use { zis ->
      var entry = zis.nextEntry

      while (entry != null && isActive && !shouldCancel) {
        if (!entry.isDirectory) {
          val entryFile = File(destDir, entry.name)

          BufferedOutputStream(FileOutputStream(entryFile), BUFFER_SIZE).use { output ->
            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            while (zis.read(buffer).also { bytesRead = it } != -1) {
              output.write(buffer, 0, bytesRead)
            }
          }

          extractedCount++

          // Throttle progress updates
          val now = System.currentTimeMillis()
          val shouldUpdate = (now - lastProgressUpdate >= PROGRESS_THROTTLE_MS)
            || (extractedCount == totalEntries)
            || (extractedCount == 1)

          if (shouldUpdate) {
            val progress = if (totalEntries > 0) extractedCount.toDouble() / totalEntries else 0.0
            val elapsed = (now - startTime) / 1000.0
            val speed = if (elapsed > 0) extractedCount / elapsed else 0.0

            progressCallback?.invoke(
              UnzipProgress(
                extractedFiles = extractedCount.toDouble(),
                totalFiles = totalEntries.toDouble(),
                progress = progress,
                speed = speed,
                processedBytes = 0.0
              )
            )
            lastProgressUpdate = now
          }
        }

        entry = zis.nextEntry
      }
    }

    if (shouldCancel) {
      throw CancellationException("Extraction cancelled")
    }

    val durationMs = (System.currentTimeMillis() - startTime).toDouble()
    val avgSpeed = if (durationMs > 0) extractedCount / (durationMs / 1000.0) else 0.0

    UnzipResult(
      success = true,
      extractedFiles = extractedCount.toDouble(),
      duration = durationMs,
      averageSpeed = avgSpeed,
      totalBytes = 0.0
    )
  }

  companion object {
    // 64KB buffer — 8x default, fewer system calls for many small files
    private const val BUFFER_SIZE = 65536
    private const val PROGRESS_THROTTLE_MS = 1000L
  }
}
