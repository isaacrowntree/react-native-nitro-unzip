# Changelog

## 0.5.1 — Test sources excluded from published package

### Bug fixes

- **iOS**: `ios/Tests/**/*` no longer compile into consumers' Pods targets. The podspec's `source_files = 'ios/**/*.{h,m,mm,swift,...}'` glob was pulling test files (`ExtractionScopeTests.swift`, `UnzipErrorTests.swift`, `PartialExtractionRollbackTests.swift`, `NestedExtractionPerfTests.swift`) into the consumer's build. Now excluded via `exclude_files`.
- **npm tarball hygiene**: `ios/Tests/` and `android/src/test/` were shipping in the published package (~95 KB across platforms). Now excluded via `files` field. Android source sets already kept `src/test` separate at compile time — this is purely tarball hygiene on that side.

No behavioural changes to extraction or zip logic.

## 0.5.0 — Cross-platform security hardening (Android NIO/ZipFile + iOS ZIPFoundation)

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

### iOS — parity with the Android security model

The same threat model addressed on Android is now closed on iOS, implemented
with iOS/Swift primitives (not a Java translation):

- **Engine**: `ZIPFoundation` (pure Swift, iterable `Archive` type) for
  unencrypted ZIPs. Lets us pre-validate every entry's path BEFORE
  writing any file and honour `Task.cancel()` between entries.
  `SSZipArchive` is retained ONLY for password-protected paths (read and
  write) because ZIPFoundation has no AES support in either direction.
  Both paths run the same `ExtractionScope.safeURL` validation, so the
  security properties hold identically — only the underlying decrypt
  engine differs, and password-path mid-extraction cancel is
  best-effort (SSZipArchive can't be aborted once started).
- **Password ZIP crypto upgraded to AES-256 on iOS.** 0.3 used
  SSZipArchive's `withPassword:` overload which writes traditional
  PKWARE encryption — broken, crackable in minutes with modern tools.
  0.5.0 uses SSZipArchive's `aes: true` overload to match Android's
  AES-256 strength. Cross-platform password archives now have
  equivalent crypto.
- **Mid-extraction cancellation on the password path now reads the
  captured Task** rather than `Task.isCancelled`. The DispatchQueue
  worker thread that runs SSZipArchive's progress callback is outside
  any Task context, so `Task.isCancelled` would always return `false`
  (the 0.3 cancel claim was vacuous here). The Task instance's
  `isCancelled` is callable from any thread and correctly observes
  cancellation.
- **Modern Swift Concurrency**: `async`/`await` + `Task` + `Task.checkCancellation()`
  replace `NSLock` + `shouldCancel` + `DispatchQueue.global`. The cancel
  signal flows through structured concurrency — no separate state machine.
- **Typed `UnzipError` enum**: each case maps to a stable `code` string
  surfaced via `NSError.userInfo[NitroUnzipErrorCodeKey]`. JS callers
  can `switch` on `err.userInfo.NitroUnzipErrorCode` instead of
  substring-matching localised messages.
- **`URL`-based path safety** (not `String` paths). Uses Foundation's
  `.standardized` / `.resolvingSymlinksInPath()` and a `CharacterSet` of
  unsafe codepoints (controls, BiDi, NUL) to validate every entry.
- **Same security defences ship on both platforms**: Zip Slip path
  traversal, absolute paths, backslash separators, NUL bytes, BiDi
  marks/overrides, C0 controls, length cap, empty entries, dot/dotdot
  resolutions, case-insensitive NFC duplicate detection, symlink
  injection at the entry path or in any ancestor.
- **Cancellation actually works**: SSZipArchive's `unzipFile` ran to
  completion regardless of the cancel flag; with ZIPFoundation we
  iterate per-entry and check cancellation between each one. Mid-archive
  cancel halts cleanly.
- **`await()` is idempotent**: a second call returns the same Promise.
- **`cancel()` before `await()` is a no-op** (matches the Android
  contract; doesn't poison the cached Promise).
- **Scheme rejection**: non-`file://` URIs (e.g. `content://` or
  picker-returned URLs) throw `DEST_SCHEME_UNSUPPORTED` upfront.
- **Symlink-as-archive-entry rejected**: ZIP entries marked as symlinks
  in their external attributes are refused outright — never honoured.

### iOS requirements

- **Pod dependency change**: `ZIPFoundation ~> 0.9` added (used by
  default paths). `SSZipArchive ~> 2.5` is retained ONLY for the
  password-protected read+write paths it uniquely supports on iOS.
  `pod install` after upgrading.
- iOS minimum stays at **15.5+**.

### Transactional extraction (both platforms)

- **Zero partial state on mid-stream failure.** If extraction throws
  partway through (corrupt entry, disk full, write error, cancellation
  between entries), every file and directory we created is rolled back
  before the error surfaces. The previous behaviour left partials on
  disk that could look complete to the calling app. iOS uses
  `PartialExtractionRollback.rollback(files:, directories:)`; Android
  uses `rollbackPartialExtraction(files, directories)`. Both delete
  files last-written-first then directories deepest-first (depth =
  path-component count, not string length).
- **Intermediate directories are tracked, not just leaves.** Previously
  `createDirectory(withIntermediateDirectories: true)` (iOS) and
  `Files.createDirectories` (Android) created every missing parent in
  one call, but rollback only knew about the leaf — orphaned empty
  parents survived. 0.5.0 walks ancestry one level at a time and
  records each created directory.
- **Write errors propagate instead of being silently swallowed.** The
  iOS unzip path used `try? handle.write(contentsOf:)` inside the
  ZIPFoundation consumer closure, meaning a disk-full or `ENOSPC`
  truncated the output file without surfacing an error — the caller
  saw `success: true` over a partial file. Now the write throws and
  triggers rollback.

### iOS compression

- **Empty placeholder directories survive a zip + unzip round trip.**
  `HybridZipTask.collectRelativePaths` now emits both files AND
  trailing-slash directory entries (`cache/`, `logs/today/`) so
  placeholders the source tree depends on aren't silently dropped.
- **`totalFiles` / `compressedFiles` on `ZipResult` count files only,**
  matching the unzip side's `extractedFiles` semantics. Trailing-slash
  directory entries no longer inflate the round-trip count.

### iOS perf

- **POSIX `open(O_NOFOLLOW)` write path** eliminates the per-file
  `resolvingSymlinksInPath()` syscall the previous URL-based write
  needed. Real impact on nested-folder archives (tile sets, asset
  bundles) where every entry would otherwise re-stat its ancestors.

### Test coverage

- **Android**: 73 unit tests (was 21 in 0.3.0). Adds: partial-extraction
  rollback (mid-stream failure rolls back files + intermediate dirs +
  leaves destDir intact), `rollbackPartialExtraction` direct helper
  tests, deepest-first dir deletion ordering, empty placeholder
  directory preservation through both the unencrypted and password
  paths, zero-entry archive, nested perf (1000 entries in ~120ms on
  dev hardware → ~8,300 files/sec).
- **iOS**: 46 SPM-based XCTests covering the full security surface plus
  `PartialExtractionRollback` direct tests (file-only, dir-only, mixed,
  missing-target, deepest-first ordering, empty inputs). Run via
  `swift test` from the repo root — no Xcode UI needed. The Hybrid
  classes' end-to-end orchestration is intentionally tested via the
  consuming app's actual extraction rather than mocked at the SPM layer.

## 0.3.1

- `fix(android)`: validate ZIP entry paths against destination (Zip Slip)
- JVM unit tests for Zip Slip + extraction helpers

## 0.3.0

- Initial Nitro Modules 0.35 alignment, JVM target Java 17, iOS min 15.5.
