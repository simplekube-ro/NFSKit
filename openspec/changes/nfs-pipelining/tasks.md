## 1. Event Loop Foundation

- [x] 1.1 Create `NFSEventLoop` class (`@unchecked Sendable`, `final`) with a dedicated `DispatchSerialQueue`, `nfs_context*` ownership, and lifecycle methods (start/stop)
- [x] 1.2 Implement DispatchSource setup: `makeReadSource` for POLLIN, dynamic `makeWriteSource` for POLLOUT based on `nfs_which_events()` state
- [x] 1.3 Implement `nfs_service()` dispatch in read/write source event handlers, with `nfs_which_events()` check and write source toggle after each service call
- [x] 1.4 Implement file descriptor change detection: compare `nfs_get_fd()` after each `nfs_service()`, recreate DispatchSources on mismatch
- [x] 1.5 Implement event loop shutdown: cancel DispatchSources, resume all pending continuations with disconnection error, drain operation queue

## 2. Continuation Registry and Operation Submission

- [x] 2.1 Define `OperationID` type and `ContinuationRegistry` that maps `OperationID` to `CheckedContinuation<T, Error>`
- [x] 2.2 Implement `submit()` method: enqueue operation on the serial queue, store continuation in registry, call `nfs_*_async`, update DispatchSources
- [x] 2.3 Implement C callback handler that looks up continuation by ID, copies data into Swift-managed memory, resumes continuation, and removes registry entry
- [x] 2.4 Wire up all existing NFS operations (stat, statvfs, readlink, mkdir, rmdir, unlink, rename, truncate, open, close, read, pread, write, pwrite, fsync, opendir, mount, umount) through the submit path

## 3. Adaptive Pipeline Depth Controller

- [x] 3.1 Create `PipelineController` struct with AIMD state: `depth` (Double), `ssthresh`, `phase` (slowStart/steady), `minDepth`, `maxDepth`
- [x] 3.2 Implement slow-start logic: double depth on success until reaching ssthresh, then transition to steady state
- [x] 3.3 Implement steady-state AIMD: additive increase (`depth += 1/depth`) on success, multiplicative decrease (`depth /= 2`, `ssthresh = depth/2`) on timeout or error
- [x] 3.4 Implement depth bounds clamping (min=1, max=32) and initial values (depth=2, ssthresh=16)
- [x] 3.5 Create two controller instances in the event loop: `bulkController` and `metadataController`
- [x] 3.6 Implement operation classification: read/pread/write/pwrite → bulk, all others → metadata
- [x] 3.7 Implement pipeline slot management: check `effectiveDepth - inFlightCount` for available slots, issue pending operations when slots free up after completions

## 4. Operation Batching and Cancellation

- [x] 4.1 Define `OperationBatch` class with state (`.active`/`.cancelled`), pending queue, in-flight set, completion dictionary `[Int: Data]`, and caller continuation
- [x] 4.2 Implement batch creation for chunked file transfers: split file into chunks, create operation entries with chunk indices
- [x] 4.3 Implement ordered data reassembly: on chunk completion, store in `completedChunks[index]`, when all complete assemble contiguous Data
- [x] 4.4 Implement batch cancellation on error: transition to `.cancelled`, drain pending queue, resume caller continuation with error, discard subsequent in-flight callbacks
- [x] 4.5 Implement `withTaskCancellationHandler` integration: cancellation handler submits `cancelBatch(batchId)` to the event loop queue
- [x] 4.6 Implement single-operation batches for standalone operations (stat, mkdir, etc.) that bypass chunking

## 5. Token-Based File Handles

- [x] 5.1 Create `NFSFileHandle` as a `Sendable` final class with an opaque `HandleID` (UInt64), no C pointer exposure
- [x] 5.2 Implement handle registry in the event loop: `[HandleID: UnsafeMutablePointer<nfsfh>]` with open/close lifecycle
- [x] 5.3 Implement handle open: submit `nfs_open_async` through event loop, register returned `nfsfh*`, return `NFSFileHandle` token to caller
- [x] 5.4 Implement handle close: submit `nfs_close_async`, remove registry entry. Wire into `NFSFileHandle.deinit` for automatic cleanup
- [x] 5.5 Implement handle validation: operations on a closed/unknown handle ID throw an error before issuing RPCs

## 6. Public API Rewrite

- [x] 6.1 Rewrite `NFSClient` as a `Sendable` final class: remove `NSLock`/`NSCondition`/`operationCount`, hold only `NFSEventLoop` reference and immutable config
- [x] 6.2 Rewrite `connect(export:)` and `disconnect()` as `async throws`
- [x] 6.3 Rewrite file operations (`contents(atPath:)`, `write(to:)`, `copyContentsOfFile`) as `async throws` using batch-based pipelined reads/writes
- [x] 6.4 Rewrite metadata operations (`listDirectory`, `stat`, `removeItem`, `moveItem`, `truncateFile`, `createDirectory`) as `async throws`
- [x] 6.5 Implement progress reporting for file transfers via `AsyncStream<Progress>` or async sequence
- [x] 6.6 Ensure `configurePerformance()` works pre-connect by submitting config operations through the event loop before DispatchSources are created
- [x] 6.7 Remove old `completionHandler`-based overloads, `with(completionHandler:)` helper, and `queue(_:)` dispatch wrapper

## 7. Internal Cleanup

- [x] 7.1 Remove `NFSContext.swift` blocking `async_await`/`wait_for_reply`/`withThreadSafeContext` pattern (replaced by event loop) — kept for legacy test compat; deprecated
- [x] 7.2 Remove old `NFSFileHandle.swift` direct C pointer wrapper (replaced by token handle)
- [x] 7.3 Update `NFSDirectory` to work through the event loop (or replace with async directory iteration) — replaced by `readdirAll` in event loop; old file kept for legacy compat
- [x] 7.4 Update `Extensions.swift`: keep `POSIXError` helpers and `Optional.unwrap()`, remove stream utilities if no longer needed — kept as-is, all helpers still used

## 8. Tests

- [x] 8.1 Unit test `PipelineController`: slow start, steady-state AIMD, timeout decrease, bounds clamping, reset on reconnect
- [x] 8.2 Unit test `OperationBatch`: creation, ordered reassembly, cancellation on error, cancellation before issue, single-op batch
- [x] 8.3 Unit test operation classification: verify bulk vs metadata routing for all operation types
- [x] 8.4 Unit test `NFSFileHandle` token: open/close lifecycle, double-close handling, operation on closed handle
- [x] 8.5 Unit test event loop lifecycle: start, stop, pending continuation error on shutdown
- [x] 8.6 Integration test: verify `NFSClient` compiles with strict concurrency checking enabled (`-strict-concurrency=complete`)
- [x] 8.7 Update existing `PerformanceTuningTests` to use new async API
