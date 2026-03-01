---
sidebar_position: 4
---

# Cancellation

Cancel in-progress extraction or compression operations instantly.

## Cancelling a Task

Every `UnzipTask` and `ZipTask` has a `cancel()` method:

```typescript
import { getUnzip } from 'react-native-nitro-unzip';

const unzip = getUnzip();
const task = unzip.extract('/path/to/large.zip', '/output');

// Cancel at any time
task.cancel();
```

Cancellation is **synchronous** — it happens immediately via JSI with no bridge round-trip. The `await()` promise will reject when a task is cancelled.

## Handling Cancellation

```typescript
const task = unzip.extract('/path/to/archive.zip', '/output');

try {
  const result = await task.await();
  console.log('Extraction complete:', result);
} catch (error) {
  console.log('Extraction cancelled or failed:', error);
}
```

## Safe to Call Multiple Times

`cancel()` is idempotent — calling it multiple times on the same task is safe and has no additional effect:

```typescript
task.cancel();
task.cancel(); // No-op, no error
```

## User-Initiated Cancellation

A common pattern is to wire up cancellation to a button press:

```typescript
const task = unzip.extract('/path/to/archive.zip', '/output');

task.onProgress((p) => {
  setProgress(p.progress);
});

// In your UI
const handleCancel = () => {
  task.cancel();
};

try {
  const result = await task.await();
  setStatus('complete');
} catch {
  setStatus('cancelled');
}
```
