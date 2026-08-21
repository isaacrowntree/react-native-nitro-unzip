# react-native-nitro-unzip

[![npm](https://img.shields.io/npm/v/react-native-nitro-unzip)](https://www.npmjs.com/package/react-native-nitro-unzip)
[![npm downloads](https://img.shields.io/npm/dm/react-native-nitro-unzip)](https://www.npmjs.com/package/react-native-nitro-unzip)
[![license](https://img.shields.io/npm/l/react-native-nitro-unzip)](https://github.com/isaacrowntree/react-native-nitro-unzip/blob/main/LICENSE)
[![CI](https://github.com/isaacrowntree/react-native-nitro-unzip/actions/workflows/lint-typescript.yml/badge.svg)](https://github.com/isaacrowntree/react-native-nitro-unzip/actions/workflows/lint-typescript.yml)
![Platform - iOS](https://img.shields.io/badge/platform-iOS-blue)
![Platform - Android](https://img.shields.io/badge/platform-Android-green)

High-performance ZIP operations for React Native, powered by [Nitro Modules](https://nitro.margelo.com/).

**[Read the full documentation](https://isaacrowntree.github.io/react-native-nitro-unzip/)**

## Features

- **Fast** — ~9,000+ files/sec on Android (post-NIO / `java.util.zip.ZipFile` migration in 0.5.0) and ~10,000+ files/sec on iOS (`O_NOFOLLOW` streaming writes), measured on nested 1000-entry archives on dev hardware
- **Zero bridge overhead** — progress callbacks via JSI, no serialization
- **Cancellable** — mid-write cancellation on Android (`Thread.interrupt()` + interruptible NIO channels), per-entry cancellation on iOS (Swift Concurrency)
- **AES-256 password support** — encrypted archives, zip & unzip, on both platforms
- **Transactional extraction** — zero partial state on mid-stream failure (rollback on both platforms)
- **Concurrent operations** — multiple tasks run independently
- **Background execution** — iOS background task management

## Installation

```bash
npm install react-native-nitro-unzip react-native-nitro-modules
cd ios && pod install
```

> Requires React Native 0.75+, [Nitro Modules](https://nitro.margelo.com/) 0.37+, iOS 15.5+, **Android minSdk 26+** (since 0.5.0), and Java 17 (Android).
>
> Android builds target SDK 36 and Kotlin 2.1. The library reads `rootProject.ext.compileSdkVersion` / `ndkVersion` / `kotlinVersion` before its own defaults, so a consuming app (or Expo's root project) controls the toolchain as usual.

### Security defences (0.5.0+)

The 0.5.0 release added the same Zip Slip / symlink / case-collision /
BiDi-spoofing defences to **both Android and iOS**:

- Path traversal (`../escape`), absolute paths, backslash separators
- NUL bytes, BiDi overrides/isolates (CVE-2021-42574 class), C0 control characters
- Length cap (1024 chars), empty entries, dot/dot-dot resolutions
- Case-insensitive + NFC-normalised duplicate detection (FAT32/HFS+/APFS-CI overwrite prevention)
- Symlink injection at the entry target OR in any ancestor directory
- **Transactional extraction**: any failure mid-extraction (corrupt
  entry, disk full, write error, cancellation) rolls back every file
  AND every intermediate directory we created before the error
  surfaces — the destination is either fully extracted or untouched

Errors carry a stable `code` (e.g. `ENTRY_OUTSIDE_DESTINATION`,
`SYMLINK_IN_ANCESTRY`, `WRONG_PASSWORD`, `CANCELLED`) so JS handlers can
branch programmatically rather than parsing localised messages.

### Platform configuration

**iOS.** The library depends on `SSZipArchive`, which requires iOS 15.5+. Ensure your app's Podfile (or Expo `Podfile.properties.json`) sets `ios.deploymentTarget` to `15.5` or higher. Expo SDK 57 already floors this at 16.4, so no action is needed there.

**Android.** The library hard-requires `minSdkVersion 26` (the extraction path uses `java.nio.file`). The manifest merger rejects a lower value at build time rather than crashing on device, so set it explicitly. With Expo, use `expo-build-properties`:

```json
{
  "expo": {
    "plugins": [["expo-build-properties", { "android": { "minSdkVersion": 26 } }]]
  }
}
```

For a bare React Native app, set `minSdkVersion = 26` in `android/build.gradle`.

## Quick Example

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

const unzip = getUnzip();
const task = unzip.extract('/path/to/archive.zip', '/path/to/output');

task.onProgress((p) => {
  console.log(`${(p.progress * 100).toFixed(0)}% — ${p.extractedFiles}/${p.totalFiles} files`);
});

const result = await task.await();
console.log(`Extracted ${result.extractedFiles} files in ${result.duration}ms`);
```

## Documentation

Visit the **[docs site](https://isaacrowntree.github.io/react-native-nitro-unzip/)** for:

- [Getting Started](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/getting-started) — installation and setup
- [Extraction](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/usage/extraction) — extract archives with progress
- [Compression](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/usage/compression) — create ZIP archives
- [Password Protection](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/usage/password) — encrypted archives
- [Cancellation](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/usage/cancellation) — cancel operations
- [Performance](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/performance) — benchmarks and internals
- [API Reference](https://isaacrowntree.github.io/react-native-nitro-unzip/docs/api) — auto-generated from TypeScript

## Example

See the [example app](./example) for a working demo.

## Contributing

See the [contributing guide](CONTRIBUTING.md) to learn how to contribute to the repository and the development workflow.

## License

MIT
