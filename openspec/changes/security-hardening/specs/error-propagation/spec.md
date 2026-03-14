## ADDED Requirements

### Requirement: Throwing security configuration
`setSecurity()` SHALL be a throwing method. When the security mode cannot be applied (e.g., called after connection is established), the method SHALL throw the underlying error instead of silently discarding it.

#### Scenario: Security set before connection
- **WHEN** `setSecurity(.kerberos5p)` is called before `connect()`
- **THEN** the security mode is applied successfully

#### Scenario: Security set after connection
- **WHEN** `setSecurity(.kerberos5p)` is called after the connection is already established
- **THEN** the method MUST throw the underlying `EISCONN` error so the caller knows the setting was not applied

#### Scenario: Caller explicitly ignores error
- **WHEN** a caller uses `try? client.setSecurity(.kerberos5p)` to intentionally ignore the error
- **THEN** behavior is identical to the previous silent `try?` (backward compatible opt-in)

### Requirement: Throwing performance configuration
`configurePerformance()` SHALL be a throwing method. When any performance setting fails, the method SHALL throw the first error encountered.

#### Scenario: All settings applied successfully
- **WHEN** `configurePerformance(readMax: 1_048_576, writeMax: 1_048_576)` is called on a valid context
- **THEN** all settings are applied and the method returns without error

#### Scenario: Setting fails on destroyed context
- **WHEN** `configurePerformance(readMax: 1_048_576)` is called after the context has been destroyed
- **THEN** the method MUST throw the underlying error

### Requirement: Improved POSIX error code mapping
`POSIXErrorCode.init(_ code: Int32)` SHALL use `.EIO` as the fallback for unknown error codes instead of `.ECANCELED`. The original numeric code SHALL be preserved in the error description.

#### Scenario: Known POSIX error code
- **WHEN** a libnfs callback returns error code `-2` (ENOENT)
- **THEN** the error is mapped to `POSIXError(.ENOENT)`

#### Scenario: Unknown error code
- **WHEN** a libnfs callback returns an error code that does not map to any `POSIXErrorCode` raw value
- **THEN** the error MUST be mapped to `POSIXError(.EIO)` (not `.ECANCELED`)

### Requirement: Queue-confinement assertions for CallbackData
`CallbackData.resume()` SHALL include a `dispatchPrecondition(condition: .onQueue(queue))` assertion in DEBUG builds to enforce the queue-confinement invariant that protects `hasResumed`.

#### Scenario: Resume called on correct queue
- **WHEN** `CallbackData.resume()` is called on the NFSEventLoop's serial queue
- **THEN** the assertion passes and the continuation is resumed normally

#### Scenario: Resume called off queue in debug build
- **WHEN** `CallbackData.resume()` is called from a different queue in a DEBUG build
- **THEN** the `dispatchPrecondition` MUST trap, catching the thread-safety violation during development

### Requirement: Timestamp precision
`Date(timespec:)` SHALL preserve full nanosecond precision when converting from `timespec` to `Date`. The conversion SHALL NOT use integer division that truncates sub-microsecond values.

#### Scenario: Nanosecond timestamp conversion
- **WHEN** a `timespec` with `tv_sec = 1000000000` and `tv_nsec = 123456789` is converted to `Date`
- **THEN** the resulting `TimeInterval` MUST be `1000000000.123456789` (within floating-point precision), not `1000000000.123456` (truncated by integer division)
