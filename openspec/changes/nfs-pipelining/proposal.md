## Why

NFSKit currently serializes all NFS operations — each RPC is issued, polled to completion, and only then is the next one started. On WiFi connections to NAS devices (1-20ms RTT), this creates significant idle time on the wire. A directory listing with 50 entries requires 50+ sequential round trips (~150ms), and large file transfers waste bandwidth waiting between chunks. Pipelining multiple RPCs over a single connection eliminates this latency tax.

Additionally, NFSKit targets Swift 5.9+ but uses `NSLock`/`NSRecursiveLock`/`NSCondition` for thread safety with a blocking `poll()` loop. This architecture is incompatible with Swift 6 strict concurrency — blocking the cooperative thread pool causes starvation, and the mutable C pointer state cannot satisfy `Sendable` requirements without a fundamental redesign.

## What Changes

- **Replace the blocking poll-based event loop** with a `DispatchSource`-driven event loop on a dedicated serial `DispatchQueue`. All `nfs_context*` access is confined to this queue — no locks needed.
- **Enable NFS pipelining** by decoupling RPC submission from reply waiting. Multiple `nfs_*_async` calls are issued before polling, with `nfs_queue_length()` controlling pipeline depth.
- **Adaptive pipeline depth** using AIMD (Additive Increase, Multiplicative Decrease) with independent controllers for bulk I/O (reads/writes) and metadata operations (stat/readdir/mkdir).
- **Continuation-based async API** replacing the current `completionHandler` pattern. Callers suspend via `withCheckedThrowingContinuation` while the event loop services RPCs.
- **Batch cancellation** for pipelined operations. When one operation in a group fails, remaining queued operations are dropped and in-flight operations are discarded on callback arrival. Integrates with Swift `Task` cancellation via `withTaskCancellationHandler`.
- **BREAKING**: `NFSFileHandle` changes from a direct C pointer wrapper to a token-based handle. The event loop owns all `nfsfh*` pointers; callers hold opaque `Sendable` handle IDs.
- **BREAKING**: `NFSClient` becomes a non-actor `Sendable` final class. The callback-based public API (`completionHandler` overloads) is replaced with `async throws` methods.

## Capabilities

### New Capabilities
- `event-loop`: DispatchSource-driven event loop that owns the nfs_context, manages DispatchSources for I/O readiness, and serializes all C-level operations on a dedicated queue
- `pipelining`: Pipeline controller that manages in-flight RPC batches, issues operations up to the adaptive depth limit, handles ordered reassembly of chunked transfers, and provides cooperative cancellation
- `adaptive-depth`: AIMD-based adaptive pipeline depth with slow-start phase, independent controllers for bulk vs metadata operations, and backoff on timeout/error
- `async-api`: Swift 6 strict concurrency public API surface using async/await, Sendable types, continuation bridging, and Task cancellation integration

### Modified Capabilities

## Impact

- **Sources/NFSKit/NFSContext.swift** — Replaced entirely. The blocking `async_await`/`wait_for_reply`/`withThreadSafeContext` pattern is removed in favor of the event loop submission model.
- **Sources/NFSKit/NFSClient.swift** — Major rewrite. Drops `NSLock`/`NSCondition`/`DispatchQueue` threading, removes `completionHandler` overloads, becomes a thin `Sendable` wrapper over the event loop.
- **Sources/NFSKit/NFSFileHandle.swift** — Becomes a `Sendable` token type. The `nfsfh*` pointer moves into the event loop's handle registry.
- **Sources/NFSKit/Extensions.swift** — `Optional.unwrap()` and POSIX error helpers remain. Stream utilities may change.
- **Public API** — Breaking changes to all public method signatures (callback → async). Consumers must update call sites.
- **Swift version** — Minimum Swift version may increase to 5.9+ (already the case) or 6.0 depending on strict concurrency feature availability.
- **Dependencies** — No new external dependencies. Continues using libnfs XCFramework as-is. `nfs_queue_length()` is already available in the C headers.
