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
    ↓ uses
NFSContext (C context wrapper — Sources/NFSKit/NFSContext.swift)
    ↓ imports
nfs target (C bridge — Sources/nfs/)
    ↓ links
Libnfs.xcframework (pre-built binary — Framework/)
```

### Key Files

- **NFSClient.swift** — Public API. Manages connections, file/directory CRUD, upload/download with progress tracking. Thread-safe via `NSLock`/`NSCondition` + concurrent `DispatchQueue`.
- **NFSContext.swift** — Wraps `UnsafeMutablePointer<nfs_context>`. Implements async operations using callback-based `async_await` pattern with `poll()`. Uses `NSRecursiveLock` for thread safety.
- **NFSFileHandle.swift** — File handle wrapper with read/write/seek. Uses 1MB buffer size for I/O operations.
- **NFSDirectory.swift** — Swift `Collection` conformance for directory iteration. Not thread-safe.
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

## Key Patterns

- **Async pattern**: NFSContext uses a callback-based `async_await` method that polls the NFS file descriptor for events — not Swift structured concurrency.
- **Error handling**: POSIX errno values are wrapped into Swift `Error` via `POSIXError` in Extensions.swift.
- **Memory management**: Unsafe C pointers are managed carefully with `deinit` cleanup in NFSContext. `Optional.unwrap()` throws on nil to avoid force-unwraps.
- **Progress tracking**: File transfers use Foundation `Progress` objects with cancellation callbacks.
- **Thread safety**: `NFSClient` uses `NSLock` for connection and `NSCondition` for operation counting. `NFSContext` uses `NSRecursiveLock`. `NFSDirectory` is explicitly not thread-safe.
