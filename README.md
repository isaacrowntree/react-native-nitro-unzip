# react-native-nitro-unzip

High-performance ZIP extraction for React Native, powered by [Nitro Modules](https://nitro.margelo.com/).

- **iOS**: SSZipArchive (C-based libz) — ~500 files/sec
- **Android**: Optimized ZipInputStream with 64KB buffers — ~474 files/sec
- **Zero bridge overhead** for progress callbacks (JSI-based)
- **Proper object instances** — each extraction is an `UnzipTask` you can observe and cancel
- **Concurrent extractions** supported out of the box
- **iOS background task** management for continued extraction when app is backgrounded

## Installation

```bash
npm install react-native-nitro-unzip react-native-nitro-modules
cd ios && pod install
```

## Usage

```typescript
import { getUnzip } from 'react-native-nitro-unzip'

const unzip = getUnzip()
const task = unzip.extract('/path/to/archive.zip', '/path/to/output')

// Track progress
task.onProgress((p) => {
  console.log(`${(p.progress * 100).toFixed(0)}% — ${p.extractedFiles}/${p.totalFiles} files`)
  console.log(`Speed: ${p.speed.toFixed(0)} files/sec`)
})

// Await result
const result = await task.await()
console.log(`Extracted ${result.extractedFiles} files in ${result.duration}ms`)

// Or cancel
task.cancel()
```

## API

### `getUnzip(): Unzip`

Creates an `Unzip` factory instance.

### `Unzip.extract(zipPath, destinationPath): UnzipTask`

Starts extracting a ZIP archive. Returns an `UnzipTask` instance immediately.

- `zipPath` — absolute path to the ZIP file (`file://` URIs accepted)
- `destinationPath` — absolute path to extract into (created if missing)

### `UnzipTask`

| Property/Method | Type | Description |
|---|---|---|
| `taskId` | `string` | Unique identifier for this extraction |
| `onProgress(callback)` | `(progress: UnzipProgress) => void` | Register a progress callback (throttled to ~1/sec) |
| `cancel()` | `void` | Cancel this extraction |
| `await()` | `Promise<UnzipResult>` | Await the extraction result |

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

- React Native 0.75+
- Nitro Modules 0.34+
- iOS 13+
- Android SDK 21+

## License

MIT
