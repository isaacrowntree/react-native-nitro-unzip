---
sidebar_position: 1
---

# Extraction

Extract ZIP archives with real-time progress tracking.

## Basic Extraction

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

const unzip = getUnzip();
const task = unzip.extract('/path/to/archive.zip', '/path/to/output');

const result = await task.await();
console.log(`Extracted ${result.extractedFiles} files`);
```

The destination directory is created automatically if it doesn't exist.

## Progress Tracking

Register a progress callback to get real-time updates during extraction:

```typescript
const task = unzip.extract('/path/to/archive.zip', '/path/to/output');

task.onProgress((progress) => {
  console.log(`${(progress.progress * 100).toFixed(0)}%`);
  console.log(`${progress.extractedFiles}/${progress.totalFiles} files`);
  console.log(`Speed: ${progress.speed.toFixed(0)} files/sec`);
  console.log(`Processed: ${progress.processedBytes} bytes`);
});

const result = await task.await();
```

Progress callbacks are throttled to approximately one update per second to avoid unnecessary overhead. The first file and final file always trigger a callback regardless of throttling.

### Progress Fields

| Field | Type | Description |
|---|---|---|
| `extractedFiles` | `number` | Files extracted so far |
| `totalFiles` | `number` | Total files in the archive |
| `progress` | `number` | 0.0 to 1.0 |
| `speed` | `number` | Current speed in files per second |
| `processedBytes` | `number` | Bytes processed so far |

## Result

The `await()` method resolves with an `UnzipResult`:

```typescript
const result = await task.await();

if (result.success) {
  console.log(`Extracted ${result.extractedFiles} files`);
  console.log(`Duration: ${result.duration}ms`);
  console.log(`Average speed: ${result.averageSpeed.toFixed(0)} files/sec`);
  console.log(`Total size: ${result.totalBytes} bytes`);
}
```

| Field | Type | Description |
|---|---|---|
| `success` | `boolean` | Whether extraction completed |
| `extractedFiles` | `number` | Total files extracted |
| `totalFiles` | `number` | Total files in the archive |
| `duration` | `number` | Duration in milliseconds |
| `averageSpeed` | `number` | Average files per second |
| `totalBytes` | `number` | Size of the ZIP file in bytes |

## Concurrent Extractions

Multiple extractions can run simultaneously. Each task operates independently:

```typescript
const task1 = unzip.extract('/path/to/first.zip', '/output/first');
const task2 = unzip.extract('/path/to/second.zip', '/output/second');

const [result1, result2] = await Promise.all([
  task1.await(),
  task2.await(),
]);
```

## File URI Support

Both `file://` URIs and plain absolute paths are accepted:

```typescript
// Both work
unzip.extract('file:///path/to/archive.zip', '/output');
unzip.extract('/path/to/archive.zip', '/output');
```
