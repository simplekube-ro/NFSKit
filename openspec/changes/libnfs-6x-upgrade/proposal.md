## Why

NFSKit vendors libnfs at commit 465a12d (post-5.0.2), which is 210 commits and 3 major releases behind the current libnfs 6.0.2. The 6.x line introduces zero-copy reads (caller-provided buffers), removes the built-in page cache, reorders read/write function signatures, and adds security features (Kerberos, TLS). Upgrading unlocks significant performance gains — eliminating per-read memory copies, raising max transfer size from 1MB to 4MB, and enabling pipelined reads into pre-allocated contiguous buffers. The existing pipelining architecture is already designed for this; libnfs 6.x provides the missing C-level support.

## What Changes

- **BREAKING**: Update libnfs submodule from 5.0.2+84 to 6.0.2 — all read/write async function signatures change (parameter reorder, `uint64_t` → `size_t`, caller-provided read buffers)
- **BREAKING**: Remove `readAhead`, `pageCachePages`, `pageCacheTTL` parameters from `NFSClient.configurePerformance()` and corresponding methods in `NFSEventLoop`/`NFSContext` — these APIs no longer exist in libnfs 6.x
- Implement zero-copy reads using ARC-managed buffer wrapper (`ReadBuffer`) that pre-allocates memory, passes it to libnfs, and transfers ownership to `Data(bytesNoCopy:)` — eliminates all intermediate copies
- Redesign `OperationBatch` to support pre-allocated contiguous buffers for bulk file reads — each chunk read fills a slice of a single buffer, removing the reassembly copy step
- Add `NFSSecurity` enum and `NFSClient.setSecurity()` for Kerberos 5 authentication modes (krb5, krb5i, krb5p)
- Add `NFSStats` struct and `NFSClient.stats()` for runtime RPC diagnostics (requests sent, responses received, timeouts, retransmissions, reconnects)
- Add `NFSClient.serverAddress` property exposing the connected server address
- Add logging callback support in `NFSEventLoop` routing libnfs internal logs to a Swift handler
- Extend `configurePerformance()` with `writeMax`, `retransmissions`, and `timeout` parameters
- Auto-generate `Sources/nfs/include/config.h` from cmake output in `build.sh` instead of maintaining a stale hand-written copy (currently declares "libnfs 4.0.0")
- Update `Sources/nfs/include/libnfs-private.h` to new include path (`include/libnfs-private.h` in 6.x, was `include/nfsc/libnfs-private.h`)

## Capabilities

### New Capabilities
- `zero-copy-reads`: ARC-managed read buffer strategy that eliminates memory copies on the read path — pre-allocate, fill in-place via libnfs, transfer ownership to Data
- `bulk-transfer-buffers`: Pre-allocated contiguous buffer for pipelined bulk file reads — chunks fill slices of a single buffer, no reassembly copies
- `nfs-security`: Kerberos 5 authentication support (krb5, krb5i, krb5p) via libnfs 6.x security API
- `rpc-diagnostics`: Runtime RPC statistics and logging callback support for observability
- `build-pipeline-config`: Auto-generated config.h and updated private header management for libnfs 6.x

### Modified Capabilities
<!-- No existing specs to modify — this is the first spec-driven change -->

## Impact

- **Source files modified**: `NFSEventLoop.swift` (read/write calls, buffer management, removed APIs, new features), `NFSClient.swift` (public API surface changes), `NFSContext.swift` (removed pagecache/readahead APIs, type changes), `OperationBatch.swift` (buffer-aware chunk tracking)
- **Source files created**: `ReadBuffer.swift`, `NFSSecurity.swift`, `NFSStats.swift`
- **C bridge**: `Sources/nfs/include/config.h` (regenerated), `Sources/nfs/include/libnfs-private.h` (updated from new path)
- **Build scripts**: `build.sh` (config.h copy step), `scripts/libnfs-build` (post-build config extraction)
- **XCFramework**: Full rebuild required for all 7 platform slices against libnfs 6.0.2
- **Tests**: `PerformanceTuningTests`, `NFSKitTests`, `NFSEventLoopTests` updated; new `ReadBufferTests`, `NFSSecurityTests`, `NFSStatsTests`
- **Public API breaking changes**: `configurePerformance()` signature changes (3 params removed, 3 added), `readMax` type `UInt64` → `Int`
