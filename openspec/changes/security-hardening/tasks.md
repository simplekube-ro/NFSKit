## 1. Memory Safety (HIGH priority)

- [x] 1.1 Add optional `cleanup` closure to `CallbackData` in `NFSEventLoop.swift` — invoked on both success and error paths
- [x] 1.2 Update `nfsCallback` error path (`status < 0`) to call `cbData.cleanup?()` before resuming continuation with failure
- [x] 1.3 Update `writeFile` to set `callbackData.cleanup = { writeBuf.deallocate() }` and remove `defer { writeBuf.deallocate() }` from `dataHandler`
- [x] 1.4 Update `pwriteFile` to set `callbackData.cleanup = { writeBuf.deallocate() }` and remove `defer { writeBuf.deallocate() }` from `dataHandler`
- [x] 1.5 Replace all `value as! T` force-casts with `guard let typedValue = value as? T` in continuation resume sites throughout `NFSEventLoop.swift` — resume with `POSIXError(.EIO)` on mismatch
- [x] 1.6 Add ownership transfer invariant comment to `contentsUsingPreallocatedBuffer` in `NFSClient.swift` documenting that `disown()` and `Data(bytesNoCopy:)` must be adjacent

## 2. Input Validation (MEDIUM priority)

- [x] 2.1 Add path component validation in `removeDirectoryRecursive` — skip entries where `name` contains `/` or equals `.`/`..`
- [x] 2.2 Cap `chunkSize` in `contentsUsingPreallocatedBuffer` to `min(eventLoop.getReadMax(), 4 * 1024 * 1024)`
- [x] 2.3 Add `maxPendingOperations` property to `NFSEventLoop` with default value of 4096
- [x] 2.4 Add queue depth check in the pending operation enqueue path — throw `POSIXError(.ENOBUFS)` when at capacity

## 3. Error Propagation (MEDIUM priority)

- [x] 3.1 Change `setSecurity(_ security:)` in `NFSClient.swift` from non-throwing to `throws` — remove `try?` wrapper
- [x] 3.2 Change `configurePerformance(...)` in `NFSClient.swift` from non-throwing to `throws` — remove all `try?` wrappers
- [x] 3.3 Update `POSIXErrorCode.init(_ code: Int32)` fallback from `.ECANCELED` to `.EIO` in `Extensions.swift`
- [x] 3.4 Fix `Date(timespec:)` to use `TimeInterval(timespec.tv_nsec) / 1_000_000_000.0` instead of integer division in `Extensions.swift`
- [x] 3.5 Add `dispatchPrecondition(condition: .onQueue(queue))` assertion to `CallbackData.resume()` — requires passing queue reference to `CallbackData`

## 4. Legacy Cleanup

- [x] 4.1 Verify no references to `NFSContext` exist outside `NFSContext.swift` (grep codebase)
- [x] 4.2 Delete `Sources/NFSKit/NFSContext.swift`
- [x] 4.3 Verify no references to `NFSDirectory` exist outside `NFSDirectory.swift` (grep codebase)
- [x] 4.4 Delete `Sources/NFSKit/NFSDirectory.swift`
- [x] 4.5 Audit `nfs_shim.h` — identify which raw protocol headers are actually used by Swift source files
- [x] 4.6 Remove unused raw protocol headers from `nfs_shim.h` (keep `libnfs.h` and `libnfs-raw.h`)
- [x] 4.7 Remove `#define HAVE_SO_BINDTODEVICE` from `Sources/nfs/include/config.h`

## 5. Documentation

- [x] 5.1 Add security warning doc comment to `NFSSecurity` enum documenting `AUTH_SYS` limitations
- [x] 5.2 Add security note to `NFSClient.connect` doc comment recommending Kerberos for sensitive deployments
- [x] 5.3 Document supported `O_*` flag combinations on `openFile(atPath:flags:)` doc comment

## 6. Verification

- [x] 6.1 Run `swift build` — verify clean compilation with no errors or new warnings
- [x] 6.2 Run `swift test` — verify existing tests pass (133 passed, 0 failures, 32 skipped)
- [x] 6.3 Run integration tests if Docker is available — `./scripts/test-integration.sh` (blocked by sandbox-exec OS restriction; unit tests pass with --disable-sandbox)
