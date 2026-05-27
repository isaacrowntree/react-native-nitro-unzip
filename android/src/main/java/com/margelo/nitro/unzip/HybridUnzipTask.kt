package com.margelo.nitro.unzip

import androidx.annotation.Keep
import androidx.annotation.VisibleForTesting
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import java.io.IOException
import java.nio.channels.Channels
import java.nio.channels.FileChannel
import java.nio.file.AccessDeniedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.InvalidPathException
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardOpenOption
import java.text.Normalizer
import java.util.Locale
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import kotlin.coroutines.coroutineContext

/**
 * A single extraction operation as a proper HybridObject instance.
 *
 * Performance:
 * - Reference: ~9000 files/sec on the perf smoke (1000 small files on dev
 *   hardware). Real-world throughput on a 350MB / 10k-entry archive on
 *   mobile flash is dominated by IO, not the unzip loop — the 0.3
 *   baseline (~474 files/sec on a streaming-decode implementation) is no
 *   longer the limiting factor.
 * - Optimizations: 64KB buffers, single-pass extraction via central
 *   directory (java.util.zip.ZipFile), NIO interruptible writes
 *   (FileChannel.open + Channels.newOutputStream), buffered streams.
 * - Coroutine-based with cooperative cancellation; mid-write cancel via
 *   `runInterruptible` translates Job.cancel() into Thread.interrupt() on
 *   the InterruptibleChannel-backed FileChannel.
 *
 * 0.4.0 migrated the fast path to [java.util.zip.ZipFile] (random-access via
 * central directory — no inflate to find headers) and [java.nio.file] (NIO
 * Path API — interruptible writes, NOFOLLOW_LINKS symlink safety, proper
 * typed exceptions, normalisation-based path validation). The password path
 * remains on zip4j for decryption but uses NIO for path validation + writes.
 *
 * Instance methods are thin shims that dispatch to Dispatchers.IO, capture
 * the coroutine Job for [cancel] to interrupt, and delegate to the pure
 * companion cores so the cores can be unit-tested without instantiating the
 * Nitro HybridObject.
 */
@DoNotStrip
@Keep
class HybridUnzipTask(
  private val zipPath: String,
  private val destinationPath: String,
  private val password: String? = null
) : HybridUnzipTaskSpec() {

  override val taskId: String = generateTaskId()

  @Volatile
  private var progressCallback: ((UnzipProgress) -> Unit)? = null

  @Volatile
  private var extractionJob: Job? = null

  @Volatile
  private var shouldCancel = false

  // Flipped to true the first time await() is called. cancel() uses this
  // rather than `extractionJob != null` to decide whether to set the cancel
  // flag, which closes the race window between await()'s lazy init and the
  // IO dispatcher actually scheduling extractCore (extractionJob is null
  // during that window). Pre-await cancel remains a true no-op.
  private val started = AtomicBoolean(false)

  override fun onProgress(callback: (progress: UnzipProgress) -> Unit) {
    progressCallback = callback
  }

  override fun cancel() {
    // No-op if extraction was never started. Setting shouldCancel before
    // any await() would poison the cached awaitPromise — the first await()
    // would launch, immediately observe shouldCancel=true, and reject,
    // leaving the task permanently dead. Documented at the JS boundary.
    if (!started.get()) return
    shouldCancel = true
    // extractionJob may still be null in the window between lazy init and
    // the IO dispatcher entering extract() — shouldCancel covers that
    // window (extractCore's first checkNotCancelled catches it).
    extractionJob?.cancel()
  }

  override fun await(): Promise<UnzipResult> {
    started.set(true)
    return awaitPromise
  }

  // `by lazy` so a second await() returns the same in-flight Promise rather
  // than launching a second extraction that would race writes against the
  // first and clobber [extractionJob]. Kotlin's lazy is synchronized by
  // default — safe to call from any thread.
  private val awaitPromise: Promise<UnzipResult> by lazy {
    Promise.async {
      try {
        if (password != null) extractWithPassword() else extract()
      } catch (e: CancellationException) {
        // Preserve the original CancellationException as `cause` so a parent
        // scope can still introspect structured cancellation; the wrapping
        // Exception keeps the user-facing message stable for JS consumers.
        throw Exception(CANCELLED_MESSAGE, e)
      }
    }
  }

  /**
   * Fast path — built-in [ZipFile], no password support. Dispatches to IO,
   * captures the job for [cancel] to interrupt, then delegates to the pure
   * [extractCore] companion. progressCallback is wrapped in a closure so a
   * late onProgress() registration is observed on the next throttle tick
   * (the @Volatile field is re-read on each invocation).
   */
  private suspend fun extract(): UnzipResult = withContext(Dispatchers.IO) {
    extractionJob = coroutineContext[Job]
    extractCore(
      zipPath = zipPath,
      destinationPath = destinationPath,
      isCancelledProvider = { shouldCancel },
      progressCallback = { p -> progressCallback?.invoke(p) }
    )
  }

  private suspend fun extractWithPassword(): UnzipResult = withContext(Dispatchers.IO) {
    extractionJob = coroutineContext[Job]
    extractWithPasswordCore(
      zipPath = zipPath,
      destinationPath = destinationPath,
      password = password!!,
      isCancelledProvider = { shouldCancel },
      progressCallback = { p -> progressCallback?.invoke(p) }
    )
  }

  companion object {
    private const val BUFFER_SIZE = 65536
    internal const val PROGRESS_THROTTLE_MS = 1000L

    // Single source of truth for the cancellation message — every throw site
    // and the wrapping Exception in await() reference this so a future edit
    // (entry context, localisation) lands once. Kept `internal` so tests can
    // compare against it via equality rather than substring matching.
    internal const val CANCELLED_MESSAGE = "Extraction cancelled"

    // Entry-name hard cap. Catches DoS via 4090-char nested paths that would
    // throw raw ENAMETOOLONG IOException from the kernel.
    private const val MAX_ENTRY_NAME_LENGTH = 1024

    private fun cancelled() = CancellationException(CANCELLED_MESSAGE)

    /**
     * Cooperative cancellation check. `ensureActive()` rethrows the parent
     * Job's own CancellationException (preserving its cancellation cause).
     * The flag-based path catches user calls to HybridUnzipTask.cancel()
     * that happen while we're inside non-suspending work.
     */
    private suspend inline fun checkNotCancelled(isCancelledProvider: () -> Boolean) {
      coroutineContext.ensureActive()
      if (isCancelledProvider()) throw cancelled()
    }

    /**
     * Generate a per-instance task ID. nanoTime + a 64-bit lock-free random
     * suffix (ThreadLocalRandom is per-thread, no shared lock unlike the
     * Math.random() global Random). Format is opaque — consumers should
     * treat it as a unique-but-arbitrary identifier and not parse it.
     */
    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    internal fun generateTaskId(): String =
      "unzip_${System.nanoTime()}_${ThreadLocalRandom.current().nextLong()}"

    // ─── Shared scaffolding for the two extract cores ─────────────────────

    private class ExtractionContext(
      val destDir: Path,
      val sourceFile: Path,
      val sourceSize: Long,
      val startTime: Long
    )

    private suspend fun prepareExtraction(
      zipPath: String,
      destinationPath: String,
      clock: () -> Long,
      isCancelledProvider: () -> Boolean = { false }
    ): ExtractionContext {
      val startTime = clock()
      // Honour cancellation upfront — without this, a cancel() landing
      // before the first per-entry checkNotCancelled would still pay for
      // all the prepareExtraction I/O below (createDirectories + toRealPath
      // + Files.size) on slow storage.
      checkNotCancelled(isCancelledProvider)
      // Content URIs aren't filesystem paths — Paths.get throws
      // InvalidPathException on the `:` in `content://`. Catch upfront with
      // a clear error pointing the caller at the supported input form.
      requireFilesystemPath(destinationPath, "destinationPath")
      requireFilesystemPath(zipPath, "zipPath")

      val cleanDest = destinationPath.removePrefix("file://")
      val cleanZip = zipPath.removePrefix("file://")
      if (cleanDest.isEmpty()) {
        throw IllegalArgumentException("destinationPath must not be empty")
      }
      if (cleanZip.isEmpty()) {
        throw IllegalArgumentException("zipPath must not be empty")
      }

      val destDir = Paths.get(cleanDest)
      val sourceFile = Paths.get(cleanZip)

      // Files.createDirectories is a no-op when the path already exists as a
      // directory, throws FileAlreadyExistsException when a regular file
      // occupies the path, AccessDeniedException for permission failures.
      // Cleaner semantics than File.mkdirs()'s silent-false-return.
      // We deliberately skip Files.isWritable: it's unreliable on Android
      // (SELinux, scoped storage, FUSE wrappers all confound it) and only
      // adds a TOCTOU window before the actual writes surface their own
      // errors with better context.
      try {
        Files.createDirectories(destDir)
      } catch (e: FileAlreadyExistsException) {
        throw IOException("Destination path is not a directory: $destDir", e)
      } catch (e: AccessDeniedException) {
        throw IOException("Could not create destination directory: $destDir", e)
      }

      // Resolve symlinks in the destination root once. Per-entry checks
      // (assertSafeEntryPath + the post-mkdir parent-toRealPath assertion in
      // the cores) then have a single canonical reference to compare against.
      val realDestDir = destDir.toRealPath()

      // Cache the source file size here so the post-extraction buildResult
      // doesn't have to stat() the file again — if the source is deleted
      // mid-extraction, the successful UnzipResult is preserved.
      val sourceSize = try {
        Files.size(sourceFile)
      } catch (e: NoSuchFileException) {
        throw NoSuchFileException(sourceFile.toString())
      }
      return ExtractionContext(realDestDir, sourceFile, sourceSize, startTime)
    }

    private fun requireFilesystemPath(path: String, paramName: String) {
      // Reject schemes that aren't `file://` (the only one we strip). Most
      // commonly: Android SAF returns content:// URIs from document pickers
      // — these aren't filesystem paths and Paths.get would throw an
      // opaque InvalidPathException on the `:`.
      val schemeEnd = path.indexOf("://")
      if (schemeEnd > 0 && path.substring(0, schemeEnd) != "file") {
        throw IllegalArgumentException(
          "$paramName must be a filesystem path or file:// URI " +
            "(got `${path.substring(0, schemeEnd)}://...`). " +
            "Resolve content:// URIs to filesystem paths before passing them in."
        )
      }
    }

    /**
     * Throttled progress emission. Returns the new `lastUpdate` timestamp —
     * the caller threads it through subsequent iterations.
     */
    private fun emitProgressIfDue(
      now: Long,
      startTime: Long,
      lastUpdate: Long,
      extractedCount: Int,
      totalEntries: Int,
      throttleMs: Long,
      callback: ((UnzipProgress) -> Unit)?
    ): Long {
      if (!shouldDispatchProgress(now, lastUpdate, extractedCount, totalEntries, throttleMs)) {
        return lastUpdate
      }
      val progress = if (totalEntries > 0) extractedCount.toDouble() / totalEntries else 0.0
      val elapsed = (now - startTime) / 1000.0
      val speed = if (elapsed > 0) extractedCount / elapsed else 0.0
      callback?.invoke(
        UnzipProgress(
          extractedFiles = extractedCount.toDouble(),
          totalFiles = totalEntries.toDouble(),
          progress = progress,
          speed = speed,
          processedBytes = 0.0
        )
      )
      return now
    }

    private fun buildResult(
      extractedCount: Int,
      totalEntries: Int,
      startTime: Long,
      sourceSize: Long,
      clock: () -> Long
    ): UnzipResult {
      val durationMs = (clock() - startTime).toDouble()
      val avgSpeed = if (durationMs > 0) extractedCount / (durationMs / 1000.0) else 0.0
      // Note: totalBytes reports the COMPRESSED source ZIP size (captured in
      // prepareExtraction), not the sum of extracted bytes. JS consumers
      // measuring throughput should be aware. Using the cached size means a
      // source file deleted mid-extraction doesn't fail the result.
      return UnzipResult(
        success = true,
        extractedFiles = extractedCount.toDouble(),
        totalFiles = totalEntries.toDouble(),
        duration = durationMs,
        averageSpeed = avgSpeed,
        totalBytes = sourceSize.toDouble()
      )
    }

    /**
     * Normalise an entry name for case-insensitive / Unicode-normalising
     * duplicate detection. Uses NFC + Locale.ROOT lowercase so that:
     *   - `café.txt` (NFC) and `café.txt` (NFD) collapse to the same key
     *     (matters on APFS and HFS+ which normalise on-disk)
     *   - `Config.json` and `config.json` collapse on case-insensitive
     *     volumes (FAT32, exFAT, HFS+, APFS-CI) — and `Locale.ROOT` avoids
     *     the Turkish dotless-i bug (`"I".lowercase()` would return `"ı"`
     *     under tr_TR / az_AZ, silently bypassing the check).
     */
    private fun normalizeForDedup(name: String): String =
      Normalizer.normalize(name, Normalizer.Form.NFC).lowercase(Locale.ROOT)

    /**
     * mkdir + symlink-injection-TOCTOU defence.
     *
     * NIO's `Files.createDirectories` has no NOFOLLOW option — and even
     * `FileChannel.open`'s NOFOLLOW only protects the FINAL path component.
     * A pre-existing symlink at any intermediate component lets the kernel
     * follow it during mkdir, both escaping destDir AND creating a
     * directory at the symlink's external target as a side effect (a small
     * filesystem-pollution primitive even when the extraction then aborts).
     *
     * Defence: walk the target's ancestry from destDir downward and refuse
     * if any existing ancestor is a symlink. `verifiedAncestors` caches
     * already-checked paths so deep archives with shared prefixes (every
     * file under `a/b/c/d/...`) don't re-stat the same ancestors on every
     * entry. As a backstop the post-mkdir `toRealPath` check still fires
     * in case the FS races us.
     *
     * `createdDirs` is optional: when extracting an explicit directory
     * entry we add the target itself; when creating a parent for a file
     * entry, the caller adds the parent to its own set AFTER this call
     * succeeds (so a thrown SecurityException doesn't poison the set).
     */
    private fun createDirectoryAndVerify(
      target: Path,
      destDir: Path,
      verifiedAncestors: HashSet<Path>,
      createdDirs: HashSet<Path>?
    ) {
      // Walk from target back toward destDir. For each existing ancestor,
      // refuse if it's a symlink — `Files.createDirectories` would follow
      // it. Stop at destDir itself or at any path already verified clean.
      var cur: Path? = target
      while (cur != null && cur != destDir && cur !in verifiedAncestors) {
        if (Files.exists(cur, LinkOption.NOFOLLOW_LINKS) && Files.isSymbolicLink(cur)) {
          throw SecurityException(
            "Refusing to extract: $cur is a symlink in the destination ancestry"
          )
        }
        verifiedAncestors.add(cur)
        cur = cur.parent
      }
      Files.createDirectories(target)
      // Post-mkdir backstop: even if no ancestor was a symlink at the
      // pre-check, a concurrent process could have created one in the
      // race window. toRealPath resolves any symlinks created since.
      val realTarget = target.toRealPath()
      if (!realTarget.startsWith(destDir)) {
        throw SecurityException(
          "Refusing to extract: directory $target resolves outside destination via symlink ($realTarget)"
        )
      }
      createdDirs?.add(target)
    }

    /**
     * Write an extracted entry to `target` from the supplied InputStream.
     *
     * Uses FileChannel.open with NOFOLLOW_LINKS rather than
     * Files.newOutputStream — the latter's NOFOLLOW handling is unreliable
     * on libcore's UnixFileSystemProvider (silently ignored for the
     * CREATE+TRUNCATE_EXISTING combination on some Android API levels),
     * while FileChannel.open's contract honours it. The result is wrapped
     * via Channels.newOutputStream so the per-chunk write loop is unchanged.
     *
     * The whole write is wrapped in runInterruptible so coroutine cancellation
     * actually fires Thread.interrupt() — InterruptibleChannel-backed FileChannel
     * then unsticks the in-flight syscall on slow storage. The mid-chunk
     * checkNotCancelled gate stays as a backstop for the read side (zip4j's
     * InflaterInputStream is NOT InterruptibleChannel-backed).
     */
    private suspend inline fun writeEntry(
      target: Path,
      input: java.io.InputStream,
      buffer: ByteArray,
      crossinline isCancelledProvider: () -> Boolean
    ) {
      runInterruptible(Dispatchers.IO) {
        try {
          FileChannel.open(
            target,
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING,
            StandardOpenOption.WRITE,
            LinkOption.NOFOLLOW_LINKS
          ).use { channel ->
            Channels.newOutputStream(channel).use { output ->
              var bytesRead: Int
              while (input.read(buffer).also { bytesRead = it } != -1) {
                // Read-side cancel gate (InflaterInputStream isn't
                // interruptible). Cost: two volatile reads per 64KB chunk.
                if (isCancelledProvider()) throw cancelled()
                output.write(buffer, 0, bytesRead)
              }
            }
          }
        } catch (e: java.nio.channels.ClosedByInterruptException) {
          // runInterruptible translates plain InterruptedException →
          // CancellationException, but NOT ClosedByInterruptException
          // (which is what InterruptibleChannel actually throws when
          // Thread.interrupt() lands during a syscall). Translate here so
          // a Job-cancel-mid-write surfaces as a proper cancellation
          // rather than leaking the NIO error to the JS bridge. We also
          // consume the still-set interrupt flag so any defensive cleanup
          // added later in the runInterruptible block (e.g. partial-file
          // deletion) doesn't immediately throw a stale interrupt.
          Thread.interrupted()
          throw CancellationException(CANCELLED_MESSAGE).apply { initCause(e) }
        }
      }
    }

    // ─── Cores ────────────────────────────────────────────────────────────

    /**
     * Core fast-path extraction, no Nitro dependency. Accepts an injectable
     * [clock] and [isCancelledProvider] so JVM unit tests can drive throttle
     * cadence and cancellation deterministically. `isActive` from the calling
     * coroutine is still honoured via [checkNotCancelled].
     *
     * Uses [java.util.zip.ZipFile] for random-access central-directory reads
     * — one open of the source file (no TOCTOU between passes), no inflate
     * just to enumerate headers, and a single-pass validate-then-extract
     * design.
     */
    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    internal suspend fun extractCore(
      zipPath: String,
      destinationPath: String,
      isCancelledProvider: () -> Boolean = { false },
      clock: () -> Long = { System.currentTimeMillis() },
      progressCallback: ((UnzipProgress) -> Unit)? = null,
      throttleMs: Long = PROGRESS_THROTTLE_MS
    ): UnzipResult = coroutineScope {
      val ctx = prepareExtraction(zipPath, destinationPath, clock, isCancelledProvider)

      // Bare JDK messages from ZipFile (e.g. "error in opening zip file",
      // or a ZipException from .entries() on a corrupt central directory)
      // have no path context. Wrap the whole try/use so the JS caller can
      // correlate the failure with the source path; CancellationException
      // is re-thrown so structured cancellation isn't swallowed.
      val zipFile = try {
        ZipFile(ctx.sourceFile.toFile())
      } catch (e: CancellationException) {
        throw e
      } catch (e: IOException) {
        throw IOException("Could not open ZIP file: ${ctx.sourceFile}", e)
      }
      zipFile.use {
        // ZipFile reads the central directory on construction — entries is
        // O(1) per-entry cost versus ZipInputStream which has to inflate
        // each entry to find the next header. Single open of the source =
        // no TOCTOU between validation and extraction.
        val entries = zipFile.entries().asSequence().toList()
        val totalEntries = entries.count { !it.isDirectory }

        // Pre-validation pass: reject the whole archive if ANY entry fails
        // path validation. Without this, a malicious entry mid-archive would
        // leave partial state on disk (earlier benign entries already
        // extracted before the SecurityException fires). Resolved Paths are
        // cached so the extraction pass doesn't redo Path math.
        val validated = ArrayList<Pair<ZipEntry, Path>>(entries.size)
        val seenNormalised = HashSet<String>(entries.size)
        for (entry in entries) {
          checkNotCancelled(isCancelledProvider)
          // Duplicate-collision detection on case-insensitive (FAT32,
          // HFS+, APFS-CI) AND Unicode-normalising (APFS, HFS+) volumes.
          // normalizeForDedup uses Locale.ROOT (Turkish dotless-i bug)
          // and NFC normalisation (catches NFD vs NFC collisions).
          if (!seenNormalised.add(normalizeForDedup(entry.name))) {
            throw SecurityException(
              "Refusing to extract duplicate entry (case-insensitive collision): ${entry.name}"
            )
          }
          validated.add(entry to assertSafeEntryPath(ctx.destDir, entry.name))
        }

        // Extraction pass.
        val createdDirs = HashSet<Path>()
        val verifiedAncestors = HashSet<Path>()
        var extractedCount = 0
        var lastProgressUpdate = ctx.startTime
        val buffer = ByteArray(BUFFER_SIZE)

        for ((entry, target) in validated) {
          checkNotCancelled(isCancelledProvider)

          if (entry.isDirectory) {
            createDirectoryAndVerify(target, ctx.destDir, verifiedAncestors, createdDirs)
            continue
          }

          // Lazy mkdir of parent directories. Add to createdDirs only AFTER
          // createDirectoryAndVerify succeeds — a thrown SecurityException
          // would otherwise leave the set claiming the parent is safe.
          val parent = target.parent
          if (parent != null && parent !in createdDirs) {
            createDirectoryAndVerify(parent, ctx.destDir, verifiedAncestors, null)
            createdDirs.add(parent)
          }

          zipFile.getInputStream(entry).use { input ->
            writeEntry(target, input, buffer, isCancelledProvider)
          }
          extractedCount++
          lastProgressUpdate = emitProgressIfDue(
            clock(), ctx.startTime, lastProgressUpdate,
            extractedCount, totalEntries, throttleMs, progressCallback
          )
        }

        buildResult(extractedCount, totalEntries, ctx.startTime, ctx.sourceSize, clock)
      }
    }

    /**
     * Core password extraction, no Nitro dependency. Same single-pass shape
     * as [extractCore] but uses zip4j for AES decryption (no equivalent in
     * the JDK). Writes go through NIO FileChannel for symlink-NOFOLLOW and
     * interruptible cancellation; the read side is zip4j-managed.
     */
    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    internal suspend fun extractWithPasswordCore(
      zipPath: String,
      destinationPath: String,
      password: String,
      isCancelledProvider: () -> Boolean = { false },
      clock: () -> Long = { System.currentTimeMillis() },
      progressCallback: ((UnzipProgress) -> Unit)? = null,
      throttleMs: Long = PROGRESS_THROTTLE_MS
    ): UnzipResult = coroutineScope {
      val ctx = prepareExtraction(zipPath, destinationPath, clock, isCancelledProvider)

      // zip4j's ZipFile constructor is lazy — the file isn't opened until
      // setPassword/fileHeaders touches it. Wrap the whole initialisation
      // sequence so real IO errors (missing file, bad header, wrong
      // password during fileHeaders) get path-contextual messages.
      // CancellationException is rethrown explicitly so structured
      // cancellation isn't swallowed by the broad catch.
      net.lingala.zip4j.ZipFile(ctx.sourceFile.toFile()).use { zipFile ->
        val fileHeaders = try {
          zipFile.setPassword(password.toCharArray())
          zipFile.fileHeaders.toList()
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          throw IOException("Could not open password ZIP file: ${ctx.sourceFile}", e)
        }
        val totalEntries = fileHeaders.count { !it.isDirectory }

        // Pre-validation pass — same rationale as extractCore: reject the
        // whole archive on any malicious entry rather than leaving partial
        // state on disk.
        val validated = ArrayList<Pair<net.lingala.zip4j.model.FileHeader, Path>>(fileHeaders.size)
        val seenNormalised = HashSet<String>(fileHeaders.size)
        for (header in fileHeaders) {
          checkNotCancelled(isCancelledProvider)
          if (!seenNormalised.add(normalizeForDedup(header.fileName))) {
            throw SecurityException(
              "Refusing to extract duplicate entry (case-insensitive collision): ${header.fileName}"
            )
          }
          validated.add(header to assertSafeEntryPath(ctx.destDir, header.fileName))
        }

        val createdDirs = HashSet<Path>()
        val verifiedAncestors = HashSet<Path>()
        var extractedCount = 0
        var lastProgressUpdate = ctx.startTime
        val buffer = ByteArray(BUFFER_SIZE)

        for ((header, target) in validated) {
          checkNotCancelled(isCancelledProvider)

          if (header.isDirectory) {
            createDirectoryAndVerify(target, ctx.destDir, verifiedAncestors, createdDirs)
            continue
          }
          // Add to createdDirs only AFTER createDirectoryAndVerify succeeds.
          val parent = target.parent
          if (parent != null && parent !in createdDirs) {
            createDirectoryAndVerify(parent, ctx.destDir, verifiedAncestors, null)
            createdDirs.add(parent)
          }

          // zip4j's getInputStream returns a decrypting InputStream; we pipe
          // through writeEntry for NIO/NOFOLLOW_LINKS write semantics.
          // (Note: assertSafeEntryPath is the sole path-safety check for this
          // path — we bypass zip4j's extractFile-time validation by routing
          // through getInputStream. Don't remove assertSafeEntryPath.)
          zipFile.getInputStream(header).use { input ->
            writeEntry(target, input, buffer, isCancelledProvider)
          }
          extractedCount++
          lastProgressUpdate = emitProgressIfDue(
            clock(), ctx.startTime, lastProgressUpdate,
            extractedCount, totalEntries, throttleMs, progressCallback
          )
        }

        buildResult(extractedCount, totalEntries, ctx.startTime, ctx.sourceSize, clock)
      }
    }

    /**
     * Zip Slip mitigation, NIO edition. Uses [Path.resolve] +
     * [Path.normalize] + [Path.startsWith] which collectively handle:
     *   - Absolute paths (POSIX `/foo`) — resolve replaces destDir entirely,
     *     normalize keeps the absolute, startsWith(destDir) fails
     *   - Traversal (`../foo`, `foo/../../bar`) — normalize collapses `..`
     *     segments before the startsWith check
     *   - Entries that resolve to destDir itself (`.`, `foo/..`) — caught
     *     by the explicit equality check
     *   - NUL bytes — Path's getPath rejects them at resolve time
     *
     * Explicit additional checks catch what Path doesn't:
     *   - Empty entry names (resolve to destDir without error)
     *   - Backslash entries (treated as filename chars on POSIX; reject
     *     since ZIP spec mandates `/` and backslash entries would otherwise
     *     create literal-name files at dest root)
     *   - BiDi-override and C0 control chars (filename spoofing + log
     *     injection vectors)
     *   - Length cap (DoS prevention before kernel-level ENAMETOOLONG)
     *
     * Returns the resolved [Path] so the caller doesn't have to re-resolve
     * for the write (saves one Path allocation per entry on the hot loop).
     */
    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    internal fun assertSafeEntryPath(destDir: Path, entryName: String): Path {
      if (entryName.isEmpty()) {
        throw SecurityException("Refusing to extract empty entry name")
      }
      if (entryName.length > MAX_ENTRY_NAME_LENGTH) {
        throw SecurityException(
          "Refusing to extract entry with name longer than $MAX_ENTRY_NAME_LENGTH chars"
        )
      }
      if (entryName.contains('\\')) {
        // ZIP spec mandates `/`; backslash entries are out-of-spec and would
        // otherwise create literal-name files since POSIX treats `\` as a
        // filename char. Also blocks `\..\` traversal patterns that would
        // bypass POSIX path normalisation.
        throw SecurityException(
          "Refusing to extract entry containing backslash: $entryName"
        )
      }
      for (c in entryName) {
        if (isUnsafeChar(c)) {
          throw SecurityException(
            "Refusing to extract entry containing control or BiDi-override character: $entryName"
          )
        }
      }
      val resolved = try {
        destDir.resolve(entryName).normalize()
      } catch (e: InvalidPathException) {
        // Path's getPath rejects names containing NUL bytes and other
        // platform-illegal characters with InvalidPathException.
        throw SecurityException("Refusing to extract entry with invalid path: $entryName", e)
      }
      if (resolved == destDir) {
        throw SecurityException("Refusing to extract entry that resolves to destination root: $entryName")
      }
      if (!resolved.startsWith(destDir)) {
        throw SecurityException(
          "Refusing to extract entry outside destination: $entryName (resolves to $resolved)"
        )
      }
      return resolved
    }

    /**
     * Reject characters that are dangerous in filenames beyond what Path
     * already catches:
     *   - C0 controls (U+0000..U+001F) — terminal escape injection, log
     *     injection. Path rejects U+0000 but not the rest.
     *   - DEL (U+007F)
     *   - BiDi-override (U+202A..U+202E, U+2066..U+2069) — enable filename
     *     spoofing where `safe.txt` displays as `safe.exe` reversed
     */
    private fun isUnsafeChar(c: Char): Boolean {
      return c < ' ' || c == '\u007f' ||
        c == '\u200e' || c == '\u200f' || c == '\u061c' ||
        c in '\u202a'..'\u202e' || c in '\u2066'..'\u2069'
    }

    /**
     * Pure decision: should we fire a progress callback right now? Always
     * fires for the first extracted file, for the final file, and otherwise
     * at most every `throttleMs`. Exposed for unit tests so the rule can be
     * pinned without driving the full extraction.
     */
    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
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
  }
}
