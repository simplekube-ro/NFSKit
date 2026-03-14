# NFSKit

Swift NFS client for Apple platforms, built on [libnfs](https://github.com/sahlberg/libnfs).

Forked from [alexiscn/NFSKit](https://github.com/alexiscn/NFSKit) and substantially rewritten with a new event loop architecture, adaptive pipelining, libnfs 6.x support, and security hardening.

![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20Catalyst-blue.svg)
![License](https://img.shields.io/badge/License-MIT%20%2B%20LGPL%20v2.1-green.svg)

## What's Different from the Original

The [original NFSKit](https://github.com/alexiscn/NFSKit) by [@alexiscn](https://github.com/alexiscn) provided a synchronous NFS wrapper using `poll()` loops and `NSRecursiveLock`. This fork replaces the internals while preserving the public API shape:

| Area | Original | This Fork |
|------|----------|-----------|
| **Event loop** | Blocking `poll()` with `NSRecursiveLock` | Non-blocking `DispatchSource` on a serial queue |
| **Concurrency** | Basic async/await wrappers | Full `Sendable` conformance, `CheckedContinuation` throughout |
| **libnfs version** | 4.x | 6.0.2 — zero-copy reads, `pread`/`pwrite`, RPC stats |
| **Pipelining** | Sequential (one RPC at a time) | Adaptive AIMD congestion control (up to 32 concurrent RPCs) |
| **Reads** | Copy-based chunked reads | Zero-copy pre-allocated buffer path for files up to 64 MB |
| **Security** | No security API | `NFSSecurity` enum with Kerberos 5/5i/5p support |
| **Error handling** | Silent `try?` on config, `ECANCELED` fallback | Throwing APIs, proper error propagation, `EIO` fallback |
| **Memory safety** | `as!` force-casts, leaked write buffers on error | Safe `as?` casts, cleanup closures, queue-confinement assertions |
| **Thread safety** | `NFSDirectory` not thread-safe, no runtime checks | All legacy unsafe types removed, `dispatchPrecondition` assertions |
| **Testing** | No tests | 101 unit tests + 32 integration tests (Docker NFS) |

## Features

- **Async/await API** — Modern Swift concurrency throughout
- **NFS v3/v4 support** — Via libnfs 6.0.2
- **Zero-copy reads** — Pre-allocated buffer path for files up to 64 MB
- **Adaptive pipelining** — AIMD congestion control for concurrent RPC operations
- **Sendable & thread-safe** — All public types are `Sendable`; safe from any actor or task
- **File transfer with progress** — Upload and download with cancellable progress callbacks
- **Multi-platform** — macOS, iOS, tvOS, Mac Catalyst, and their simulators

## Installation

NFSKit is distributed as a Swift Package.

```swift
dependencies: [
    .package(url: "https://github.com/simplekube-ro/NFSKit.git", branch: "main")
]
```

## Quick Start

```swift
import NFSKit

// Create a client
let client = try NFSClient(url: URL(string: "nfs://192.168.1.100")!)!

// List available exports
let exports = try await client.listExports()
print("Exports:", exports)

// Mount an export
try await client.connect(export: "/share")

// List directory contents
let items = try await client.contentsOfDirectory(atPath: "/")
for entry in items {
    let name = entry[.nameKey] as! String
    let size = entry[.fileSizeKey] as! Int64
    let type = entry[.fileResourceTypeKey] as! URLFileResourceType
    print("\(name) — \(type) — \(size) bytes")
}

// Read a file
let data = try await client.contents(atPath: "/example.txt")

// Read with progress
let largeData = try await client.contents(atPath: "/large-file.bin") { bytesRead, totalSize in
    print("Progress: \(bytesRead)/\(totalSize)")
    return true // return false to cancel
}

// Write a file
let payload = "Hello, NFS!".data(using: .utf8)!
try await client.write(data: payload, toPath: "/hello.txt")

// File operations
try await client.moveItem(atPath: "/hello.txt", toPath: "/renamed.txt")
try await client.createDirectory(atPath: "/new-dir")
try await client.removeItem(atPath: "/new-dir")

// Disconnect
try await client.disconnect()
```

### Performance Tuning

Configure performance parameters **before** connecting:

```swift
let client = try NFSClient(url: url)!

try client.configurePerformance(
    readMax: 1_048_576,    // 1 MB max read size
    writeMax: 1_048_576,   // 1 MB max write size
    autoReconnect: -1,     // infinite reconnect retries
    timeout: 30_000        // 30 second RPC timeout (ms)
)

try client.setSecurity(.system) // or .kerberos5, .kerberos5i, .kerberos5p

try await client.connect(export: "/share")
```

### File Handle I/O

For fine-grained control, use file handles directly:

```swift
let handle = try await client.openFile(atPath: "/data.bin", flags: O_RDONLY)

// Positional read (does not change file position)
let header = try await handle.pread(offset: 0, count: 64)

// Sequential read
let chunk = try await handle.read(count: 4096)

// Seek
let pos = try await handle.lseek(offset: 0, whence: SEEK_END)
print("File size: \(pos) bytes")

// Handle is automatically closed when deallocated
```

## Platform Support

| Platform | Minimum Version | Architectures |
|----------|----------------|---------------|
| macOS | 10.15 | x86_64, arm64 |
| iOS | 13.0 | arm64 |
| tvOS | 13.0 | arm64 |
| Mac Catalyst | 13.0 | x86_64, arm64 |
| iOS Simulator | 13.0 | x86_64, arm64 |
| tvOS Simulator | 13.0 | x86_64, arm64 |

**Swift**: 5.9+

## Documentation

- **[Architecture Guide](docs/ARCHITECTURE.md)** — Internal design: layer stack, event loop, pipeline system, connection lifecycle, memory management
- **[API Reference](docs/API.md)** — Complete public API documentation for all types and methods

## License

NFSKit source code is licensed under the [MIT License](LICENSE).

[libnfs](https://github.com/sahlberg/libnfs) is licensed under [LGPL v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). The pre-built `Libnfs.xcframework` included in this repository is subject to the LGPL v2.1 terms.

## Acknowledgements

- **[alexiscn](https://github.com/alexiscn)** — Original NFSKit author. The public API design and initial libnfs integration come from [alexiscn/NFSKit](https://github.com/alexiscn/NFSKit).
- **[amosavian](https://github.com/amosavian)** — [AMSMB2](https://github.com/amosavian/AMSMB2) inspired the architecture patterns used in this fork.
- **[sahlberg](https://github.com/sahlberg)** — Creator of [libnfs](https://github.com/sahlberg/libnfs), the C library that makes all of this possible.
