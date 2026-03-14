# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NFSKit is a Swift wrapper around [libnfs](https://github.com/sahlberg/libnfs) providing NFS client functionality for Apple platforms. Architecture inspired by [AMSMB2](https://github.com/amosavian/AMSMB2).

**Licensing**: NFSKit source is MIT, but libnfs is LGPL v2.1.

## Build & Test Commands

```bash
# Build the Swift package
swift build

# Run tests (minimal test suite — requires NFS server for real testing)
swift test

# Run integration tests (requires Docker)
docker compose -f test-fixtures/docker-compose.yml up -d
swift test --filter IntegrationTests
docker compose -f test-fixtures/docker-compose.yml down -v

# Or use the integration test script (handles Docker lifecycle automatically)
./scripts/test-integration.sh

# Rebuild the libnfs XCFramework from source (requires Homebrew, automake, cmake)
./build.sh                          # Build libnfs for all platforms
./build.sh -p "macos ios" -a arm64  # Build for specific platforms/archs
./build.sh -d                       # Debug build
./xcframework.sh                    # Create XCFramework from built libraries
```

## Architecture

### Layer Stack

```
NFSClient (public API — Sources/NFSKit/NFSClient.swift)
    ↓ delegates to
NFSEventLoop (event loop — Sources/NFSKit/NFSEventLoop.swift)
    ↓ imports
nfs target (C bridge — Sources/nfs/)
    ↓ links
Libnfs.xcframework (pre-built binary — Framework/)
```

### Key Files

- **NFSClient.swift** — Public API. Manages connections, file/directory CRUD, upload/download with progress. Sendable with immutable properties; delegates all work to NFSEventLoop.
- **NFSEventLoop.swift** — Core event loop. Owns `nfs_context*`, manages DispatchSources for I/O on a serial queue, maintains a continuation registry, and routes operations through an adaptive pipeline.
- **PipelineController.swift** — AIMD congestion control for adaptive pipeline depth.
- **OperationType.swift** — Classifies NFS operations into bulk/metadata categories for pipeline routing.
- **OperationBatch.swift** — Groups related operations with ordered reassembly.
- **ReadBuffer.swift** — ARC-managed wrapper for zero-copy read buffers from libnfs 6.x.
- **NFSSecurity.swift** — NFS authentication security mode enum.
- **NFSStats.swift** — RPC transport statistics snapshot.
- **NFSFileHandle.swift** — File handle wrapper with read/write/seek. Uses 1MB buffer size for I/O operations.
- **Extensions.swift** — POSIX error wrapping, `URLResourceKey` helpers, `Optional.unwrap()` throwing helper, stream utilities.
- **Parser.swift** — Converts C types (`statvfs`, `nfs_stat_64`, opaque pointers) to Swift types.

### C Bridge Module (`Sources/nfs/`)

The `nfs` target is a Swift-importable C module. `nfs.c` is an empty marker file; the real work is in `include/`:
- `nfs_shim.h` — aggregates libnfs headers
- `config.h` — libnfs build configuration
- `libnfs-private.h` — private libnfs types needed by the wrapper

The `cSettings` in Package.swift define compile flags (`HAVE_CONFIG_H`, `HAVE_SOCKADDR_LEN`, etc.) required by libnfs headers.

### XCFramework Build Pipeline

`build.sh` compiles libnfs from the `Vendor/libnfs` git submodule using autotools+CMake per platform/arch. `xcframework.sh` then uses `lipo` + `xcodebuild -create-xcframework` to produce `Framework/Libnfs.xcframework`.

## Platform Targets

- **Swift**: 5.9+
- **macOS**: 10.15+ (x86_64, arm64)
- **iOS**: 13.0+ (arm64)
- **tvOS**: 13.0+ (arm64)
- **iOS Simulator**: 13.0+ (x86_64, arm64)
- **tvOS Simulator**: 13.0+ (x86_64, arm64)
- **Mac Catalyst**: 13.0+ (x86_64, arm64)

## Development Rules

- **Strict TDD**: All new features and bug fixes MUST follow test-driven development. Write failing tests first, then implement the minimum code to make them pass, then refactor. Do not write implementation code without a corresponding failing test already in place.

## Key Patterns

- **Event loop**: NFSEventLoop uses DispatchSources (not Swift structured concurrency) on a serial queue. All mutable NFS state is confined to this queue.
- **Pipeline**: Operations are classified as bulk or metadata and routed through separate AIMD-controlled pipelines.
- **Callbacks**: libnfs async functions take C callbacks. NFSEventLoop wraps these with `CallbackData` objects passed via `Unmanaged` pointers, resuming `CheckedContinuation`s when complete.
- **Error handling**: POSIX errno values are wrapped into Swift `Error` via `POSIXError` in Extensions.swift.
- **Memory management**: Unsafe C pointers managed with `deinit` cleanup. `Optional.unwrap()` throws on nil. `ReadBuffer` provides ARC-managed zero-copy reads.
- **Progress tracking**: File transfers use Foundation `Progress` objects with cancellation callbacks.
- **Thread safety**: NFSClient is Sendable (immutable properties). All mutable state lives on NFSEventLoop's serial DispatchQueue. `CallbackData.resume()` includes a `dispatchPrecondition` assertion to enforce queue confinement.

## libnfs Gotchas

- **DispatchSource fd reuse**: libnfs closes and reopens sockets during multi-step connections (portmapper → mountd → nfsd). macOS may reuse the same fd number, and kqueue silently drops the old registration. DispatchSources must be unconditionally recreated after each `nfs_service`/`rpc_service` call.
- **`rpc_service` returns -1 after callback**: This is normal libnfs behavior — the connection closes after the RPC response. Always check the completion flag before checking the return value.
- **`mount_getexports_async` needs a separate `rpc_context`**: Create via `rpc_init_context()`, not `nfs_get_rpc_context(ctx)`. Using the NFS context's RPC would corrupt its connection state. See `Vendor/libnfs/examples/nfsclient-async.c` for the reference pattern.
- **RPC functions available via C bridge**: `rpc_get_fd`, `rpc_which_events`, `rpc_service`, `rpc_init_context`, `rpc_destroy_context` are all accessible through `libnfs-raw.h` (included by `nfs_shim.h`).
