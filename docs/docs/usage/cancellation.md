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

**0.4.0 — mid-write cancellation actually fires.** On Android, `cancel()` triggers `Thread.interrupt()` via `runInterruptible`, which unsticks an in-flight `FileChannel` write on the next syscall (not the next chunk boundary). On iOS, `Task.checkCancellation()` runs between every entry, so a cancel between entries halts immediately. In both cases the partial state is then rolled back before the promise rejects — see [Transactional behaviour](./extraction#transactional-behaviour-040).

**`cancel()` before `await()` is a no-op.** If you cancel a task you haven't `await()`'d yet, the next `await()` proceeds normally. This avoids the 0.3-era footgun where a pre-await cancel permanently poisoned the task.

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
