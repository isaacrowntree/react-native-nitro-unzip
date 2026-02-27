# react-native-nitro-unzip

[![npm](https://img.shields.io/npm/v/react-native-nitro-unzip)](https://www.npmjs.com/package/react-native-nitro-unzip)
[![license](https://img.shields.io/npm/l/react-native-nitro-unzip)](https://github.com/isaacrowntree/react-native-nitro-unzip/blob/main/LICENSE)
[![CI](https://github.com/isaacrowntree/react-native-nitro-unzip/actions/workflows/lint-typescript.yml/badge.svg)](https://github.com/isaacrowntree/react-native-nitro-unzip/actions/workflows/lint-typescript.yml)

High-performance ZIP operations for React Native, powered by [Nitro Modules](https://nitro.margelo.com/).

- **iOS**: SSZipArchive (C-based libz) — ~500 files/sec
- **Android**: Optimized ZipInputStream with 64KB buffers — ~474 files/sec
- **Zero bridge overhead** — progress callbacks via JSI, no serialization
- **Object instances** — each task is an observable, cancellable `UnzipTask` or `ZipTask`
- **Concurrent operations** supported out of the box
- **Password support** — AES-256 encrypted archives (zip4j on Android, SSZipArchive on iOS)
- **Zip creation** — compress files and directories with optional password protection
- **Background tasks** — iOS background task management for continued extraction

## Installation

```bash
npm install react-native-nitro-unzip react-native-nitro-modules
cd ios && pod install
```

> Requires React Native 0.75+ and [Nitro Modules](https://nitro.margelo.com/) 0.34+

## Usage

### Extract a ZIP archive

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

const unzip = getUnzip();
const task = unzip.extract('/path/to/archive.zip', '/path/to/output');

task.onProgress((p) => {
  console.log(`${(p.progress * 100).toFixed(0)}% — ${p.extractedFiles}/${p.totalFiles} files`);
  console.log(`Speed: ${p.speed.toFixed(0)} files/sec`);
});

const result = await task.await();
console.log(`Extracted ${result.extractedFiles} files in ${result.duration}ms`);
```

### Extract with password

```typescript
const task = unzip.extractWithPassword('/path/to/encrypted.zip', '/output', 'secret');
const result = await task.await();
```

### Create a ZIP archive

```typescript
const task = unzip.zip('/path/to/folder', '/output/archive.zip');

task.onProgress((p) => {
  console.log(`${(p.progress * 100).toFixed(0)}% — ${p.compressedFiles}/${p.totalFiles}`);
});

const result = await task.await();
console.log(`Compressed ${result.compressedFiles} files`);
```

### Create with password (AES-256)

```typescript
const task = unzip.zipWithPassword('/path/to/folder', '/output/secure.zip', 'secret');
const result = await task.await();
```

### Cancel an operation

```typescript
const task = unzip.extract('/path/to/large.zip', '/output');

// Cancel at any time — synchronous via JSI
task.cancel();
```

## API

### `getUnzip(): Unzip`

Creates an `Unzip` factory instance.

### Extraction

| Method | Returns | Description |
|---|---|---|
| `extract(zipPath, destPath)` | `UnzipTask` | Extract a ZIP archive |
| `extractWithPassword(zipPath, destPath, password)` | `UnzipTask` | Extract a password-protected archive |

### Compression

| Method | Returns | Description |
|---|---|---|
| `zip(sourcePath, destZipPath)` | `ZipTask` | Create a ZIP archive from a directory |
| `zipWithPassword(sourcePath, destZipPath, password)` | `ZipTask` | Create a password-protected ZIP (AES-256) |

### `UnzipTask` / `ZipTask`

| Property/Method | Type | Description |
|---|---|---|
| `taskId` | `string` | Unique identifier for this operation |
| `onProgress(callback)` | `void` | Register a progress callback (throttled ~1/sec) |
| `cancel()` | `void` | Cancel the operation (synchronous via JSI) |
| `await()` | `Promise<Result>` | Await the operation result |

### `UnzipProgress`

| Field | Type | Description |
|---|---|---|
| `extractedFiles` | `number` | Files extracted so far |
| `totalFiles` | `number` | Total files in archive |
| `progress` | `number` | 0.0 to 1.0 |
| `speed` | `number` | Files per second |
| `processedBytes` | `number` | Bytes processed |

### `UnzipResult`

| Field | Type | Description |
|---|---|---|
| `success` | `boolean` | Whether extraction completed |
| `extractedFiles` | `number` | Total files extracted |
| `duration` | `number` | Duration in milliseconds |
| `averageSpeed` | `number` | Average files per second |
| `totalBytes` | `number` | Total bytes extracted |

### `ZipProgress`

| Field | Type | Description |
|---|---|---|
| `compressedFiles` | `number` | Files compressed so far |
| `totalFiles` | `number` | Total files to compress |
| `progress` | `number` | 0.0 to 1.0 |
| `speed` | `number` | Files per second |

### `ZipResult`

| Field | Type | Description |
|---|---|---|
| `success` | `boolean` | Whether compression completed |
| `compressedFiles` | `number` | Total files compressed |
| `duration` | `number` | Duration in milliseconds |
| `averageSpeed` | `number` | Average files per second |
| `totalBytes` | `number` | Total bytes written |

## Performance

Benchmarked on a 350MB archive with 10,432 small files (map tiles):

| Platform | Speed | Time |
|---|---|---|
| iOS (iPhone) | ~500 files/sec | ~20s |
| Android | ~474 files/sec | ~22s |

### Why it's fast

- **iOS**: SSZipArchive uses C-based libz decompression with streaming extraction
- **Android**: 64KB I/O buffers (8x default), batch directory creation, buffered streams
- **Both**: Progress callbacks go through JSI (no bridge serialization), throttled to 1/sec

## Requirements

| Requirement | Version |
|---|---|
| React Native | 0.75+ |
| Nitro Modules | 0.34+ |
| iOS | 13+ |
| Android SDK | 21+ |

## Example

See the [example app](./example) for a working demo of extraction, zip creation, password support, and cancellation.

## Contributing

See the [contributing guide](CONTRIBUTING.md) to learn how to contribute to the repository and the development workflow.

## License

MIT
