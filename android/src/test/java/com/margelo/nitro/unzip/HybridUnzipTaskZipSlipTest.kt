package com.margelo.nitro.unzip

import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Regression tests for the Zip Slip mitigation in HybridUnzipTask.
 *
 * The mitigation lives in [HybridUnzipTask.Companion.assertSafeEntryPath].
 * These tests exercise it directly — full extraction integration is covered
 * end-to-end via [HybridUnzipTaskCoroutineTest].
 *
 * After the 0.4 NIO migration, the helper takes a [Path] and uses Path
 * resolution + normalisation instead of File canonicalisation.
 */
class HybridUnzipTaskZipSlipTest {

  @get:Rule
  val tempFolder = TemporaryFolder()

  private lateinit var destDir: Path

  @Before
  fun setUp() {
    // toRealPath() resolves symlinks (matches what prepareExtraction does),
    // so the test rig matches production.
    destDir = tempFolder.newFolder("dest").toPath().toRealPath()
  }

  // ─── Accepts legitimate entries ─────────────────────────────────────────

  @Test
  fun `accepts plain file entry`() {
    HybridUnzipTask.assertSafeEntryPath(destDir, "foo.png")
  }

  @Test
  fun `accepts nested directory entry`() {
    HybridUnzipTask.assertSafeEntryPath(destDir, "tiles/12/345/678.png")
  }

  @Test
  fun `accepts deep nesting`() {
    HybridUnzipTask.assertSafeEntryPath(destDir, "a/b/c/d/e/f/g/h/i.png")
  }

  @Test
  fun `accepts dotted filenames that are not traversal`() {
    HybridUnzipTask.assertSafeEntryPath(destDir, "image.tar.gz")
    HybridUnzipTask.assertSafeEntryPath(destDir, ".hidden")
    HybridUnzipTask.assertSafeEntryPath(destDir, "..foo")
  }

  @Test
  fun `accepts entry with internal traversal that stays inside dest`() {
    // Path.normalize collapses `..` so `foo/../bar` becomes `bar` — still
    // inside destDir. This is intentional: archives sometimes contain
    // legitimate internal traversal patterns.
    val resolved = HybridUnzipTask.assertSafeEntryPath(destDir, "foo/../bar.png")
    assertEquals(destDir.resolve("bar.png"), resolved)
  }

  @Test
  fun `returns the resolved Path so the caller can reuse it`() {
    val resolved = HybridUnzipTask.assertSafeEntryPath(destDir, "tiles/12/x.png")
    assertEquals(destDir.resolve("tiles/12/x.png"), resolved)
  }

  // ─── Rejects classic Zip Slip payloads ──────────────────────────────────

  @Test
  fun `rejects parent traversal`() {
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "../escape.txt")
    }
    assertTrue(ex.message!!.contains("../escape.txt"))
  }

  @Test
  fun `rejects deep parent traversal`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "../../../databases/poi.db")
    }
  }

  @Test
  fun `rejects traversal mixed with subdirectories`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "tiles/../../../etc/passwd")
    }
  }

  @Test
  fun `rejects POSIX absolute paths`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "/etc/passwd")
    }
  }

  @Test
  fun `rejects traversal disguised by a leading sibling`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "../dest-sibling/foo.png")
    }
  }

  @Test
  fun `error message includes the offending entry name`() {
    val payload = "../../boom.txt"
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, payload)
    }
    assertTrue(ex.message!!.contains(payload))
  }

  @Test
  fun `rejects entry whose normalised path equals destDir`() {
    // `.` resolves to destDir itself; `foo/..` collapses to destDir.
    // FileOutputStream on the dest dir would crash with IsADirectoryException.
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, ".")
    }
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "foo/..")
    }
  }

  // ─── NUL byte + invalid path characters ─────────────────────────────────

  @Test
  fun `rejects NUL byte in entry name`() {
    // NUL is a C0 control character (< U+0020) so it deterministically hits
    // the isUnsafeChar branch before Path's resolve() would even see it.
    // Assert the specific message to catch regressions where the control
    // check is removed and NUL falls through to InvalidPathException.
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "foo\u0000.txt")
    }
    assertTrue(
      ex.message!!.contains("control"),
      "expected control-char rejection (NUL is a C0 control), got: ${ex.message}"
    )
  }

  @Test
  fun `rejects NUL byte even when wrapped by safe-looking path`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "tiles/foo\u0000/bar.png")
    }
  }

  // ─── Empty entry name ───────────────────────────────────────────────────

  @Test
  fun `rejects empty entry name`() {
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "")
    }
    assertTrue(ex.message!!.contains("empty"))
  }

  // ─── Backslash entries ──────────────────────────────────────────────────

  @Test
  fun `rejects entries containing backslash`() {
    // ZIP spec mandates `/`. On POSIX, `\` is a filename character — so an
    // entry like `..\..\etc\passwd` would not be caught by Path's normalize
    // (each backslash-component is opaque) and would extract as a literal-
    // name file at dest root. Reject outright.
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "subdir\\file.txt")
    }
  }

  @Test
  fun `rejects backslash-prefixed entries`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "\\foo.txt")
    }
  }

  @Test
  fun `rejects mid-path backslash traversal`() {
    assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, "..\\..\\etc\\passwd")
    }
  }

  // ─── Control characters and BiDi-override ───────────────────────────────

  @Test
  fun `rejects C0 control characters in entry name`() {
    // \u001b (ESC) can inject ANSI sequences into terminals echoing logs;
    // \u0007 (BEL), \u007f (DEL), etc.
    for (c in listOf('\u0001', '\u0007', '\u001b', '\u007f')) {
      assertFailsWith<SecurityException>("expected SecurityException for char ${c.code}") {
        HybridUnzipTask.assertSafeEntryPath(destDir, "log${c}injected.txt")
      }
    }
  }

  @Test
  fun `rejects BiDi-override characters in entry name`() {
    // \u202e (RTL OVERRIDE) reverses subsequent text — `safe\u202etxt.exe`
    // displays in file browsers as `safeexe.txt`, spoofing a benign filename.
    // U+202A..U+202E = explicit overrides; U+2066..U+2069 = isolates;
    // U+200E/U+200F = LRM/RLM marks; U+061C = ALM (Arabic Letter Mark).
    val bidiChars = listOf(
      '\u200e', '\u200f', '\u061c',
      '\u202a', '\u202b', '\u202c', '\u202d', '\u202e',
      '\u2066', '\u2067', '\u2068', '\u2069'
    )
    for (c in bidiChars) {
      assertFailsWith<SecurityException>("expected SecurityException for char ${c.code}") {
        HybridUnzipTask.assertSafeEntryPath(destDir, "payment${c}rfdp.exe")
      }
    }
  }

  // ─── Length cap ─────────────────────────────────────────────────────────

  @Test
  fun `rejects entry names exceeding the length cap`() {
    val tooLong = "a".repeat(1025)
    val ex = assertFailsWith<SecurityException> {
      HybridUnzipTask.assertSafeEntryPath(destDir, tooLong)
    }
    assertTrue(ex.message!!.contains("longer than"))
  }

  @Test
  fun `accepts entry names at the length cap boundary`() {
    val atCap = "a".repeat(1024)
    HybridUnzipTask.assertSafeEntryPath(destDir, atCap)
  }
}
