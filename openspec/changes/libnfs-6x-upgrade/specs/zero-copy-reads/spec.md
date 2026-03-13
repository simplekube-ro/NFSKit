## ADDED Requirements

### Requirement: ReadBuffer manages unsafe pointer lifecycle via ARC
The system SHALL provide a `ReadBuffer` class that allocates an `UnsafeMutableRawPointer` of a specified size, is `@unchecked Sendable`, and deallocates the pointer in `deinit` unless `disown()` has been called to transfer ownership.

#### Scenario: Normal allocation and deallocation
- **WHEN** a `ReadBuffer` is created with `byteCount: 4096`
- **THEN** it SHALL allocate 4096 bytes of memory accessible via its `pointer` property and `size` property SHALL return 4096

#### Scenario: Ownership transfer prevents double-free
- **WHEN** `disown()` is called on a `ReadBuffer`
- **THEN** the `ReadBuffer.deinit` SHALL NOT deallocate the pointer, and `isOwned` SHALL return `false`

#### Scenario: Deallocation on release without disown
- **WHEN** a `ReadBuffer` is released without calling `disown()`
- **THEN** `deinit` SHALL deallocate the pointer

### Requirement: nfs_read_async uses caller-provided buffer
The `NFSEventLoop.readFile()` method SHALL allocate a `ReadBuffer`, pass its pointer as the `buf` parameter to `nfs_read_async(ctx, fh, buf, count, cb, priv)`, and construct the result `Data` from the buffer without copying.

#### Scenario: Successful read returns zero-copy Data
- **WHEN** `readFile(handleID:count:)` is called and the read succeeds with N bytes
- **THEN** the result `Data` SHALL be created via `Data(bytesNoCopy:count:deallocator:)` using the `ReadBuffer`'s pointer and N as the count, and `ReadBuffer.disown()` SHALL have been called

#### Scenario: Read error frees the buffer
- **WHEN** `readFile(handleID:count:)` is called and libnfs returns an error (status < 0)
- **THEN** the `ReadBuffer` SHALL be deallocated via its `deinit` (no memory leak)

#### Scenario: EOF returns empty Data and frees buffer
- **WHEN** a read callback fires with status == 0 (EOF)
- **THEN** the result SHALL be an empty `Data()` and the `ReadBuffer` SHALL be deallocated

### Requirement: nfs_pread_async uses caller-provided buffer
The `NFSEventLoop.preadFile()` method SHALL allocate a `ReadBuffer`, pass its pointer as the `buf` parameter to `nfs_pread_async(ctx, fh, buf, count, offset, cb, priv)`, and construct the result `Data` from the buffer without copying.

#### Scenario: Successful positional read returns zero-copy Data
- **WHEN** `preadFile(handleID:offset:count:)` is called and succeeds with N bytes
- **THEN** the result `Data` SHALL be created via `Data(bytesNoCopy:count:deallocator:)` using the `ReadBuffer`'s pointer

#### Scenario: Positional read error frees the buffer
- **WHEN** `preadFile(handleID:offset:count:)` fails
- **THEN** the `ReadBuffer` SHALL be deallocated without leaking

### Requirement: Write async calls use updated parameter order
The `NFSEventLoop.writeFile()` and `pwriteFile()` methods SHALL call `nfs_write_async(ctx, fh, buf, count, cb, priv)` and `nfs_pwrite_async(ctx, fh, buf, count, offset, cb, priv)` respectively, matching the libnfs 6.x parameter order.

#### Scenario: Write call uses correct 6.x signature
- **WHEN** `writeFile(handleID:data:)` is called
- **THEN** it SHALL invoke `nfs_write_async` with parameters in order: `(ctx, handle, bufPtr, size_t(count), callback, privateData)`

#### Scenario: Positional write call uses correct 6.x signature
- **WHEN** `pwriteFile(handleID:offset:data:)` is called
- **THEN** it SHALL invoke `nfs_pwrite_async` with parameters in order: `(ctx, handle, bufPtr, size_t(count), offset, callback, privateData)`

### Requirement: Read callback ignores data pointer
The `nfsCallback` data handler for read operations SHALL NOT use the `dataPtr` parameter from the C callback (it is NULL in libnfs 6.x). It SHALL instead read from the captured `ReadBuffer`.

#### Scenario: Callback dataPtr is unused for reads
- **WHEN** the NFS read callback fires with `data == NULL` and `status > 0`
- **THEN** the data handler SHALL construct `Data` from the captured `ReadBuffer.pointer` with count `Int(status)`, not from `dataPtr`
