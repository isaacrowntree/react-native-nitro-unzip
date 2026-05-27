---
sidebar_position: 2
---

# Compression

Create ZIP archives from directories with progress tracking.

## Basic Compression

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

const unzip = getUnzip();
const task = unzip.zip('/path/to/folder', '/output/archive.zip');

const result = await task.await();
console.log(`Compressed ${result.compressedFiles} files`);
```

## Progress Tracking

Monitor compression progress in real-time:

```typescript
const task = unzip.zip('/path/to/folder', '/output/archive.zip');

task.onProgress((progress) => {
  console.log(`${(progress.progress * 100).toFixed(0)}%`);
  console.log(`${progress.compressedFiles}/${progress.totalFiles} files`);
  console.log(`Speed: ${progress.speed.toFixed(0)} files/sec`);
});

const result = await task.await();
```

### Progress Fields

| Field | Type | Description |
|---|---|---|
| `compressedFiles` | `number` | Files compressed so far |
| `totalFiles` | `number` | Total files to compress |
| `progress` | `number` | 0.0 to 1.0 |
| `speed` | `number` | Current speed in files per second |

## Result

The `await()` method resolves with a `ZipResult`:

```typescript
const result = await task.await();

if (result.success) {
  console.log(`Compressed ${result.compressedFiles} files`);
  console.log(`Duration: ${result.duration}ms`);
  console.log(`Average speed: ${result.averageSpeed.toFixed(0)} files/sec`);
  console.log(`Output size: ${result.totalBytes} bytes`);
}
```

| Field | Type | Description |
|---|---|---|
| `success` | `boolean` | Whether compression completed |
| `compressedFiles` | `number` | Total **files** compressed (excludes empty placeholder dirs — see note below) |
| `totalFiles` | `number` | Total **files** to compress |
| `duration` | `number` | Duration in milliseconds |
| `averageSpeed` | `number` | Average files per second |
| `totalBytes` | `number` | Total bytes written to the zip file |

:::note Empty directory preservation (0.4.0+)
Empty placeholder directories in the source (e.g. `cache/`, `logs/today/`) are preserved as trailing-slash entries in the archive, so a zip → unzip round trip keeps them. They do **not** count toward `compressedFiles` / `totalFiles` — those fields use the same files-only semantics as the unzip-side `extractedFiles` / `totalFiles`, so cross-platform round-trip counts match.
:::
