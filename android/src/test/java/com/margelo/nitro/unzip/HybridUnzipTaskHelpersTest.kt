package com.margelo.nitro.unzip

import org.junit.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pure-function tests for the throttle decision that drives HybridUnzipTask's
 * extraction loop. Directory pre-collection is now inlined in the production
 * path and covered end-to-end via [HybridUnzipTaskCoroutineTest].
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

}
