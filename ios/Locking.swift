import Foundation

extension NSLocking {
  /// Scoped locking that is callable from an `async` function.
  ///
  /// Swift 6 marks `NSLocking.lock()` / `unlock()` unavailable from
  /// asynchronous contexts, because a lock held across a suspension point can
  /// be released on a different thread than acquired it. Routing through a
  /// *synchronous* generic makes that impossible by construction — `body`
  /// cannot contain an `await` — so the critical section is provably
  /// suspension-free and the compiler is satisfied.
  ///
  /// `NSLocking.withLock` in the standard library would do the same job but is
  /// iOS 16+, and this pod still supports 15.5.
  @inline(__always)
  func withLockSync<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

/// Thread-safe throttle for progress callbacks fired from library-owned
/// worker threads.
///
/// Replaces a captured `var lastProgressUpdate` that was read and written from
/// SSZipArchive's progress handler — a data race Swift 6 rejects. Folding the
/// compare and the store into one locked operation also removes a
/// check-then-act window in which two threads could both decide to emit.
final class ProgressThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private var lastUpdate: Date
  private let interval: TimeInterval

  init(interval: TimeInterval, start: Date = Date()) {
    self.interval = interval
    self.lastUpdate = start
  }

  /// Returns `true` at most once per `interval`, unless `force` is set (used
  /// so the first and last entry always emit).
  func shouldEmit(now: Date = Date(), force: Bool = false) -> Bool {
    lock.withLockSync {
      guard force || now.timeIntervalSince(lastUpdate) >= interval else {
        return false
      }
      lastUpdate = now
      return true
    }
  }
}

/// A single value guarded by a lock, for state shared between an `async`
/// function and a callback that a C/Objective-C library invokes on its own
/// worker thread.
///
/// Used for the extracted-file counter, which SSZipArchive's progress handler
/// writes and the enclosing function reads once the operation completes.
/// The hand-off happened to work in practice but was never synchronised.
final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    self.storage = value
  }

  var value: Value {
    lock.withLockSync { storage }
  }

  func set(_ newValue: Value) {
    lock.withLockSync { storage = newValue }
  }
}
