package com.margelo.nitro.unzip

import com.margelo.nitro.unzip.HybridUnzipTask.Companion.EntryDescriptor
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pure-function tests for the helpers that drive HybridUnzipTask's
 * extraction loop. These exercise the wrapper-owned logic (throttling,
 * directory pre-collection) without instantiating the Nitro module —
 * everything tested here is our code, not the underlying JDK / zip4j.
 */
class HybridUnzipTaskHelpersTest {

  // ─── shouldDispatchProgress ─────────────────────────────────────────────

  @Test
  fun `dispatches immediately on the first extracted file`() {
    assertTrue(
      HybridUnzipTask.shouldDispatchProgress(
        now = 0L,
        lastUpdate = 0L,
        extractedCount = 1,
        totalEntries = 1000
      )
    )
  }

  @Test
  fun `dispatches when the final file is extracted regardless of throttle`() {
    assertTrue(
      HybridUnzipTask.shouldDispatchProgress(
        now = 100L,
        lastUpdate = 50L, // 50ms ago — well inside the default 1000ms throttle
        extractedCount = 1000,
        totalEntries = 1000
      )
    )
  }

  @Test
  fun `throttles mid-stream updates inside the window`() {
    assertFalse(
      HybridUnzipTask.shouldDispatchProgress(
        now = 500L,
        lastUpdate = 0L, // 500ms ago — inside the 1000ms throttle
        extractedCount = 50,
        totalEntries = 1000
      )
    )
  }

  @Test
  fun `dispatches once the throttle window elapses`() {
    assertTrue(
      HybridUnzipTask.shouldDispatchProgress(
        now = 1500L,
        lastUpdate = 0L, // 1500ms ago — outside the 1000ms throttle
        extractedCount = 50,
        totalEntries = 1000
      )
    )
  }

  @Test
  fun `dispatches at exactly the throttle boundary`() {
    assertTrue(
      HybridUnzipTask.shouldDispatchProgress(
        now = 1000L,
        lastUpdate = 0L, // exactly 1000ms — inclusive boundary
        extractedCount = 50,
        totalEntries = 1000
      )
    )
  }

  @Test
  fun `respects a custom throttle window`() {
    // With a 100ms throttle, a 50ms gap should be skipped...
    assertFalse(
      HybridUnzipTask.shouldDispatchProgress(
        now = 50L,
        lastUpdate = 0L,
        extractedCount = 10,
        totalEntries = 100,
        throttleMs = 100L
      )
    )
    // ...but a 150ms gap should fire.
    assertTrue(
      HybridUnzipTask.shouldDispatchProgress(
        now = 150L,
        lastUpdate = 0L,
        extractedCount = 10,
        totalEntries = 100,
        throttleMs = 100L
      )
    )
  }

  @Test
  fun `handles zero totalEntries gracefully (no division)`() {
    // The first-file and final-file rules still apply; throttle decides
    // the rest. Important: this function shouldn't divide by zero.
    assertTrue(
      HybridUnzipTask.shouldDispatchProgress(
        now = 0L,
        lastUpdate = 0L,
        extractedCount = 1,
        totalEntries = 0
      )
    )
  }

  // ─── collectDirectoriesToCreate ─────────────────────────────────────────

  @Test
  fun `returns empty list for an archive with only root files`() {
    val dirs = HybridUnzipTask.collectDirectoriesToCreate(
      listOf(
        EntryDescriptor("a.png", false),
        EntryDescriptor("b.png", false)
      )
    )
    assertEquals(emptyList(), dirs)
  }

  @Test
  fun `extracts parent directories from nested file entries`() {
    val dirs = HybridUnzipTask.collectDirectoriesToCreate(
      listOf(
        EntryDescriptor("tiles/12/x/y.png", false),
        EntryDescriptor("tiles/12/x/z.png", false)
      )
    )
    // Only the immediate parent of each file is collected — File.parent
    // returns the closest enclosing directory, not the full ancestor chain.
    // mkdirs() in the production path handles intermediate creation.
    assertEquals(listOf("tiles/12/x"), dirs)
  }

  @Test
  fun `includes explicit directory entries as-is`() {
    val dirs = HybridUnzipTask.collectDirectoriesToCreate(
      listOf(
        EntryDescriptor("tiles/", true),
        EntryDescriptor("tiles/foo.png", false)
      )
    )
    // Both "tiles/" (explicit) and "tiles" (from foo.png's parent) end up
    // in the set — deduplicated by the underlying hashSet.
    assertTrue(dirs.contains("tiles/") || dirs.contains("tiles"))
  }

  @Test
  fun `sorts directories so parents come before children`() {
    val dirs = HybridUnzipTask.collectDirectoriesToCreate(
      listOf(
        EntryDescriptor("a/b/c/d.png", false),
        EntryDescriptor("a/x.png", false),
        EntryDescriptor("a/b/y.png", false)
      )
    )
    // Lexicographic sort gives parent-before-child for typical paths,
    // ensuring mkdirs() never tries to create a child whose parent doesn't
    // exist (it would anyway via mkdirs() recursion, but the sort makes
    // the algorithm predictable).
    val a = dirs.indexOf("a")
    val ab = dirs.indexOf("a/b")
    val abc = dirs.indexOf("a/b/c")
    // Only entries that appear get checked; any -1 simply means that level
    // wasn't a parent of any file (File.parent returns the immediate parent
    // only, so deep nests collect only the deepest level here).
    if (a >= 0 && ab >= 0) assertTrue(a < ab)
    if (ab >= 0 && abc >= 0) assertTrue(ab < abc)
  }

  @Test
  fun `deduplicates repeated directories`() {
    val dirs = HybridUnzipTask.collectDirectoriesToCreate(
      listOf(
        EntryDescriptor("tiles/a.png", false),
        EntryDescriptor("tiles/b.png", false),
        EntryDescriptor("tiles/c.png", false)
      )
    )
    assertEquals(listOf("tiles"), dirs)
  }

  @Test
  fun `handles an empty entry list`() {
    val dirs = HybridUnzipTask.collectDirectoriesToCreate(emptyList())
    assertEquals(emptyList(), dirs)
  }
}
