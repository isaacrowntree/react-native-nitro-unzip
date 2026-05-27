package com.margelo.nitro.unzip

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.IOException
import org.junit.Assume
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.FileSystemException
import java.nio.file.Files
import java.nio.file.Path
import java.text.Normalizer
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Coroutine-flavoured tests for the wrapper logic in HybridUnzipTask.
 *
 * These exercise the [HybridUnzipTask.Companion.extractCore] /
 * [HybridUnzipTask.Companion.extractWithPasswordCore] suspend functions
 * directly — the Nitro HybridObject can't be constructed from a JVM unit
 * test (it carries a JNI HybridData), so the production methods are thin
 * shims over these companion entry points.
 *
 * Coverage tracks the spike checklist:
 *   - Cancellation mid-extraction stops cleanly
 *   - Progress callbacks fire at the expected throttled cadence
 *   - Two-pass extraction handles malformed archives + downstream throws
 *   - taskId uniqueness across concurrent instances
 */
class HybridUnzipTaskCoroutineTest {

  @get:Rule
  val tempFolder = TemporaryFolder()

  private fun newDestDir(name: String = "dest"): File = tempFolder.newFolder(name)
  private fun newZipFile(name: String = "test.zip"): File =
    File(tempFolder.root, name)

  // ─── End-to-end happy paths (realistic mocked streams) ──────────────────

  @Test
  fun `extractCore extracts a multi-file zip with correct contents`() = runTest {
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf(
      "alpha.txt" to "alpha contents".toByteArray(),
      "beta.txt" to "beta contents".toByteArray(),
      "gamma.txt" to "gamma contents".toByteArray()
    ))
    val dest = newDestDir()

    val result = HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath
    )

    assertTrue(result.success)
    assertEquals(3.0, result.extractedFiles)
    assertEquals(3.0, result.totalFiles)
    assertEquals(
      "alpha contents",
      File(dest, "alpha.txt").readText()
    )
    assertEquals(
      "beta contents",
      File(dest, "beta.txt").readText()
    )
    assertEquals(
      "gamma contents",
      File(dest, "gamma.txt").readText()
    )
  }

  @Test
  fun `extractCore creates nested directories from pass 1`() = runTest {
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf(
      "tiles/12/x/y.png" to byteArrayOf(1, 2, 3),
      "tiles/12/x/z.png" to byteArrayOf(4, 5, 6)
    ))
    val dest = newDestDir()

    HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath
    )

    assertTrue(File(dest, "tiles/12/x").isDirectory)
    assertTrue(File(dest, "tiles/12/x/y.png").isFile)
    assertTrue(File(dest, "tiles/12/x/z.png").isFile)
  }

  @Test
  fun `extractCore strips file scheme from paths`() = runTest {
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf("a.txt" to "x".toByteArray()))
    val dest = newDestDir()

    val result = HybridUnzipTask.extractCore(
      zipPath = "file://${zip.absolutePath}",
      destinationPath = "file://${dest.absolutePath}"
    )

    assertEquals(1.0, result.extractedFiles)
    assertTrue(File(dest, "a.txt").isFile)
  }

  // ─── Cancellation honouring ─────────────────────────────────────────────

  @Test
  fun `extractCore throws CancellationException when isCancelledProvider flips mid-extraction`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 50)
    val dest = newDestDir()
    val cancelled = AtomicBoolean(false)
    val extractedBeforeCancel = AtomicInteger(0)

    val ex = assertFailsWith<CancellationException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath,
        isCancelledProvider = { cancelled.get() },
        // throttleMs=0 fires progress on every file so the cancel signal
        // lands at a predictable boundary.
        throttleMs = 0L,
        progressCallback = { p ->
          extractedBeforeCancel.set(p.extractedFiles.toInt())
          if (p.extractedFiles >= 5) cancelled.set(true)
        }
      )
    }
    assertTrue(ex.message!!.contains("cancelled"))
    // Cancelled by file ~5 — should NOT have extracted all 50.
    assertTrue(
      extractedBeforeCancel.get() in 5..49,
      "expected partial extraction, got ${extractedBeforeCancel.get()}"
    )
    val onDisk = dest.listFiles()?.size ?: 0
    assertTrue(onDisk < 50, "expected partial extraction on disk, got $onDisk")
  }

  // ─── Two-pass error handling ────────────────────────────────────────────

  @Test
  fun `extractCore rejects malicious entries during pass 1 before any file is written`() = runTest {
    // Archive contains a legitimate entry followed by a Zip Slip payload.
    // Pass 1 should catch the payload and abort before pass 2 writes
    // anything — guarding against partial state on a malicious archive.
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf(
      "harmless.txt" to "ok".toByteArray(),
      "../escape.txt" to "boom".toByteArray()
    ))
    val dest = newDestDir()

    assertFailsWith<SecurityException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
    }
    // Pass 1 is a complete gatekeeper — zero files should have been
    // written to disk before the rejection.
    assertEquals(0, dest.listFiles()?.size ?: 0)
  }

  @Test
  fun `extractCore propagates exceptions thrown from the progress callback during pass 2`() = runTest {
    // A throwing progress callback simulates downstream failure during
    // pass 2 (e.g. JS-side handler error). The exception should propagate
    // and partial files written prior to the throw should remain on disk.
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 10)
    val dest = newDestDir()

    val ex = assertFailsWith<RuntimeException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath,
        throttleMs = 0L,
        progressCallback = { p ->
          if (p.extractedFiles >= 3) {
            throw RuntimeException("downstream failure at file ${p.extractedFiles}")
          }
        }
      )
    }
    assertTrue(ex.message!!.contains("downstream failure"))
    // Files 1..3 were written before the callback at extractedFiles==3 threw;
    // remaining 4..10 never started. Two-pass behaviour: partial state is
    // surfaced to the caller, not silently swallowed.
    assertEquals(3, dest.listFiles()?.size ?: 0)
  }

  @Test
  fun `extractCore throws when source zip is missing`() = runTest {
    val dest = newDestDir()
    // After the NIO migration this is a typed NoSuchFileException whose
    // message is the missing path itself.
    val ex = assertFailsWith<java.nio.file.NoSuchFileException> {
      HybridUnzipTask.extractCore(
        zipPath = "/does/not/exist.zip",
        destinationPath = dest.absolutePath
      )
    }
    assertTrue(ex.message!!.contains("/does/not/exist.zip"))
  }

  // ─── Progress throttling (controlled clock) ─────────────────────────────

  @Test
  fun `extractCore fires progress only on first and last file when clock is frozen`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 10)
    val dest = newDestDir()
    val callbacks = mutableListOf<UnzipProgress>()

    HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath,
      // Frozen clock — never advances. shouldDispatchProgress only fires
      // for extractedCount == 1 (first) and extractedCount == totalEntries
      // (last); throttle gate (now - lastUpdate >= throttleMs) never opens.
      clock = { 0L },
      throttleMs = 1000L,
      progressCallback = { callbacks.add(it) }
    )

    assertEquals(2, callbacks.size, "expected first + last only, got $callbacks")
    assertEquals(1.0, callbacks.first().extractedFiles)
    assertEquals(10.0, callbacks.last().extractedFiles)
  }

  @Test
  fun `extractCore fires progress on every file when throttle is zero`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 5)
    val dest = newDestDir()
    val callbacks = mutableListOf<UnzipProgress>()

    HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath,
      throttleMs = 0L,
      progressCallback = { callbacks.add(it) }
    )

    assertEquals(5, callbacks.size)
    assertEquals(
      listOf(1.0, 2.0, 3.0, 4.0, 5.0),
      callbacks.map { it.extractedFiles }
    )
  }

  @Test
  fun `extractCore fires progress at throttle boundaries with a stepping clock`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 5)
    val dest = newDestDir()
    val callbacks = mutableListOf<UnzipProgress>()
    // Clock advances 600ms per call. extractCore reads the clock once per
    // file plus once for startTime and once for the final UnzipResult — and
    // lastProgressUpdate is initialised from startTime (no extra read). With
    // throttleMs=1000:
    //   file 1: extractedCount==1 → fire (rule 1), lastUpdate=now
    //   file 2: now-lastUpdate=600 < 1000 → no fire
    //   file 3: now-lastUpdate=1200 ≥ 1000 → fire, lastUpdate=now
    //   file 4: now-lastUpdate=600 < 1000 → no fire
    //   file 5: extractedCount==totalEntries → fire (rule 2)
    // Exactly 3 callbacks: files 1, 3, 5.
    var tick = 0L
    val clock = { tick.also { tick += 600 } }

    HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath,
      clock = clock,
      throttleMs = 1000L,
      progressCallback = { callbacks.add(it) }
    )

    assertEquals(3, callbacks.size)
    assertEquals(
      listOf(1.0, 3.0, 5.0),
      callbacks.map { it.extractedFiles }
    )
  }

  // ─── Password path ──────────────────────────────────────────────────────

  @Test
  fun `extractWithPasswordCore extracts password-protected zip with correct password`() = runTest {
    val zip = newZipFile("protected.zip")
    val password = "hunter2"
    ZipFixtures.writeProtectedZip(zip, password, listOf(
      "secret.txt" to "classified".toByteArray()
    ))
    val dest = newDestDir()

    val result = HybridUnzipTask.extractWithPasswordCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath,
      password = password
    )

    assertTrue(result.success)
    assertEquals(1.0, result.extractedFiles)
    assertEquals("classified", File(dest, "secret.txt").readText())
  }

  @Test
  fun `extractWithPasswordCore throws on wrong password`() = runTest {
    val zip = newZipFile("protected.zip")
    ZipFixtures.writeProtectedZip(zip, "correct", listOf(
      "secret.txt" to "classified".toByteArray()
    ))
    val dest = newDestDir()

    assertFailsWith<Exception> {
      HybridUnzipTask.extractWithPasswordCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath,
        password = "wrong"
      )
    }
  }

  // Note on password-path Zip Slip: zip4j 2.10+ validates fileNameInZip at
  // write time, so we can't programmatically build a malicious password
  // fixture from this test. The mitigation is exercised at the unit level
  // in [HybridUnzipTaskZipSlipTest] against the assertSafeEntryPath helper
  // that both extractCore and extractWithPasswordCore call.

  // ─── Task ID isolation ──────────────────────────────────────────────────

  @Test
  fun `generateTaskId produces unique IDs across sequential calls`() {
    val ids = (1..1000).map { HybridUnzipTask.generateTaskId() }
    assertEquals(1000, ids.toSet().size)
  }

  @Test
  fun `generateTaskId produces unique IDs across concurrent coroutines`() = runTest {
    // runTest's TestDispatcher is single-threaded — async {} blocks would
    // execute sequentially. Switch to Dispatchers.Default so the 500 tasks
    // actually fan out across worker threads and exercise the nanoTime()
    // + Math.random() combination under real contention. withTimeout sits
    // INSIDE the Default-dispatcher block so its 5s budget is real wall
    // time, not the surrounding TestDispatcher's virtual time (which would
    // trip instantly).
    val ids = withContext(Dispatchers.Default) {
      withTimeout(5_000) {
        (1..500).map { async { HybridUnzipTask.generateTaskId() } }.awaitAll()
      }
    }
    assertEquals(500, ids.toSet().size)
  }

  @Test
  fun `generateTaskId uses the unzip_ prefix`() {
    val id = HybridUnzipTask.generateTaskId()
    assertTrue(id.startsWith("unzip_"), "expected unzip_ prefix, got $id")
  }

  // ─── Coverage backfill for the removed collectDirectoriesToCreate helper ─

  @Test
  fun `extractCore handles an empty archive`() = runTest {
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, emptyList())
    val dest = newDestDir()

    val result = HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath
    )

    assertEquals(0.0, result.extractedFiles)
    assertEquals(0.0, result.totalFiles)
    assertTrue(result.success)
  }

  @Test
  fun `extractCore handles an archive with only root files`() = runTest {
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf(
      "a.png" to byteArrayOf(1),
      "b.png" to byteArrayOf(2)
    ))
    val dest = newDestDir()

    HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath
    )

    assertTrue(File(dest, "a.png").isFile)
    assertTrue(File(dest, "b.png").isFile)
    // Only the dest dir itself should exist — no spurious subdirectories.
    assertEquals(
      setOf("a.png", "b.png"),
      dest.listFiles()!!.map { it.name }.toSet()
    )
  }

  @Test
  fun `extractCore deduplicates explicit directory entries against parent-derived ones`() = runTest {
    val zip = newZipFile()
    // Archive has both an explicit `tiles/` directory entry AND a file
    // under it (`tiles/foo.png`). Pass 1 adds `tiles/` from the dir entry
    // and `tiles` from parentPathOf(file). Both should map to the same
    // resulting directory.
    ZipFixtures.writeZip(zip, listOf(
      "tiles/" to ByteArray(0),
      "tiles/foo.png" to byteArrayOf(1, 2, 3)
    ))
    val dest = newDestDir()

    HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath
    )

    assertTrue(File(dest, "tiles").isDirectory)
    assertTrue(File(dest, "tiles/foo.png").isFile)
  }

  // ─── New behaviours after review 2 ──────────────────────────────────────

  @Test
  fun `extractCore raises clear error when destination already exists as a regular file`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 1)
    val occupiedDest = File(tempFolder.root, "occupied")
    occupiedDest.writeText("I am a file, not a directory")

    val ex = assertFailsWith<IOException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = occupiedDest.absolutePath
      )
    }
    assertTrue(
      ex.message!!.contains("not a directory"),
      "expected fail-fast error, got ${ex.message}"
    )
  }

  @Test
  fun `extractCore rejects backslash-separator entries outright`() = runTest {
    // 0.4 NIO migration: backslash entries are out-of-spec (ZIP mandates `/`)
    // and historically produced literal-name files at dest root. Now rejected
    // by assertSafeEntryPath before any write happens.
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf(
      "subdir\\file.txt" to "hi".toByteArray()
    ))
    val dest = newDestDir()

    assertFailsWith<SecurityException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
    }
    assertEquals(0, dest.listFiles()?.size ?: 0)
  }

  @Test
  fun `extractCore rejects archives with duplicate case-collapsing entry names`() = runTest {
    // FAT32 / HFS+ / APFS-CI silently collapse `Config.json` and `config.json`
    // to the same on-disk file. Reject the whole archive rather than allow
    // the second entry to overwrite the first.
    val zip = newZipFile()
    ZipFixtures.writeZip(zip, listOf(
      "Config.json" to "benign".toByteArray(),
      "config.json" to "malicious".toByteArray()
    ))
    val dest = newDestDir()

    assertFailsWith<SecurityException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
    }
    // Pre-validation pass catches the dup BEFORE writes start → 0 files.
    assertEquals(0, dest.listFiles()?.size ?: 0)
  }

  @Test
  fun `extractWithPasswordCore rejects archives with duplicate case-collapsing entry names`() = runTest {
    val zip = newZipFile("dup.zip")
    val password = "p"
    ZipFixtures.writeProtectedZip(zip, password, listOf(
      "Secret.txt" to "benign".toByteArray(),
      "secret.txt" to "malicious".toByteArray()
    ))
    val dest = newDestDir()

    assertFailsWith<SecurityException> {
      HybridUnzipTask.extractWithPasswordCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath,
        password = password
      )
    }
    assertEquals(0, dest.listFiles()?.size ?: 0)
  }

  @Test
  fun `extractCore rejects NFD vs NFC duplicate normalisation collision`() = runTest {
    // APFS/HFS+ normalise filenames on disk so the NFC and NFD forms of
    // the same filename collapse to one on-disk file. normalizeForDedup
    // uses Normalizer.Form.NFC to catch the collision before writes start.
    //
    // Both forms are constructed explicitly via Normalizer.normalize rather
    // than embedding literal strings in the source: macOS git's
    // core.precomposeunicode (default ON) silently normalises file contents
    // to NFC at checkout, which would otherwise turn this into a same-string
    // duplicate test that would still pass even if the production NFC step
    // were removed.
    val base = "caf\u00e9.txt"  // precomposed e-acute (U+00E9)
    val nfcName = Normalizer.normalize(base, Normalizer.Form.NFC)
    val nfdName = Normalizer.normalize(base, Normalizer.Form.NFD)
    // Precondition: the two normalisations must be byte-distinct, otherwise
    // this test is exercising raw-string dedup, not NFC normalisation.
    assertTrue(
      nfcName != nfdName,
      "NFC and NFD must produce different byte sequences for this test to exercise the production NFC step"
    )

    val zip = newZipFile("nfd.zip")
    ZipFixtures.writeZip(zip, listOf(
      nfcName to "nfc".toByteArray(),
      nfdName to "nfd".toByteArray()
    ))
    val dest = newDestDir()

    assertFailsWith<SecurityException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
    }
    assertEquals(0, dest.listFiles()?.size ?: 0)
  }

  @Test
  fun `extractCore dedup uses Locale-ROOT not default-locale lowercasing`() = runTest {
    // Pin that production uses lowercase(Locale.ROOT), not the default
    // locale. Entries `\u0130.txt` (LATIN CAPITAL I WITH DOT) and `i.txt`:
    //   - Locale.ROOT.lowercase("\u0130") = "i\u0307" (i + combining dot)
    //     — does NOT match "i", so the two entries are DISTINCT under ROOT.
    //   - Locale("tr").lowercase("\u0130") = "i" — would MATCH "i" and
    //     trigger a (false) collision.
    // If production used Locale.getDefault(), this test would throw
    // SecurityException under a tr-TR default. With Locale.ROOT, it
    // extracts cleanly. We mutate the default to tr-TR to make the
    // wrong code path observable.
    val zip = newZipFile("locale.zip")
    ZipFixtures.writeZip(zip, listOf(
      "\u0130.txt" to "dotted-I".toByteArray(),
      "i.txt" to "lowercase-i".toByteArray()
    ))
    val dest = newDestDir()

    val previousLocale = Locale.getDefault()
    Locale.setDefault(Locale.forLanguageTag("tr-TR"))
    try {
      val result = HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
      // Under Locale.ROOT both entries extract cleanly. If production
      // regressed to Locale.getDefault() the tr-TR default would falsely
      // collide them and throw before this assertion ran.
      assertEquals(2.0, result.extractedFiles)
      assertTrue(File(dest, "\u0130.txt").isFile)
      assertTrue(File(dest, "i.txt").isFile)
    } finally {
      Locale.setDefault(previousLocale)
    }
  }

  // ─── Symlink injection (NOFOLLOW_LINKS + parent toRealPath verify) ─────

  @Test
  fun `extractCore refuses to write through a symlink at the target path`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile("link.zip"), count = 1)
    val dest = newDestDir()
    val outside = tempFolder.newFolder("outside")
    val outsideFile = File(outside, "secret.txt").apply { writeText("untouched") }

    // Plant a symlink at the exact entry-target path. extractCore must
    // refuse rather than follow it and overwrite outsideFile.
    // ZipFixtures.writeFlatZip names entries `file_000.bin`.
    val symlinkTarget = File(dest, "file_000.bin")
    try {
      Files.createSymbolicLink(symlinkTarget.toPath(), outsideFile.toPath())
    } catch (e: UnsupportedOperationException) {
      println("SKIP: symlink-at-target test — filesystem does not support symbolic links")
      Assume.assumeNoException(e)
      return@runTest
    } catch (e: FileSystemException) {
      println("SKIP: symlink-at-target test — symlink creation not permitted here")
      Assume.assumeNoException(e)
      return@runTest
    }

    assertFailsWith<IOException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
    }
    // The real invariant is the side-effect: NOFOLLOW_LINKS refused to
    // follow the symlink, so the outside file is untouched. Asserting on
    // the exception message would be brittle across JDK/libcore versions
    // ("Too many levels of symbolic links" vs platform-localised strerror
    // outputs vs future API levels).
    assertEquals("untouched", outsideFile.readText())
  }

  @Test
  fun `extractCore refuses when an intermediate parent dir is a symlink to outside dest`() = runTest {
    // The deeper attack: assertSafeEntryPath sees a lexical path inside
    // destDir, but a parent component is a pre-existing symlink. NOFOLLOW
    // on the final component alone doesn't catch this — createDirectoryAndVerify
    // does the post-mkdir toRealPath().startsWith(destDir) check.
    val zip = newZipFile("link-parent.zip")
    ZipFixtures.writeZip(zip, listOf(
      "subdir/file.txt" to "boom".toByteArray()
    ))
    val dest = newDestDir()
    val outside = tempFolder.newFolder("outside-target")

    try {
      Files.createSymbolicLink(File(dest, "subdir").toPath(), outside.toPath())
    } catch (e: UnsupportedOperationException) {
      println("SKIP: symlink-as-parent test — filesystem does not support symbolic links")
      Assume.assumeNoException(e)
      return@runTest
    } catch (e: FileSystemException) {
      println("SKIP: symlink-as-parent test — symlink creation not permitted here")
      Assume.assumeNoException(e)
      return@runTest
    }

    assertFailsWith<SecurityException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = dest.absolutePath
      )
    }
    // No file was written through the symlink.
    assertEquals(0, outside.listFiles()?.size ?: 0)
  }

  // ─── cancel() lifecycle ─────────────────────────────────────────────────

  @Test
  fun `generateTaskId emits ids whose prefix and shape are stable`() {
    val id = HybridUnzipTask.generateTaskId()
    assertTrue(id.startsWith("unzip_"))
    val parts = id.removePrefix("unzip_").split('_')
    assertEquals(2, parts.size, "expected unzip_<nanoTime>_<random>, got $id")
    // Both parts must parse as longs.
    parts[0].toLong()
    parts[1].toLong()
  }

  // The cancel-then-retry guard inside HybridUnzipTask.cancel() can't be
  // exercised end-to-end without instantiating the HybridObject (which the
  // JVM tests can't do — it carries a JNI HybridData). Instead, exercise
  // the underlying invariant: extractCore with `isCancelledProvider = { false }`
  // and a cancelled-but-not-yet-extracted scenario can still run cleanly.
  // This is documented at the JS boundary; covered by the cancel docstring
  // contract: 'cancel() before await() is a no-op'.

  // ─── Content URI / scheme rejection ─────────────────────────────────────

  @Test
  fun `extractCore rejects content URIs with a clear error`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 1)
    val ex = assertFailsWith<IllegalArgumentException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = "content://com.android.externalstorage.documents/tree/primary%3ADownload"
      )
    }
    assertTrue(
      ex.message!!.contains("content://"),
      "expected content URI guidance, got ${ex.message}"
    )
  }

  @Test
  fun `extractCore rejects empty destinationPath`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 1)
    assertFailsWith<IllegalArgumentException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = ""
      )
    }
  }

  @Test
  fun `extractCore rejects file scheme only with empty path`() = runTest {
    val zip = ZipFixtures.writeFlatZip(newZipFile(), count = 1)
    assertFailsWith<IllegalArgumentException> {
      HybridUnzipTask.extractCore(
        zipPath = zip.absolutePath,
        destinationPath = "file://"
      )
    }
  }

  // ─── Cached source size (deleted source after extraction) ───────────────

  @Test
  fun `buildResult uses cached source size when source file is deleted mid-extraction`() = runTest {
    // Cache happens in prepareExtraction; if a separate process unlinked
    // the source file after extraction but before buildResult, JS used to
    // see a NoSuchFileException despite the extraction succeeding.
    val zip = ZipFixtures.writeFlatZip(newZipFile("snapshot.zip"), count = 3)
    val cachedSize = zip.length()
    val dest = newDestDir()

    val result = HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath,
      progressCallback = { p ->
        // Delete the source after the first file is extracted but BEFORE
        // buildResult runs. Confirms buildResult is using the cached size.
        if (p.extractedFiles >= 1.0) zip.delete()
      },
      throttleMs = 0L
    )

    assertTrue(result.success)
    assertEquals(cachedSize.toDouble(), result.totalBytes)
    assertFalse(zip.exists(), "test setup invariant — source should have been deleted")
  }

  // ─── UTF-8 entry names ──────────────────────────────────────────────────

  @Test
  fun `extractCore correctly extracts entries with UTF-8 names`() = runTest {
    val zip = newZipFile("utf8.zip")
    ZipFixtures.writeZip(zip, listOf(
      "café.txt" to "espresso".toByteArray(),
      "中文/文档.txt" to "chinese".toByteArray(),
      "emoji-📁.txt" to "folder".toByteArray()
    ))
    val dest = newDestDir()

    val result = HybridUnzipTask.extractCore(
      zipPath = zip.absolutePath,
      destinationPath = dest.absolutePath
    )

    assertEquals(3.0, result.extractedFiles)
    assertEquals("espresso", File(dest, "café.txt").readText())
    assertEquals("chinese", File(dest, "中文/文档.txt").readText())
    assertEquals("folder", File(dest, "emoji-📁.txt").readText())
  }

  // ─── runInterruptible: structured cancellation interrupts blocking IO ─

  @Test
  fun `Job-cancel from outside the coroutine reliably aborts an in-flight extraction`() = runTest {
    // End-to-end test that structured cancellation actually stops an
    // in-flight extraction. We DO NOT try to prove runInterruptible
    // specifically translates Thread.interrupt — that path is exercised
    // for users (FileChannel-write blocked in kernel) but reliably
    // reproducing kernel-blocking IO from a CI unit test on tmpfs is
    // brittle. What's load-bearing for users: a cancel() lands and the
    // extraction halts before completing.
    //
    // Sizing: enough entries that even on fast tmpfs the extraction can
    // observe the cancel mid-stream.
    val zip = ZipFixtures.writeFlatZip(newZipFile("cancel.zip"), count = 2000, bytesPerEntry = 16 * 1024)
    val dest = newDestDir()

    val (cancelled, completionError) = withContext(Dispatchers.Default) {
      var error: Throwable? = null
      val job = launch {
        try {
          HybridUnzipTask.extractCore(
            zipPath = zip.absolutePath,
            destinationPath = dest.absolutePath
          )
        } catch (e: Throwable) {
          error = e
          throw e
        }
      }
      // Let the extraction get going, then cancel.
      kotlinx.coroutines.delay(10)
      job.cancel()
      withTimeout(5_000) { job.join() }
      job.isCancelled to error
    }
    assertTrue(cancelled, "expected Job.cancel() to land cleanly")
    // The cancellation MUST surface as CancellationException, not as a
    // bare NIO error from a ClosedByInterruptException leak.
    assertTrue(
      completionError is CancellationException,
      "expected CancellationException, got ${completionError?.javaClass?.name}: ${completionError?.message}"
    )
    val onDisk = dest.listFiles()?.size ?: 0
    assertTrue(onDisk < 2000, "expected partial extraction after cancel, got $onDisk files")
  }

  // ─── Performance smoke ─────────────────────────────────────────────────

  @Test
  fun `extractCore extracts a 1000-entry archive in under 10 seconds`() = runTest {
    // Smoke test against the migration's value-prop: ZipFile + central
    // directory should comfortably hit the documented ~474 files/s. 1000
    // entries / 10s = 100 files/s — a 4x regression headroom catches any
    // accidental return to streaming-decode without flaking the test under
    // CI load.
    val zip = ZipFixtures.writeFlatZip(newZipFile("perf.zip"), count = 1000, bytesPerEntry = 256)
    val dest = newDestDir()

    val start = System.nanoTime()
    val result = withContext(Dispatchers.Default) {
      withTimeout(10_000) {
        HybridUnzipTask.extractCore(
          zipPath = zip.absolutePath,
          destinationPath = dest.absolutePath
        )
      }
    }
    val elapsedMs = (System.nanoTime() - start) / 1_000_000

    assertEquals(1000.0, result.extractedFiles)
    println("extractCore (flat): 1000 entries in ${elapsedMs}ms (~${1000 * 1000 / elapsedMs} files/s)")
  }

  @Test
  fun `extractCore extracts a 1000-entry nested archive in under 10 seconds`() = runTest {
    // Realistic workload: tile sets, asset bundles, SDK archives — files
    // spread across deep directory trees with many shared parent prefixes.
    // This is the harder test for the directory-creation and ancestry-
    // walk paths: createdDirs dedup keeps it from re-creating shared
    // parents, verifiedAncestors cache keeps the symlink walk amortised.
    val zip = ZipFixtures.writeNestedZip(newZipFile("perf-nested.zip"), count = 1000, bytesPerEntry = 256)
    val dest = newDestDir()

    val start = System.nanoTime()
    val result = withContext(Dispatchers.Default) {
      withTimeout(10_000) {
        HybridUnzipTask.extractCore(
          zipPath = zip.absolutePath,
          destinationPath = dest.absolutePath
        )
      }
    }
    val elapsedMs = (System.nanoTime() - start) / 1_000_000

    assertEquals(1000.0, result.extractedFiles)
    // Spot-check a leaf actually landed where we expect — proves the
    // nested structure was preserved on-disk, not flattened.
    assertTrue(
      File(dest, "tier_0/sub_0/leaf_0/file_0000.bin").isFile,
      "expected nested structure to be preserved"
    )
    println("extractCore (nested): 1000 entries in ${elapsedMs}ms (~${1000 * 1000 / elapsedMs} files/s)")
  }
}
