## Context

NFSKit wraps libnfs to provide NFS client functionality for Apple platforms. The current architecture uses a single `nfs_context*` per connection with a blocking `poll()` loop that serializes all operations — one RPC is issued and waited on before the next can begin. Thread safety is managed via `NSRecursiveLock` on the context and `NSLock`/`NSCondition` on the client.

This design is incompatible with Swift 6 strict concurrency (blocking the cooperative thread pool, non-Sendable mutable state shared across isolation boundaries) and leaves significant performance on the table for WiFi-to-NAS workloads where round-trip latency dominates.

libnfs provides two concurrency models:
1. **Async API** (`nfs_*_async` + `poll` + `nfs_service`) — caller manages the event loop, can issue multiple RPCs before polling.
2. **MT API** (`nfs_mt_service_thread_start`) — libnfs owns a service thread, exposes only blocking sync functions.

The MT API was evaluated and rejected: blocking sync calls cannot run on Swift's cooperative thread pool without starvation risk, and the libnfs-owned pthread cannot serve as a Swift actor executor.

## Goals / Non-Goals

**Goals:**
- Enable NFS operation pipelining — multiple RPCs in-flight simultaneously over a single connection
- Full Swift 6 strict concurrency compliance with clean `Sendable` boundaries
- Adaptive pipeline depth that self-tunes for varying WiFi conditions
- Cooperative cancellation of pipelined operation batches, integrated with Swift `Task` cancellation
- Non-blocking event loop that never occupies the cooperative thread pool

**Non-Goals:**
- Multi-connection pooling (multiple `nfs_context*` to the same server) — orthogonal optimization, can be layered later
- NFSv4 compound operations — libnfs handles these internally
- Custom Swift `SerialExecutor` for the event loop — `DispatchSerialQueue` is sufficient
- Backward-compatible callback API — this is a clean break to async/await

## Decisions

### 1. DispatchSource event loop over manual poll() thread

The event loop uses `DispatchSource.makeReadSource` and `DispatchSource.makeWriteSource` on the NFS file descriptor, running on a dedicated `DispatchSerialQueue`.

**Why over manual poll() thread:** DispatchSource integrates natively with GCD — no thread lifecycle management, no manual poll timeout tuning, and the serial queue provides the isolation guarantee needed for `nfs_context*` confinement. Since NFSKit targets Apple platforms exclusively, GCD availability is guaranteed.

**Why over actor with custom executor:** An actor would add an unnecessary hop — `NFSClient` has no mutable state of its own, it just forwards to the event loop. A `Sendable` final class holding a reference to the event loop is simpler and faster.

**Alternative considered:** `RunLoop`-based event loop using `CFFileDescriptor`. Rejected because `RunLoop` requires a dedicated thread anyway and is less ergonomic than GCD for this use case.

### 2. Independent AIMD controllers for bulk vs metadata operations

Two separate pipeline depth controllers, one for bulk I/O (read/write) and one for metadata (stat/readdir/mkdir/unlink/rename). Each uses TCP-style AIMD:
- Slow start: double depth on success until reaching `ssthresh`
- Steady state: additive increase (`depth += 1/depth` per completion)
- On timeout/error: multiplicative decrease (`depth /= 2`, `ssthresh = depth/2`)
- Bounds: min=1, max=32

**Why independent:** Bulk and metadata operations have fundamentally different characteristics. Metadata RPCs are tiny and latency-bound — optimal depth is high (8-16). Bulk reads are large and bandwidth-bound — optimal depth is low (2-4) on WiFi. A shared controller would either underperform on metadata or overcommit on bulk after a metadata burst.

**Why AIMD over fixed depth:** WiFi conditions vary dramatically (1-50ms RTT, ±30ms jitter). A fixed depth that works on 5GHz close to AP will underperform on congested 2.4GHz, and vice versa. AIMD is battle-tested (TCP has used it for 30+ years) and self-corrects.

**Alternative considered:** Single shared AIMD controller with operation-weight heuristics. Rejected because a metadata burst growing the window to 16 followed by a large-file read would issue 16 × 1MB = 16MB simultaneously.

### 3. Continuation-based caller suspension

Callers use `withCheckedThrowingContinuation` combined with `withTaskCancellationHandler`. The continuation is stored in a registry on the event loop queue, keyed by operation or batch ID. The C callback (fired synchronously during `nfs_service`) resumes the continuation.

**Why over AsyncStream:** Streams add buffering complexity and backpressure semantics that don't fit the request-response model. Each NFS operation has exactly one result — a continuation is the natural primitive.

**Why checked over unsafe:** Performance difference is negligible for NFS I/O (network RTT dominates). Checked continuations catch double-resume bugs during development.

### 4. Token-based file handles

`NFSFileHandle` becomes a `Sendable` final class holding only an opaque `UInt64` identifier. The actual `nfsfh*` pointer lives in a registry (`[HandleID: UnsafeMutablePointer<nfsfh>]`) owned by the event loop. Handle operations submit through the event loop like any other operation.

**Why final class over struct:** A struct handle is trivially copyable. If two copies exist and one calls `close()`, the other holds a dangling token. A final class with `deinit` that auto-submits `nfs_close_async` provides deterministic lifetime management with reference counting.

**Why not expose nfsfh* at all:** The C pointer is not `Sendable` and must never leave the event loop queue. Exposing it, even as an opaque type, invites misuse across isolation boundaries.

### 5. Batch-based operation grouping for cancellation

A `contents(atPath:)` call creates an `OperationBatch` that groups all chunk read operations. The batch tracks state (`.active` / `.cancelled`), holds the caller's continuation, and manages ordered reassembly of chunk data via a `[Int: Data]` dictionary keyed by chunk index.

On error in any chunk: the batch transitions to `.cancelled`, the pending queue is drained, in-flight RPCs are allowed to complete (libnfs has no per-operation cancel), and their callbacks discard data. The caller's continuation is resumed with the error immediately — no waiting for in-flight stragglers.

**Why not cancel at the libnfs level:** libnfs provides no per-RPC cancel API. `rpc_error_all_pdus()` errors everything on the context (including unrelated operations). Disconnecting and reconnecting is too heavy. Cooperative cancellation at the NFSKit layer is the only viable approach.

### 6. DispatchSource fd change handling

After mount, reconnect, or auto-reconnect, `nfs_get_fd()` may return a different file descriptor. The event loop must detect this and recreate DispatchSources. Detection happens after any `nfs_service()` call by comparing `nfs_get_fd()` against the cached fd.

## Risks / Trade-offs

**[Risk] DispatchSource and nfs_which_events() mismatch** — libnfs reports desired events via `nfs_which_events()` (POLLIN/POLLOUT), but DispatchSource uses separate read/write sources. The write source must be dynamically activated/suspended based on `nfs_which_events()` after every `nfs_service()` call. If the write source is not activated when libnfs needs POLLOUT, outbound RPCs stall.
→ *Mitigation:* Check `nfs_which_events()` after every `nfs_service()` call and after every operation submission. Toggle write source accordingly.

**[Risk] Memory pressure from in-flight chunk buffers** — With pipeline depth 4-8 and 1MB chunks, up to 8MB of response data may be held in the batch's reassembly dictionary while waiting for earlier chunks. For very large files, this is bounded by the pipeline depth, not file size.
→ *Mitigation:* Pipeline depth max of 32 bounds worst case to 32MB. For typical WiFi workloads, bulk depth stabilizes at 2-4 (2-4MB). Acceptable for a NAS client.

**[Risk] Callback data pointer lifetime** — libnfs callback data pointers are only valid during the callback invocation. Data must be copied into Swift-managed memory (e.g., `Data(bytes:count:)`) before the callback returns. This is already the case in the current code, but pipelining increases the number of concurrent callbacks.
→ *Mitigation:* No change needed — existing pattern of copying to `Data` in the callback is preserved.

**[Risk] Breaking API change** — All public `completionHandler`-based methods are replaced with `async throws`. Consumers must update all call sites.
→ *Mitigation:* This is a major version bump. Document migration path. The new API is strictly simpler (no completion handler nesting).

**[Trade-off] No graceful degradation to sync** — The MT service thread approach is not offered as a fallback. If the DispatchSource approach has issues on a specific platform, there's no alternative code path.
→ *Accepted:* NFSKit targets Apple platforms exclusively where GCD and DispatchSource are stable system components.

**[Trade-off] AIMD slow start on fresh connections** — The first few operations after connect run at depth 1-2, which is suboptimal if the link is fast. Full pipeline depth takes ~4-5 successful batches to reach.
→ *Accepted:* Slow start completes within the first few hundred milliseconds. Correctness over premature optimization.
