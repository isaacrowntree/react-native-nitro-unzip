---
sidebar_position: 1
---

# Getting Started

react-native-nitro-unzip provides high-performance ZIP extraction and compression for React Native, powered by [Nitro Modules](https://nitro.margelo.com/).

## Requirements

| Requirement | Version |
|---|---|
| React Native | 0.75+ |
| Nitro Modules | 0.34+ |
| iOS | 13+ |
| Android SDK | 21+ |

:::info New Architecture Required
This library requires React Native's New Architecture (Fabric + TurboModules) as it is built on Nitro Modules.
:::

## Installation

```bash
npm install react-native-nitro-unzip react-native-nitro-modules
```

### iOS

```bash
cd ios && pod install
```

### Android

No additional setup needed — the library auto-links with React Native.

## Quick Start

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

// Create an Unzip instance
const unzip = getUnzip();

// Extract a ZIP archive
const task = unzip.extract('/path/to/archive.zip', '/path/to/output');

task.onProgress((p) => {
  console.log(`${(p.progress * 100).toFixed(0)}% — ${p.extractedFiles}/${p.totalFiles} files`);
});

const result = await task.await();
console.log(`Extracted ${result.extractedFiles} files in ${result.duration}ms`);
```

The `getUnzip()` function creates an `Unzip` factory instance. From there you can create extraction tasks, compression tasks, and more. Each task is an independent, observable, and cancellable operation.

## Next Steps

- [Extraction](./usage/extraction) — extracting ZIP archives with progress tracking
- [Compression](./usage/compression) — creating ZIP archives from directories
- [Password Protection](./usage/password) — working with encrypted archives
- [Cancellation](./usage/cancellation) — cancelling in-progress operations
