## ADDED Requirements

### Requirement: config.h auto-generated from cmake output
The `build.sh` script SHALL copy the cmake-generated `config.h` from the first completed platform build to `Sources/nfs/include/config.h`, replacing the hand-maintained file.

#### Scenario: config.h updated during build
- **WHEN** `build.sh` completes the first architecture build
- **THEN** `Sources/nfs/include/config.h` SHALL contain the cmake-generated configuration matching libnfs 6.0.2

#### Scenario: config.h includes new 6.x defines
- **WHEN** the generated `config.h` is produced on macOS
- **THEN** it SHALL define `HAVE_STDATOMIC_H`, `HAVE_SYS_UIO_H`, `HAVE_SIGNAL_H`, `HAVE_SYS_UTSNAME_H`, and `HAVE_DISPATCH_DISPATCH_H`

### Requirement: libnfs submodule updated to 6.0.2
The `Vendor/libnfs` git submodule SHALL point to the `libnfs-6.0.2` tag (commit `18c5c73`).

#### Scenario: Submodule at correct version
- **WHEN** `git submodule status` is run
- **THEN** the `Vendor/libnfs` entry SHALL reference the `libnfs-6.0.2` tag

### Requirement: Private header updated to new path
`Sources/nfs/include/libnfs-private.h` SHALL be sourced from `include/libnfs-private.h` in the libnfs 6.x tree (moved from `include/nfsc/libnfs-private.h`).

#### Scenario: Private header matches 6.x version
- **WHEN** the project builds successfully
- **THEN** `Sources/nfs/include/libnfs-private.h` SHALL contain the libnfs 6.0.2 private header with the updated `struct nfsfh` (no `readahead` or `pagecache` fields)

### Requirement: XCFramework rebuilt against 6.0.2
After submodule update, `build.sh` and `xcframework.sh` SHALL produce a `Framework/Libnfs.xcframework` linked against libnfs 6.0.2 for all supported platform slices.

#### Scenario: All platform slices build
- **WHEN** `build.sh` is run with default options followed by `xcframework.sh`
- **THEN** `Framework/Libnfs.xcframework` SHALL contain slices for macos (x86_64, arm64), ios (arm64), tvos (arm64), isimulator (x86_64, arm64), tvsimulator (x86_64, arm64), and maccatalyst (x86_64, arm64)

### Requirement: Removed APIs not referenced
After the upgrade, the Swift source SHALL NOT reference `nfs_set_pagecache`, `nfs_set_pagecache_ttl`, `nfs_set_readahead`, `nfs_pagecache_invalidate`, `nfs_pagecache_init`, or `nfs_create`/`nfs_create_async`.

#### Scenario: No references to removed C APIs
- **WHEN** the project is searched for removed API calls
- **THEN** zero matches SHALL be found in `Sources/NFSKit/`
