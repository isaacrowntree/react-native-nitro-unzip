# Changelog

## 0.4.0 — Android NIO + ZipFile migration

**Breaking changes** — please read before upgrading.

### Requirements

- **Android `minSdk` bumped from 21 → 26.** The library now uses `java.nio.file.Path` / `Files` / `FileChannel` which require API 26+. Bump your app's `minSdkVersion` accordingly.
- **`peerDependencies` updated:** `react-native-nitro-modules >= 0.35`.

### New behaviour — archive rejection

Archives that previously extracted may now be rejected with `SecurityException`. The added defences:

- **Backslash in entry names.** ZIP spec mandates `/`. Archives produced by some legacy Windows tooling embed `\` separators and previously extracted as literal-name files at the destination root. Now hard-rejected.
- **Case-insensitive duplicate detection.** Archives shipping `Config.json` and `config.json` would silently overwrite each other on FAT32/HFS+/APFS-CI volumes. Now rejected. Locale-independent (`Locale.ROOT`) and Unicode-normalised (NFC) so `café.txt` (NFC) and `café.txt` (NFD) also collide.
- **BiDi-override and C0 control characters in entry names.** Reject filenames containing `U+0000..U+001F`, `U+007F`, BiDi marks (`U+200E`, `U+200F`, `U+061C`), and overrides/isolates (`U+202A..U+202E`, `U+2066..U+2069`) — CVE-2021-42574 "Trojan Source" class.
- **Empty entry names** and entries that resolve to the destination root itself (`.`, `foo/..`) are rejected upfront.
- **Length cap.** Entry names longer than 1024 chars are rejected (kernel `ENAMETOOLONG` DoS prevention).
- **Symlink injection.** `FileChannel.open(..., NOFOLLOW_LINKS)` plus a post-`mkdirs` `toRealPath().startsWith(destDir)` assertion catches symlinks injected at the target path OR in any intermediate parent.

### New behaviour — destination handling

- **Content URIs are rejected.** `content://`-style URIs (returned by Android's Storage Access Framework / DocumentFile) now throw `IllegalArgumentException` with a clear message. Resolve them to a filesystem path before passing in.
- **Empty `destinationPath` is rejected.** Previously fell through to the JVM's current working directory; now throws `IllegalArgumentException`.
- **Failures use typed exceptions** — `IOException`, `NoSuchFileException`, `FileAlreadyExistsException` — instead of bare `Exception`, so JS-side catch handlers can branch on cause class.

### Internals — Android only

- **Single-pass extraction.** `java.util.zip.ZipFile` reads the central directory once; entries are validated upfront then extracted from the same FD. Eliminates the TOCTOU window where the source ZIP could be swapped between pass 1 (validation) and pass 2 (extraction).
- **Pre-validation rejects malicious archives before any write.** A `../escape.txt` entry mid-archive would previously partially-extract earlier benign entries before failing. Now: zero partial state on rejection.
- **`cancel()` semantics:**
  - `cancel()` before `await()` is now a **no-op** (the next `await()` proceeds normally). Previously, an early cancel poisoned the cached `awaitPromise` and the task was permanently dead.
  - `await()` is **idempotent** — calling it multiple times returns the same `Promise<UnzipResult>`.
  - Mid-write cancellation actually fires `Thread.interrupt()` via `runInterruptible`; `FileChannel`-backed writes unstick immediately rather than waiting for the next chunk boundary.
  - The original `CancellationException` cause is preserved via `ensureActive()`.
- **Pass 1 honours cancellation.** Previously, cancelling during the validation pass had to wait until pass 2 began.

### iOS

No iOS changes in 0.4.0. iOS Zip Slip / cancellation parity is the next planned follow-up.

### Test coverage

64 unit tests (was 21 in 0.3.0). Coverage added for: symlink-at-target, symlink-as-intermediate-parent, NFD/NFC normalisation collision, Turkish-locale case collision, BiDi/control-char rejection, length cap, content URI rejection, cached source size, UTF-8 entry names, and a perf smoke test (1000 entries in ~100ms on dev machine).

## 0.3.1

- `fix(android)`: validate ZIP entry paths against destination (Zip Slip)
- JVM unit tests for Zip Slip + extraction helpers

## 0.3.0

- Initial Nitro Modules 0.35 alignment, JVM target Java 17, iOS min 15.5.
