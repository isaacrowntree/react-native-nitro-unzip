---
sidebar_position: 3
---

# Performance

react-native-nitro-unzip is designed for speed. Here's how it performs and why.

## Benchmarks

Tested on a 350MB archive with 10,432 small files (map tiles):

| Platform | Speed | Time |
|---|---|---|
| iOS (iPhone) | ~500 files/sec | ~20s |
| Android | ~474 files/sec | ~22s |

## Why It's Fast

### iOS

[SSZipArchive](https://github.com/ZipArchive/ZipArchive) uses C-based **libz** decompression with streaming extraction, avoiding memory overhead from loading the entire archive into memory.

### Android

The Android implementation uses several optimizations:

- **64KB I/O buffers** — 8x the default buffer size, reducing system call overhead
- **Batch directory creation** — creates directory trees in bulk rather than one at a time
- **Buffered streams** — wraps all I/O in buffered streams for efficient reads and writes

### Both Platforms

- **JSI callbacks** — progress updates go through JSI (JavaScript Interface), bypassing the React Native bridge entirely. No serialization or deserialization overhead.
- **Throttled updates** — progress callbacks fire at most once per second, so even archives with thousands of files don't flood the JS thread.
- **Background execution** — extraction runs on native background threads, keeping the UI responsive.

## vs react-native-zip-archive

| | react-native-nitro-unzip | react-native-zip-archive |
|---|---|---|
| Architecture | JSI (Nitro Modules) | Bridge |
| Progress callbacks | Via JSI, no serialization | Via bridge events |
| Cancellation | Synchronous | Not supported |
| Concurrent ops | Yes | Limited |
| Password support | AES-256 (zip & unzip) | Unzip only |
| Zip creation | Yes | Yes |
| New Architecture | Required | Optional |
