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
 *
 * When a password is provided, uses zip4j for decryption. Otherwise uses
 * the fast built-in ZipInputStream path (no extra dependency overhead).
 */
@DoNotStrip
@Keep
class HybridUnzipTask(
  private val zipPath: String,
  private val destinationPath: String,
  private val password: String? = null
) : HybridUnzipTaskSpec() {

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
    return Promise.async {
      try {
        if (password != null) extractWithPassword() else extract()
      } catch (e: CancellationException) {
        throw Exception("Extraction cancelled")
      }
    }
  }

  /**
   * Fast path — built-in ZipInputStream, no password support.
   */
  private suspend fun extract(): UnzipResult = withContext(Dispatchers.IO) {
    extractionJob = coroutineContext[Job]

    val startTime = System.currentTimeMillis()

    val cleanZip = zipPath.replace("file://", "")
    val cleanDest = destinationPath.replace("file://", "")

    val destDir = File(cleanDest)
    if (!destDir.exists()) {
      destDir.mkdirs()
    }
    // Canonicalize the destination once for Zip Slip validation. Any entry
    // whose resolved path doesn't start with this prefix is rejected.
    val canonicalDestDir = destDir.canonicalFile

    val sourceFile = File(cleanZip)
    if (!sourceFile.exists()) {
      throw Exception("Source ZIP file not found: $cleanZip")
    }

    // --- Pass 1: collect entries ---
    val pass1Entries = mutableListOf<EntryDescriptor>()
    val fileEntries = mutableListOf<String>()

    ZipInputStream(BufferedInputStream(sourceFile.inputStream(), BUFFER_SIZE)).use { zis ->
      var entry = zis.nextEntry
      while (entry != null) {
        // Reject malicious entries before either pass touches the filesystem.
        // Zip Slip: an entry named `../../foo` would resolve outside destDir
        // and write to arbitrary app-private paths.
        assertSafeEntryPath(canonicalDestDir, entry.name)
        pass1Entries.add(EntryDescriptor(entry.name, entry.isDirectory))
        if (!entry.isDirectory) {
          fileEntries.add(entry.name)
        }
        entry = zis.nextEntry
      }
    }

    // Batch create all directories (sorted parent-before-child).
    collectDirectoriesToCreate(pass1Entries).forEach { dirPath ->
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
          // Defence in depth: re-validate per entry in case the archive
          // shuffles between passes (shouldn't, but ZIP central directory
          // and local headers can disagree on malformed archives).
          assertSafeEntryPath(canonicalDestDir, entry.name)
          val entryFile = File(destDir, entry.name)

          BufferedOutputStream(FileOutputStream(entryFile), BUFFER_SIZE).use { output ->
            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            while (zis.read(buffer).also { bytesRead = it } != -1) {
              output.write(buffer, 0, bytesRead)
            }
          }

          extractedCount++

          // Throttle progress updates — decision lives in companion so it can
          // be exercised in unit tests without driving full extraction.
          val now = System.currentTimeMillis()
          val shouldUpdate = shouldDispatchProgress(
            now,
            lastProgressUpdate,
            extractedCount,
            totalEntries
          )

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
    val zipFileSize = sourceFile.length().toDouble()

    UnzipResult(
      success = true,
      extractedFiles = extractedCount.toDouble(),
      totalFiles = totalEntries.toDouble(),
      duration = durationMs,
      averageSpeed = avgSpeed,
      totalBytes = zipFileSize
    )
  }

  /**
   * Password-protected extraction using zip4j.
   */
  private suspend fun extractWithPassword(): UnzipResult = withContext(Dispatchers.IO) {
    extractionJob = coroutineContext[Job]

    val startTime = System.currentTimeMillis()

    val cleanZip = zipPath.replace("file://", "")
    val cleanDest = destinationPath.replace("file://", "")

    val destDir = File(cleanDest)
    if (!destDir.exists()) {
      destDir.mkdirs()
    }
    val canonicalDestDir = destDir.canonicalFile

    val sourceFile = File(cleanZip)
    if (!sourceFile.exists()) {
      throw Exception("Source ZIP file not found: $cleanZip")
    }

    val zipFile = net.lingala.zip4j.ZipFile(sourceFile)
    zipFile.setPassword(password!!.toCharArray())

    val fileHeaders = zipFile.fileHeaders
    // Zip Slip mitigation — validate every entry's resolved path before
    // delegating to zip4j. zip4j 2.10+ has its own check but defence in depth
    // is cheap, and it shields against older versions if the resolved
    // dependency tree slips.
    for (header in fileHeaders) {
      assertSafeEntryPath(canonicalDestDir, header.fileName)
    }
    val totalEntries = fileHeaders.size
    var extractedCount = 0
    var lastProgressUpdate = System.currentTimeMillis()

    for (header in fileHeaders) {
      if (!isActive || shouldCancel) break

      if (!header.isDirectory) {
        zipFile.extractFile(header, cleanDest)
        extractedCount++

        val now = System.currentTimeMillis()
        val shouldUpdate = shouldDispatchProgress(
          now,
          lastProgressUpdate,
          extractedCount,
          totalEntries
        )

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
    }

    if (shouldCancel) {
      throw CancellationException("Extraction cancelled")
    }

    val durationMs = (System.currentTimeMillis() - startTime).toDouble()
    val avgSpeed = if (durationMs > 0) extractedCount / (durationMs / 1000.0) else 0.0
    val zipFileSize = sourceFile.length().toDouble()

    UnzipResult(
      success = true,
      extractedFiles = extractedCount.toDouble(),
      totalFiles = totalEntries.toDouble(),
      duration = durationMs,
      averageSpeed = avgSpeed,
      totalBytes = zipFileSize
    )
  }

  companion object {
    private const val BUFFER_SIZE = 65536
    internal const val PROGRESS_THROTTLE_MS = 1000L

    /**
     * Zip Slip mitigation — reject any entry whose resolved canonical path
     * doesn't sit inside the destination directory. Catches the classic
     * `../../foo` payload as well as absolute paths (`/etc/passwd`) and
     * exotic separators that resolve through `..` after canonicalisation.
     *
     * Throws SecurityException with the offending entry name so callers can
     * fail loudly (and report to crash analytics) when malformed archives
     * appear in production.
     */
    internal fun assertSafeEntryPath(canonicalDestDir: File, entryName: String) {
      val resolved = File(canonicalDestDir, entryName).canonicalFile
      val destPrefix = canonicalDestDir.path + File.separator
      if (resolved.path != canonicalDestDir.path &&
          !resolved.path.startsWith(destPrefix)) {
        throw SecurityException(
          "Refusing to extract entry outside destination: $entryName (resolves to ${resolved.path})"
        )
      }
    }

    /**
     * Pure decision: should we fire a progress callback right now? Always
     * fires for the first extracted file, for the final file, and otherwise
     * at most every `throttleMs`. Pulled into the companion so a JVM unit
     * test can pin the exact behaviour without driving the full extraction.
     */
    internal fun shouldDispatchProgress(
      now: Long,
      lastUpdate: Long,
      extractedCount: Int,
      totalEntries: Int,
      throttleMs: Long = PROGRESS_THROTTLE_MS
    ): Boolean {
      if (extractedCount == 1) return true
      if (extractedCount == totalEntries) return true
      return (now - lastUpdate) >= throttleMs
    }

    /**
     * Two-pass extraction pre-collects the set of directories that need to
     * exist before file writes start. Pulled out so the algorithm can be
     * tested independently of streaming I/O.
     *
     * Returns a sorted list (parent directories before children) of unique
     * directory paths derived from the supplied entries. Pure file entries
     * contribute their parent path; pure directory entries contribute
     * themselves.
     */
    internal fun collectDirectoriesToCreate(
      entries: List<EntryDescriptor>
    ): List<String> {
      val dirs = hashSetOf<String>()
      for (entry in entries) {
        if (entry.isDirectory) {
          dirs.add(entry.name)
        } else {
          val parent = File(entry.name).parent
          if (parent != null) dirs.add(parent)
        }
      }
      return dirs.sorted()
    }

    /** Test-friendly description of a ZIP entry without depending on the JDK type. */
    internal data class EntryDescriptor(val name: String, val isDirectory: Boolean)
  }
}
