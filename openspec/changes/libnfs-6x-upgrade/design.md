## Context

NFSKit wraps libnfs as a pre-built XCFramework linked through a Swift C module shim. The current vendored version (5.0.2+84) uses an API where libnfs internally allocates read buffers and passes them to callbacks. The recently completed pipelining architecture (`NFSEventLoop` + `PipelineController` + `OperationBatch`) already manages concurrent NFS operations via DispatchSource — but each read still copies data twice: once from libnfs's internal buffer to `Data`, and again during reassembly.

libnfs 6.0.2 fundamentally changes the read path to caller-provided buffers, removes the built-in page cache, and adds security/diagnostic APIs. The pipelining architecture is already designed to benefit from these changes.

## Goals / Non-Goals

**Goals:**
- Upgrade libnfs to 6.0.2 and adapt all Swift call sites to the new API
- Eliminate memory copies on the read path via zero-copy buffer management
- Enable pre-allocated contiguous buffers for pipelined bulk file reads
- Expose libnfs 6.x security (Kerberos) and diagnostic (RPC stats, logging) capabilities
- Auto-generate `config.h` from cmake to prevent version drift
- Maintain Swift 6 strict concurrency compliance throughout

**Non-Goals:**
- TLS transport security (`xprtsec`) — requires linking GnuTLS, not practical for Apple platform distribution
- Vectored I/O at the RPC layer (`rpc_nfs3_readv_task` / `rpc_nfs3_writev_task`) — the high-level `nfs_pread_async` with caller buffers achieves zero-copy without dropping to the RPC layer; vectored I/O is a future optimization
- libnfs multithreading mode (`HAVE_MULTITHREADING`) — NFSKit already serializes all NFS operations on a single DispatchQueue; enabling libnfs's internal threading would conflict with this model
- NFSv4 compound operation batching — out of scope for this upgrade
- Backwards compatibility with libnfs 5.x — clean break

## Decisions

### 1. Zero-copy read buffer: ARC-managed wrapper class

**Decision**: Create a `ReadBuffer` class that allocates `UnsafeMutableRawPointer`, is captured by the read callback closure, and transfers ownership to `Data(bytesNoCopy:deallocator:)` on success or deallocates on error via `deinit`.

**Why not store buffer in CallbackData?** Adds optional fields to a type used by all operations (stat, mkdir, etc.). The closure-capture approach keeps CallbackData generic.

**Why not raw pointer with manual lifecycle?** Leaks if the error path skips the data handler. The ARC wrapper guarantees cleanup: on success, `disown()` transfers pointer ownership to Data's deallocator; on error, deinit frees the pointer.

```
ReadBuffer lifecycle:
  allocate → captured by dataHandler closure
  SUCCESS: Data(bytesNoCopy:) takes pointer, ReadBuffer.disown() prevents double-free
  ERROR:   CallbackData released → closure released → ReadBuffer.deinit → deallocate
```

### 2. Bulk transfer: pre-allocated contiguous buffer

**Decision**: For `NFSClient.contents(atPath:)`, allocate a single buffer of `fileSize` bytes, then issue pipelined `nfs_pread_async` calls where each chunk points to `buffer + (chunkIndex * chunkSize)`. When all chunks complete, wrap the entire buffer in `Data(bytesNoCopy:)`.

**Why not keep per-chunk Data reassembly?** The current `OperationBatch.assembleData()` copies all chunks into a new contiguous `Data`. With a pre-allocated buffer, there's nothing to assemble — chunks fill their slots in-place.

**Trade-off**: Pre-allocating the full file size uses more peak memory upfront, but total memory usage is lower (1x file size vs ~3x with copies). For streaming/unknown-size reads, fall back to per-chunk allocation.

### 3. OperationBatch evolution: buffer-slice tracking

**Decision**: Extend `OperationBatch` with an optional `ManagedBuffer` reference and per-chunk offset/length tracking instead of storing `Data` per chunk. `recordChunkCompletion` records that a slice was filled (by offset) rather than storing copied data. `assembleData()` becomes a no-op when using a pre-allocated buffer — just wrap the whole thing.

### 4. Removed APIs: hard delete, no deprecation

**Decision**: Remove `readAhead`, `pageCachePages`, `pageCacheTTL` from the public API entirely rather than marking deprecated.

**Why**: The pipelining rewrite already broke the entire public API surface. There are no external consumers to protect. Silent no-ops are dishonest — they'd let callers think they're tuning performance when the underlying capability doesn't exist.

### 5. Security API: Swift enum mapping

**Decision**: Map `enum rpc_sec` to a Swift `NFSSecurity` enum with cases `.system`, `.kerberos5`, `.kerberos5i`, `.kerberos5p`. Called via `nfs_set_security()` pre-connect.

**Why enum over string-based configuration?** Type safety, discoverability, and the set of options is fixed by the NFS protocol.

### 6. RPC stats: snapshot struct

**Decision**: Map `struct rpc_stats` to a Swift `NFSStats` struct. Queried via `rpc_get_stats()` through the event loop's queue to maintain thread safety. Returns a snapshot, not a live view.

**Why not use the per-PDU stats callback?** The per-PDU callback (`rpc_set_stats_cb`) fires on every RPC call/response, which would require careful Sendable handling and adds overhead. The snapshot API (`rpc_get_stats()`) is simpler and sufficient for diagnostics.

### 7. Logging: callback routed through event loop

**Decision**: Set `rpc_set_log_cb()` during context creation. The C callback posts to the event loop's queue, which forwards to a user-provided Swift closure. Debug level controlled via `nfs_set_debug()`.

### 8. config.h: cmake-generated, copied post-build

**Decision**: After the first platform/arch cmake build in `build.sh`, copy the generated `config.h` to `Sources/nfs/include/config.h`. The cmake template already handles platform detection correctly.

**Why not generate per-platform?** All Apple SDK slices produce identical config.h values (the only difference, `HAVE_FORK=0` on tvOS, is already handled via CFLAGS, not config.h). One config.h works for all targets.

## Risks / Trade-offs

**[Pre-allocated buffer for large files may cause memory pressure on constrained devices]** → Cap the pre-allocation at a configurable maximum (e.g., 64MB). Files larger than the cap use chunked allocation with per-chunk `ReadBuffer` instances. The pipeline still operates — just with individual zero-copy buffers per chunk rather than one contiguous buffer.

**[Private header struct layout changes between releases]** → NFSKit doesn't access private struct fields from Swift (verified). The private header is only needed for C compilation of the shim module. Risk is low but should be verified at build time.

**[Read callback contract change (data pointer is NULL in 6.x)]** → The `nfsCallback` handler already checks `dataPtr` before using it. For reads, the `dataHandler` closure now ignores `dataPtr` and reads from the captured `ReadBuffer` instead. This is safe because the buffer is guaranteed to be filled by the time the callback fires.

**[nfs_set_readmax type changes from UInt64 to size_t]** → On 64-bit Apple platforms, `size_t` maps to `UInt` (not `UInt64`). Swift treats these as different types. Change internal APIs to use `Int` (Swift's native integer) and cast at the C boundary.

**[XCFramework rebuild required]** → The build pipeline is already automated. Main risk is build environment drift (Xcode version, SDK paths). Document the build environment requirements.
