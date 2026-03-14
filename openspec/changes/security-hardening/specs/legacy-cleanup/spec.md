## ADDED Requirements

### Requirement: Remove NFSContext legacy wrapper
`NFSContext.swift` SHALL be deleted from the codebase. It is superseded by `NFSEventLoop` and contributes 2 MEDIUM-severity findings (silent error catch, lock-during-poll deadlock). No public or internal consumers reference it from `NFSClient` or `NFSEventLoop`.

#### Scenario: NFSContext file removed
- **WHEN** the security hardening change is applied
- **THEN** `Sources/NFSKit/NFSContext.swift` MUST NOT exist in the repository

#### Scenario: No remaining references to NFSContext
- **WHEN** `NFSContext.swift` is removed
- **THEN** no other source file in `Sources/NFSKit/` SHALL reference `NFSContext` as a type, variable, or import

### Requirement: Remove NFSDirectory legacy collection
`NFSDirectory.swift` SHALL be deleted from the codebase. It is superseded by `NFSEventLoop.readdirAll` and has a HIGH-severity nil pointer dereference bug. It is `internal` access — no external consumers.

#### Scenario: NFSDirectory file removed
- **WHEN** the security hardening change is applied
- **THEN** `Sources/NFSKit/NFSDirectory.swift` MUST NOT exist in the repository

#### Scenario: No remaining references to NFSDirectory
- **WHEN** `NFSDirectory.swift` is removed
- **THEN** no other source file in `Sources/NFSKit/` SHALL reference `NFSDirectory` as a type

### Requirement: Minimized C bridge header exposure
`nfs_shim.h` SHALL include only the high-level `libnfs.h` API header and the specific raw headers required by `NFSEventLoop` (`libnfs-raw.h`). Protocol-specific raw headers (`libnfs-raw-nfs4.h`, `libnfs-raw-nlm.h`, `libnfs-raw-nsm.h`, `libnfs-raw-portmap.h`, `libnfs-raw-rquota.h`) SHALL be removed unless a specific function from them is used in the Swift codebase.

#### Scenario: Required raw headers retained
- **WHEN** `NFSEventLoop.swift` calls `rpc_init_context`, `rpc_get_fd`, `rpc_service`, or other functions from `libnfs-raw.h`
- **THEN** `libnfs-raw.h` MUST remain in `nfs_shim.h`

#### Scenario: Unused protocol headers removed
- **WHEN** no Swift source file calls functions declared in `libnfs-raw-nlm.h`, `libnfs-raw-nsm.h`, `libnfs-raw-portmap.h`, or `libnfs-raw-rquota.h`
- **THEN** those headers MUST be removed from `nfs_shim.h`

#### Scenario: Build succeeds after header reduction
- **WHEN** unused protocol headers are removed from `nfs_shim.h`
- **THEN** `swift build` MUST succeed without errors

### Requirement: Correct Darwin platform config
`config.h` SHALL NOT define `HAVE_SO_BINDTODEVICE` on Darwin platforms. `SO_BINDTODEVICE` is a Linux-only socket option that does not exist on macOS, iOS, or tvOS.

#### Scenario: SO_BINDTODEVICE removed from config
- **WHEN** the security hardening change is applied
- **THEN** `Sources/nfs/include/config.h` MUST NOT contain `#define HAVE_SO_BINDTODEVICE`

#### Scenario: Build succeeds after config change
- **WHEN** `HAVE_SO_BINDTODEVICE` is removed from `config.h`
- **THEN** `swift build` MUST succeed without errors on all Apple platforms

### Requirement: AUTH_SYS security documentation
The public API documentation for `NFSClient.connect` and `NFSSecurity` SHALL document that the default `AUTH_SYS` mode provides no encryption, no message integrity, and UID/GID-based authentication that can be forged by any client on the network. The documentation SHALL recommend `kerberos5p` for sensitive deployments.

#### Scenario: Security documentation present
- **WHEN** a developer reads the doc comments on `NFSSecurity` or `NFSClient.connect`
- **THEN** they MUST find a clear warning about `AUTH_SYS` limitations and a recommendation for Kerberos
