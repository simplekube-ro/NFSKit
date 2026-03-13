## ADDED Requirements

### Requirement: Independent pipeline controllers for bulk and metadata
The system SHALL maintain two separate pipeline depth controllers: one for bulk I/O operations (read, write) and one for metadata operations (stat, readdir, mkdir, rmdir, unlink, rename, truncate). Each controller SHALL track its own depth independently.

#### Scenario: Metadata burst does not inflate bulk depth
- **WHEN** 50 stat operations complete successfully, growing the metadata depth to 12
- **THEN** the bulk pipeline depth remains at its own independently tracked value
- **WHEN** a large file read begins after the stat burst
- **THEN** the bulk controller's depth (not the metadata controller's) determines how many read RPCs are in-flight

#### Scenario: Bulk timeout does not penalize metadata
- **WHEN** a bulk read operation times out, halving the bulk depth
- **THEN** the metadata pipeline depth is unaffected

### Requirement: AIMD depth adjustment with slow start
Each pipeline controller SHALL use Additive Increase, Multiplicative Decrease (AIMD) with an initial slow-start phase.

#### Scenario: Slow start phase doubles depth on success
- **WHEN** the controller is in slow-start phase
- **THEN** the effective depth doubles after each successful completion (1 → 2 → 4 → 8)
- **WHEN** the depth reaches `ssthresh` (slow-start threshold)
- **THEN** the controller transitions to steady-state phase

#### Scenario: Steady-state additive increase
- **WHEN** the controller is in steady-state phase and an operation completes successfully
- **THEN** the depth increases by `1/depth` (linear growth: approximately +1 per full window of completions)

#### Scenario: Multiplicative decrease on timeout
- **WHEN** an operation times out
- **THEN** `ssthresh` is set to `depth / 2`
- **THEN** `depth` is halved (but not below `minDepth`)
- **THEN** the controller enters steady-state phase (not slow-start)

#### Scenario: Multiplicative decrease on NFS error
- **WHEN** an operation fails with an NFS error (not a client-side cancellation)
- **THEN** the same multiplicative decrease logic applies as for timeout

### Requirement: Depth bounds
Each pipeline controller SHALL enforce a minimum depth of 1 and a maximum depth of 32.

#### Scenario: Depth does not drop below minimum
- **WHEN** multiplicative decrease would reduce depth below 1
- **THEN** the depth is clamped to 1

#### Scenario: Depth does not exceed maximum
- **WHEN** slow start or additive increase would raise depth above 32
- **THEN** the depth is clamped to 32

### Requirement: Initial depth values
Each controller SHALL start with a depth of 2 and an `ssthresh` of 16 on a fresh connection.

#### Scenario: Fresh connection starts at depth 2
- **WHEN** a new NFS connection is established
- **THEN** both the bulk and metadata controllers begin with depth 2 in slow-start phase

#### Scenario: Reconnect resets depth
- **WHEN** an auto-reconnect occurs
- **THEN** both controllers reset to initial values (depth 2, ssthresh 16, slow-start phase)

### Requirement: Operation classification
Operations SHALL be classified as bulk or metadata to route them to the correct controller.

#### Scenario: Read and write operations are classified as bulk
- **WHEN** a `read`, `pread`, `write`, or `pwrite` operation is submitted
- **THEN** it is routed to the bulk pipeline controller

#### Scenario: All other operations are classified as metadata
- **WHEN** a `stat`, `statvfs`, `readdir`, `mkdir`, `rmdir`, `unlink`, `rename`, `truncate`, `readlink`, `open`, or `close` operation is submitted
- **THEN** it is routed to the metadata pipeline controller
