## 1. Build Pipeline & Submodule Update

- [ ] 1.1 Update `Vendor/libnfs` submodule to `libnfs-6.0.2` tag
- [ ] 1.2 Update `Sources/nfs/include/libnfs-private.h` from `include/libnfs-private.h` (new 6.x path)
- [ ] 1.3 Add config.h copy step to `scripts/libnfs-build` — copy cmake-generated `config.h` to `Sources/nfs/include/config.h`
- [ ] 1.4 Run `build.sh` to rebuild libnfs for all platform slices against 6.0.2
- [ ] 1.5 Run `xcframework.sh` to produce updated `Framework/Libnfs.xcframework`
- [ ] 1.6 Verify `swift build` compiles (expect errors — captured by subsequent tasks)

## 2. Remove Deleted APIs

- [ ] 2.1 Remove `setReadAhead()` and `setPageCache()` from `NFSEventLoop.swift`
- [ ] 2.2 Remove `setReadAhead()` and `setPageCache()` from `NFSContext.swift`
- [ ] 2.3 Remove `readAhead`, `pageCachePages`, `pageCacheTTL` parameters from `NFSClient.configurePerformance()`
- [ ] 2.4 Update `PerformanceTuningTests.swift` — remove tests referencing pagecache/readahead APIs
- [ ] 2.5 Update `NFSKitTests.swift` — remove `configurePerformance` calls using removed parameters
- [ ] 2.6 Update `NFSEventLoopTests.swift` — remove any references to removed APIs

## 3. Fix Type Changes (uint64_t → size_t)

- [ ] 3.1 Change `NFSEventLoop.setReadMax(_ bytes: UInt64)` to `setReadMax(_ bytes: Int)`
- [ ] 3.2 Change `NFSContext.setReadMax(_ bytes: UInt64)` to `setReadMax(_ bytes: Int)`
- [ ] 3.3 Change `NFSClient.configurePerformance(readMax: UInt64?)` to `readMax: Int?`
- [ ] 3.4 Update all call sites and tests for the type change
- [ ] 3.5 Verify `swift build` compiles cleanly

## 4. Zero-Copy Reads — ReadBuffer

- [ ] 4.1 Write `ReadBufferTests.swift` — tests for allocation, `disown()`, deallocation, and `@unchecked Sendable` conformance
- [ ] 4.2 Create `ReadBuffer.swift` — ARC-managed unsafe pointer wrapper with `pointer`, `size`, `isOwned`, `disown()`, and `deinit` deallocation
- [ ] 4.3 Verify ReadBuffer tests pass

## 5. Zero-Copy Reads — Event Loop Integration

- [ ] 5.1 Write tests for zero-copy read behavior — verify `readFile` returns Data from pre-allocated buffer, not from callback dataPtr
- [ ] 5.2 Update `NFSEventLoop.readFile()` — allocate `ReadBuffer`, pass to `nfs_read_async(ctx, fh, buf, count, cb, priv)`, construct `Data(bytesNoCopy:)` in dataHandler
- [ ] 5.3 Update `NFSEventLoop.preadFile()` — same pattern with `nfs_pread_async(ctx, fh, buf, count, offset, cb, priv)`
- [ ] 5.4 Update `NFSEventLoop.writeFile()` — reorder params to `nfs_write_async(ctx, fh, buf, count, cb, priv)`
- [ ] 5.5 Update `NFSEventLoop.pwriteFile()` — reorder params to `nfs_pwrite_async(ctx, fh, buf, count, offset, cb, priv)`
- [ ] 5.6 Verify all existing event loop tests pass with updated call signatures

## 6. Bulk Transfer Buffers

- [ ] 6.1 Write tests for `OperationBatch` buffer-slice mode — create batch with pre-allocated buffer, record slice completion, verify `assembleData()` returns wrapped buffer
- [ ] 6.2 Add optional buffer-slice tracking to `OperationBatch` — `init(batchID:totalChunks:buffer:chunkSize:)`, `recordSliceCompletion(index:bytesWritten:)`, updated `assembleData()`
- [ ] 6.3 Verify legacy `OperationBatch` mode (per-chunk Data) still passes all existing tests
- [ ] 6.4 Write tests for `NFSClient.contents(atPath:)` with pre-allocated buffer — verify single allocation, pipelined pread calls, zero-copy result
- [ ] 6.5 Update `NFSClient.contents(atPath:)` — pre-allocate contiguous buffer (capped at 64MB), issue pipelined `preadFile` calls into buffer slices, wrap result with `Data(bytesNoCopy:)`
- [ ] 6.6 Use `nfs_get_readmax()` for chunk size instead of hardcoded 1MB
- [ ] 6.7 Verify bulk transfer tests pass

## 7. NFS Security

- [ ] 7.1 Write `NFSSecurityTests.swift` — test enum cases, mapping to C values, pre-connect enforcement
- [ ] 7.2 Create `NFSSecurity.swift` — `Sendable` enum with `.system`, `.kerberos5`, `.kerberos5i`, `.kerberos5p`
- [ ] 7.3 Add `setSecurity()` to `NFSEventLoop` — calls `nfs_set_security()` pre-connect, throws post-connect
- [ ] 7.4 Add `setSecurity(_ security: NFSSecurity)` to `NFSClient` public API
- [ ] 7.5 Verify security tests pass

## 8. RPC Diagnostics

- [ ] 8.1 Write `NFSStatsTests.swift` — test struct fields, snapshot behavior
- [ ] 8.2 Create `NFSStats.swift` — `Sendable` struct mapping all 7 `rpc_stats` fields
- [ ] 8.3 Add `stats()` to `NFSEventLoop` — queries `rpc_get_stats()` on the serial queue
- [ ] 8.4 Add `stats() async throws -> NFSStats` to `NFSClient` public API
- [ ] 8.5 Add `serverAddress` async property to `NFSClient` — calls `nfs_get_server_address()` through event loop
- [ ] 8.6 Add log handler support to `NFSEventLoop` — `setLogHandler()`, C callback via `rpc_set_log_cb()`, forward to Swift closure
- [ ] 8.7 Verify diagnostics tests pass

## 9. Extended Performance Tuning

- [ ] 9.1 Write tests for new `configurePerformance` parameters — `writeMax`, `retransmissions`, `timeout`
- [ ] 9.2 Add `setWriteMax(_ bytes: Int)` to `NFSEventLoop` — calls `nfs_set_writemax()`
- [ ] 9.3 Add `setRetransmissions(_ count: Int32)` to `NFSEventLoop` — calls `nfs_set_retrans()`
- [ ] 9.4 Add `setTimeout(_ milliseconds: Int32)` to `NFSEventLoop` — calls `nfs_set_timeout()`
- [ ] 9.5 Update `NFSClient.configurePerformance()` signature to include `writeMax`, `retransmissions`, `timeout`
- [ ] 9.6 Update `PerformanceTuningTests.swift` with new parameter tests
- [ ] 9.7 Verify all performance tuning tests pass

## 10. Final Verification

- [ ] 10.1 Run full `swift build` — zero warnings, zero errors
- [ ] 10.2 Run full `swift test` — all tests pass
- [ ] 10.3 Verify no references to removed C APIs (`nfs_set_pagecache`, `nfs_set_readahead`, `nfs_create`, etc.) in `Sources/NFSKit/`
- [ ] 10.4 Verify strict concurrency compliance — no `Sendable` warnings
