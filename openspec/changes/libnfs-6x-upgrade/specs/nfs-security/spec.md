## ADDED Requirements

### Requirement: NFSSecurity enum models authentication modes
The system SHALL provide an `NFSSecurity` enum with cases `system`, `kerberos5`, `kerberos5i`, `kerberos5p` that maps to the libnfs `enum rpc_sec` values. The enum SHALL be `Sendable`.

#### Scenario: All Kerberos modes are representable
- **WHEN** an `NFSSecurity` value is created
- **THEN** the available cases SHALL be `.system` (AUTH_SYS), `.kerberos5` (authentication), `.kerberos5i` (integrity), `.kerberos5p` (privacy/encryption)

### Requirement: NFSClient.setSecurity configures authentication
`NFSClient` SHALL provide a `setSecurity(_ security: NFSSecurity)` method that calls `nfs_set_security()` on the underlying NFS context. It MUST be called before `connect(export:)`.

#### Scenario: Setting Kerberos 5 security pre-connect
- **WHEN** `setSecurity(.kerberos5p)` is called before `connect(export:)`
- **THEN** `nfs_set_security(ctx, RPC_SEC_KRB5P)` SHALL be called on the underlying context

#### Scenario: Setting security after connect has no effect
- **WHEN** `setSecurity()` is called after `connect(export:)` has completed
- **THEN** the method SHALL throw an error indicating security must be set before connection

### Requirement: Default security is AUTH_SYS
If no security mode is explicitly set, the system SHALL use AUTH_SYS (standard UNIX authentication), which is the libnfs default.

#### Scenario: No explicit security configuration
- **WHEN** `connect(export:)` is called without a prior `setSecurity()` call
- **THEN** the connection SHALL use AUTH_SYS authentication
