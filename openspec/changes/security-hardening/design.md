## Context

NFSKit wraps libnfs (a C library) with a Swift async/await API. The C-Swift boundary introduces memory safety risks that Swift's type system cannot fully enforce. A security audit identified 17 issues across four categories: unsafe memory management, missing input validation, silent error swallowing, and legacy code with known defects.

The codebase uses a serial DispatchQueue for thread safety, `Unmanaged` pointers for C callback bridging, and a type-erased `Result<Any, Error>` channel for continuation delivery. These patterns are architecturally sound but have specific gaps in error paths and edge cases.

Two legacy files — `NFSContext.swift` and `NFSDirectory.swift` — are superseded by `NFSEventLoop` and `readdirAll` respectively but remain compiled and accessible, contributing 5 of the 17 findings.

## Goals / Non-Goals

**Goals:**
- Eliminate all HIGH-severity vulnerabilities (memory leaks, crashes, use-after-free)
- Close input validation gaps that enable path traversal or integer overflow
- Make security-critical configuration failures visible to callers
- Remove legacy code that contributes known vulnerabilities
- Add defensive assertions and documentation for safety invariants
- Maintain full backward compatibility except for two methods gaining `throws`

**Non-Goals:**
- Rewriting the type-erased `Result<Any, Error>` architecture to use generics (too invasive; safe casts are sufficient)
- Adding encryption or TLS support (NFS protocol limitation; document only)
- Implementing authentication beyond what libnfs supports
- Adding fuzz testing infrastructure (future work)
- Changing the DispatchQueue-based concurrency model

## Decisions

### D1: Cleanup closure on CallbackData for write buffer lifecycle

**Decision:** Add an optional `cleanup: (() -> Void)?` field to `CallbackData`. The cleanup closure is called in *both* the success path (`dataHandler`) and the error path (`nfsCallback` when `status < 0`).

**Rationale:** The current architecture has `dataHandler` responsible for freeing write buffers, but `nfsCallback`'s error path skips `dataHandler` entirely, leaking the buffer. Rather than restructuring the callback flow (which touches every operation), adding a single cleanup hook is minimal and correct.

**Alternative considered:** Always call `dataHandler` even on error. Rejected because `dataHandler` returns a typed `Result` and many handlers assume success — passing negative status would require auditing every handler.

### D2: Safe conditional casts instead of force-casts

**Decision:** Replace `value as! T` with `guard let typedValue = value as? T else { continuation.resume(throwing: ...); return }` throughout the continuation resume path.

**Rationale:** The `Result<Any, Error>` type erasure means the compiler cannot verify type safety at the resume site. A conditional cast converts a potential crash into a recoverable `.EIO` error. The performance cost of `as?` vs `as!` is negligible (single type check).

**Alternative considered:** Rewrite the entire callback system with generic-typed continuations. Rejected as too invasive for a security fix — the type-erased design works correctly in all current code paths.

### D3: Remove NFSContext.swift and NFSDirectory.swift

**Decision:** Delete both files entirely rather than deprecating them.

**Rationale:** `NFSContext` is not used by `NFSClient` or `NFSEventLoop`. It has 5 known issues (silent catch, lock-during-poll, callback type unsafety). `NFSDirectory` is `internal` access and superseded by `readdirAll`. Keeping deprecated code compiled means it must still be maintained and audited. Clean removal eliminates 5 findings with zero consumer impact.

**Alternative considered:** Mark with `@available(*, deprecated)`. Rejected because both types are `internal` — no external consumers can reference them, so deprecation warnings would only fire internally.

### D4: Backpressure via maximum pending queue depth

**Decision:** Add a configurable `maxPendingOperations` limit (default: 4096) to `NFSEventLoop`. When the queue is full, throw `POSIXError(.ENOBUFS)`.

**Rationale:** The current unbounded `pendingOperations` array allows memory exhaustion under pathological workloads (e.g., recursive traversal of 1M files). A hard limit with a clear error is better than OOM. The default of 4096 is generous enough for any realistic workload while preventing runaway growth.

**Alternative considered:** Token-bucket or semaphore-based backpressure. Rejected as over-engineered — a simple count check is sufficient and easier to reason about.

### D5: Breaking API change for configurePerformance and setSecurity

**Decision:** Make `configurePerformance()` and `setSecurity()` throwing methods.

**Rationale:** These methods silently discard errors via `try?`. The most dangerous failure mode is `setSecurity(.kerberos5p)` silently failing, causing the connection to proceed with `AUTH_SYS` (unauthenticated). Making these throwing is a breaking change but a necessary one — silent security downgrades are unacceptable.

**Migration:** Callers must add `try` or `try?` (if they genuinely want to ignore). The behavior change is opt-in: callers who already used `try?` keep the same behavior.

### D6: Path validation strategy

**Decision:** Validate directory entry names in `removeDirectoryRecursive` by rejecting names containing `/`, or equal to `.` or `..`.

**Rationale:** Simple allowlist check catches the path traversal attack vector. NFS protocol does not allow `/` in filenames, so rejecting it is always correct. Rejecting `.` and `..` prevents parent-directory traversal.

**Alternative considered:** Canonical path resolution with prefix check. Rejected because NFS paths are server-relative and `realpath` would require an additional RPC call.

### D7: Cap readMax from server

**Decision:** In `contentsUsingPreallocatedBuffer`, cap `chunkSize` to `min(eventLoop.getReadMax(), 4 * 1024 * 1024)`.

**Rationale:** `getReadMax()` returns a server-negotiated value. A malicious server could report an absurdly large readmax causing integer overflow in `(totalBytes + chunkSize - 1) / chunkSize`. The 4 MB cap matches `NFS_MAX_XFER_SIZE` from the libnfs constants.

## Risks / Trade-offs

- **Breaking API** (`configurePerformance`, `setSecurity` now throw) → Mitigated by clear migration path; only two methods affected. Consider a semver minor bump.
- **Removing NFSContext/NFSDirectory** → Risk: unknown internal consumers. Mitigated by verifying no references exist outside the files themselves via grep.
- **maxPendingOperations limit** → Risk: legitimate high-concurrency workloads hitting the limit. Mitigated by generous default (4096) and making it configurable.
- **Cleanup closure overhead** → Risk: minor memory overhead per `CallbackData`. Mitigated by closure being optional (nil for operations without allocated buffers).
- **Safe cast overhead** → Negligible; `as?` is a single type metadata comparison.
