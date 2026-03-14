## Why

A comprehensive security review identified 17 vulnerabilities across the NFSKit codebase — 4 HIGH, 7 MEDIUM, and 6 LOW/INFO severity. The most critical class involves unsafe memory management at the Swift-C boundary (write buffer leaks, force-cast crashes, use-after-free fragility), followed by input validation gaps that enable path traversal attacks, and silent error swallowing that can mask security configuration failures. These issues expose consumers to denial-of-service via memory exhaustion, crashes from adversarial NFS servers, and potential security downgrades where connections proceed unencrypted without caller awareness.

## What Changes

- **Fix write buffer memory leak** in `writeFile`/`pwriteFile` — buffers are never freed when libnfs callbacks fire with error status (HIGH-3)
- **Replace force-cast `as! T`** with safe conditional casts throughout the continuation resume path to convert crashes into recoverable errors (HIGH-2)
- **Harden parallel pread buffer ownership** — add explicit lifetime guarantees and document the ownership transfer invariant (HIGH-1)
- **Fix nil pointer dereference** in `NFSDirectory.subscript` and evaluate removal of the legacy class (HIGH-4)
- **Add path component validation** in `removeDirectoryRecursive` to prevent `../` traversal attacks (MED-3)
- **Cap server-reported `readMax`** to prevent integer overflow in chunk size calculations (MED-1)
- **Add backpressure** to the `pendingOperations` queue to prevent unbounded memory growth (MED-2)
- **Make security/performance configuration throwing** — replace `try?` with proper error propagation so callers know when settings fail (MED-7)
- **Document queue-confinement invariants** and add debug assertions for `CallbackData.hasResumed` (MED-6)
- **Remove or deprecate `NFSContext`** — the legacy wrapper has silent error swallowing (MED-4) and lock-during-poll deadlock (MED-5)
- **Fix timestamp precision loss** in `Date(timespec:)` (LOW-2)
- **Improve error code mapping** — replace `ECANCELED` fallback with `EIO` and preserve original code (LOW-1)
- **Reduce C bridge attack surface** — minimize exposed raw protocol headers in `nfs_shim.h` (LOW-3)
- **Fix `HAVE_SO_BINDTODEVICE`** config for Darwin platforms (LOW-4)
- **Add typed file open flags** validation (LOW-5)
- **Document `AUTH_SYS` security limitations** in public API (INFO-1)

## Capabilities

### New Capabilities
- `memory-safety`: Fixes for unsafe memory management at the Swift-C boundary — write buffer lifecycle, force-cast elimination, buffer ownership hardening, nil pointer guards
- `input-validation`: Path traversal prevention, server-reported value capping, file open flag validation, queue backpressure limits
- `error-propagation`: Replace silent error swallowing with proper throwing APIs, improve error code mapping, add queue-confinement assertions
- `legacy-cleanup`: Deprecate/remove `NFSContext` and `NFSDirectory`, fix C bridge config issues, reduce header attack surface

### Modified Capabilities
<!-- No existing specs to modify -->

## Impact

- **NFSClient.swift** — `configurePerformance()` and `setSecurity()` become throwing (**BREAKING**), `removeDirectoryRecursive` adds validation, `contentsUsingPreallocatedBuffer` caps chunk size
- **NFSEventLoop.swift** — `CallbackData` gets cleanup closures, `nfsCallback` error path calls cleanup, force-casts replaced with safe casts, `pendingOperations` gets max depth, debug assertions added
- **NFSDirectory.swift** — Deprecated or removed entirely
- **NFSContext.swift** — Deprecated or removed entirely
- **Extensions.swift** — `POSIXErrorCode.init` fallback changed from `.ECANCELED` to `.EIO`, `Date(timespec:)` precision fixed
- **Sources/nfs/include/** — `nfs_shim.h` minimized, `config.h` `HAVE_SO_BINDTODEVICE` removed
- **Public API** — Two methods gain `throws` (**BREAKING**); all other changes are internal
