---
sidebar_position: 3
---

# Password Protection

Work with password-protected ZIP archives using AES-256 encryption.

## Extract a Protected Archive

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

const unzip = getUnzip();
const task = unzip.extractWithPassword(
  '/path/to/encrypted.zip',
  '/path/to/output',
  'mypassword'
);

task.onProgress((p) => {
  console.log(`${(p.progress * 100).toFixed(0)}%`);
});

const result = await task.await();
```

`extractWithPassword` works identically to `extract` but takes a third `password` parameter. Progress tracking and cancellation work the same way.

## Create a Protected Archive

```typescript
const task = unzip.zipWithPassword(
  '/path/to/folder',
  '/output/secure.zip',
  'mypassword'
);

const result = await task.await();
```

## Encryption Details

| Platform | Encryption |
|---|---|
| Android | AES-256 via [zip4j](https://github.com/srikanth-lingala/zip4j) |
| iOS | Standard ZIP encryption via [SSZipArchive](https://github.com/ZipArchive/ZipArchive) |

:::note Cross-platform compatibility
Archives created with `zipWithPassword` on one platform can be extracted with `extractWithPassword` on the other.
:::
