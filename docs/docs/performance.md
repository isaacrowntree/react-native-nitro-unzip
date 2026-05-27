---
sidebar_position: 3
---

# Performance

react-native-nitro-unzip is designed for speed. Here's how it performs and why.

## Benchmarks

### 0.4.0 nested perf smoke (1000 entries across ~512 unique dirs)

Measured on dev hardware. Reflects realistic workloads (tile sets, asset bundles, SDK archives) — files spread across deep directory trees with many shared parent prefixes, not a flat archive.

| Platform | Throughput | Time |
|---|---|---|
| Android (post-NIO) | ~8,300 files/sec | ~120 ms |
| iOS (`O_NOFOLLOW` streaming write) | ~10,000+ files/sec | ~100 ms |

The Android number is a **20× improvement** over the 0.3.x `ZipInputStream`-based path (~474 files/sec). The full 0.4.0 migration ([details](#whats-new-in-040)) is what made it possible.

## Why It's Fast

### iOS

- [**ZIPFoundation**](https://github.com/weichsel/ZIPFoundation) for unencrypted archives — pure Swift, iterable `Archive` type with per-entry control. Lets us pre-validate every entry's path before any file is written and honour `Task.cancel()` between entries.
- **POSIX `open(O_NOFOLLOW | O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC)`** for writes — eliminates the per-file `resolvingSymlinksInPath()` syscall the URL-based path would otherwise pay on every entry. Critical for nested archives where every leaf would otherwise re-stat its ancestors.
- [**SSZipArchive**](https://github.com/ZipArchive/ZipArchive) is retained ONLY for password-protected paths (read + write), since ZIPFoundation has no AES support.

### Android (0.4.0 NIO migration)

- **`java.util.zip.ZipFile`** for random-access central-directory reads — no inflate to enumerate headers, no TOCTOU window between validate and extract passes (single FD).
- **`java.nio.file.FileChannel.open(..., NOFOLLOW_LINKS)` + `Channels.newOutputStream(...)`** — typed exceptions (`AccessDeniedException`, `NoSuchFileException`, `FileAlreadyExistsException`), interruptible writes, and proper symlink refusal.
- **`runInterruptible(Dispatchers.IO)`** wraps every write so coroutine `cancel()` fires `Thread.interrupt()`, which unsticks an in-flight `InterruptibleChannel`-backed write immediately rather than waiting for the next chunk boundary.
- **64 KB I/O buffers**.

### Both Platforms

- **JSI callbacks** — progress updates go through JSI, bypassing the React Native bridge. No serialization overhead.
- **Throttled updates** — progress callbacks fire at most once per second, so archives with tens of thousands of files don't flood the JS thread.
- **Background execution** — extraction runs on native background threads / Swift `Task`s, keeping the UI responsive. iOS also registers a `UIApplication.beginBackgroundTask` so the OS doesn't suspend the app mid-archive.
- **Transactional**: a mid-stream failure rolls every created file and intermediate directory back, so the destination is never left in a partial-but-looks-complete state.

## What's new in 0.4.0

| Subsystem | 0.3.x | 0.4.0 |
|---|---|---|
| Android engine | `ZipInputStream` (streaming-decode) | `java.util.zip.ZipFile` (random-access central directory) |
| Android writes | `File` + `FileOutputStream` | `java.nio.file.FileChannel` + `Channels.newOutputStream` (NIO) |
| Android `cancel()` mid-write | Best-effort flag check | `Thread.interrupt()` via `runInterruptible` |
| iOS unzip engine | SSZipArchive (opaque batch) | ZIPFoundation per-entry + `open(O_NOFOLLOW)` |
| iOS `cancel()` mid-archive | Cancel flag (ignored by SSZipArchive) | `Task.checkCancellation()` between entries |
| Password write crypto (iOS) | PKWARE traditional (broken) | **AES-256** (matches Android) |
| Mid-stream failure | Partial state left on disk | **Rollback to clean state** (both platforms) |

## vs react-native-zip-archive

| | react-native-nitro-unzip | react-native-zip-archive |
|---|---|---|
| Architecture | JSI (Nitro Modules) | Bridge |
| Progress callbacks | Via JSI, no serialization | Via bridge events |
| Cancellation | Mid-write on Android (`runInterruptible`), per-entry on iOS | Not supported |
| Concurrent ops | Yes | Limited |
| Password support | AES-256 (zip & unzip) | Unzip only |
| Zip creation | Yes | Yes |
| New Architecture | Required | Optional |
| Transactional extraction | Yes (rollback on failure) | No |
