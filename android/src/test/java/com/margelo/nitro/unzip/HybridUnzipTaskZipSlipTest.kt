package com.margelo.nitro.unzip

import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * Regression tests for the Zip Slip mitigation in HybridUnzipTask.
 *
 * The mitigation lives in the companion's [HybridUnzipTask.Companion.assertSafeEntryPath]
 * helper. These tests exercise it directly — full extraction integration is
 * out of scope for JVM unit tests because the surrounding code uses Nitro
 * Modules' coroutine bridge.
 */
class HybridUnzipTaskZipSlipTest {

  @get:Rule
  val tempFolder = TemporaryFolder()

  private lateinit var destDir: File
  private lateinit var canonicalDestDir: File

  @Before
  fun setUp() {
    destDir = tempFolder.newFolder("dest")
    canonicalDestDir = destDir.canonicalFile
  }

  @After
  fun tearDown() {
    // TemporaryFolder cleans itself up — nothing else to do.
  }

  // ─── Accepts legitimate entries ─────────────────────────────────────────

  @Test
  fun `accepts plain file entry`() {
    HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, "foo.png")
  }

  @Test
  fun `accepts nested directory entry`() {
    HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, "tiles/12/345/678.png")
  }

  @Test
  fun `accepts deep nesting`() {
    HybridUnzipTask.assertSafeEntryPath(
      canonicalDestDir,
      "a/b/c/d/e/f/g/h/i.png"
    )
  }

  @Test
  fun `accepts dotted filenames that are not traversal`() {
    HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, "image.tar.gz")
    HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, ".hidden")
    HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, "..foo")
  }

  // ─── Rejects classic Zip Slip payloads ──────────────────────────────────

  @Test
  fun `rejects parent traversal`() {
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, "../escape.txt")
    }
    assert(ex.message!!.contains("../escape.txt"))
  }

  @Test
  fun `rejects deep parent traversal`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(
        canonicalDestDir,
        "../../../databases/poi.db"
      )
    }
  }

  @Test
  fun `rejects traversal mixed with subdirectories`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(
        canonicalDestDir,
        "tiles/../../../etc/passwd"
      )
    }
  }

  @Test
  fun `rejects absolute paths`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, "/etc/passwd")
    }
  }

  @Test
  fun `rejects traversal disguised by a leading sibling`() {
    // Resolves to a sibling of destDir, not inside it.
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(
        canonicalDestDir,
        "../dest-sibling/foo.png"
      )
    }
  }

  @Test
  fun `error message includes the offending entry name`() {
    val payload = "../../boom.txt"
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(canonicalDestDir, payload)
    }
    assertEquals(true, ex.message!!.contains(payload))
  }
}
