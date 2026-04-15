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

- **Fast** — ~500 files/sec (iOS), ~474 files/sec (Android) on a 350MB / 10k file archive
- **Zero bridge overhead** — progress callbacks via JSI, no serialization
- **Cancellable** — synchronous cancellation via JSI
- **Password support** — AES-256 encrypted archives (zip & unzip)
- **Zip creation** — compress directories with optional password protection
- **Concurrent operations** — multiple tasks run independently
- **Background execution** — iOS background task management

## Installation

```bash
npm install react-native-nitro-unzip react-native-nitro-modules
cd ios && pod install
```

> Requires React Native 0.75+, [Nitro Modules](https://nitro.margelo.com/) 0.34+, iOS 15.5+, and Java 17 (Android).

### iOS deployment target

The library depends on `SSZipArchive`, which requires iOS 15.5+. Ensure your app's Podfile (or Expo `Podfile.properties.json`) sets `ios.deploymentTarget` to `15.5` or higher.

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
