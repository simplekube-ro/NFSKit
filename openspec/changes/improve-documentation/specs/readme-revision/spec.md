## ADDED Requirements

### Requirement: README contains project introduction with badges
The README SHALL begin with the project name, a one-line description, and badges for Swift version, platforms, and license.

#### Scenario: Reader opens README on GitHub
- **WHEN** a developer views the README on GitHub
- **THEN** they see the project name, description ("Swift NFS client for Apple platforms, built on libnfs"), and badges showing Swift 5.9+, supported platforms (macOS, iOS, tvOS, Catalyst), and MIT/LGPL license

### Requirement: README contains feature highlights
The README SHALL include a concise list of key features that distinguish NFSKit.

#### Scenario: Developer evaluates NFSKit capabilities
- **WHEN** a developer reads the features section
- **THEN** they see highlights including: async/await API, NFS v3/v4 support, zero-copy reads, adaptive pipelining, Sendable thread safety, file upload/download with progress, and multi-platform support

### Requirement: README contains modern async/await usage examples
The README SHALL provide Swift code examples using only the async/await API pattern, not the legacy callback-based pattern.

#### Scenario: Developer reads getting started examples
- **WHEN** a developer reads the usage examples
- **THEN** they see examples demonstrating: listing exports, connecting/mounting, directory listing, reading files, writing files, and file operations — all using `async/await` and `try`

#### Scenario: Examples are copy-paste ready
- **WHEN** a developer copies a code example into their project
- **THEN** the code compiles with only the NFSKit import and a valid NFS URL, without needing callback handlers or completion closures

### Requirement: README contains installation instructions
The README SHALL document Swift Package Manager installation with the correct repository URL.

#### Scenario: Developer adds NFSKit to their project
- **WHEN** a developer follows the installation instructions
- **THEN** they can add NFSKit via SPM using a `.package(url:)` dependency declaration

### Requirement: README contains platform support matrix
The README SHALL list all supported platforms with their minimum versions.

#### Scenario: Developer checks platform compatibility
- **WHEN** a developer reads the platform section
- **THEN** they see a table or list with: macOS 10.15+, iOS 13.0+, tvOS 13.0+, Mac Catalyst 13.0+, and the corresponding simulator targets

### Requirement: README links to architecture and API documentation
The README SHALL contain links to `docs/ARCHITECTURE.md` and `docs/API.md`.

#### Scenario: Developer wants deeper documentation
- **WHEN** a developer clicks the architecture or API reference link
- **THEN** they navigate to the corresponding document in the `docs/` directory

### Requirement: README contains license section with dual-license notice
The README SHALL clearly state that NFSKit source is MIT and libnfs is LGPL v2.1.

#### Scenario: Developer checks licensing
- **WHEN** a developer reads the license section
- **THEN** they understand both licenses apply and can find links to each license text
