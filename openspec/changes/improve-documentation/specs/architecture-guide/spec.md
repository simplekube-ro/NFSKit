## ADDED Requirements

### Requirement: Architecture document describes the layer stack
The architecture document SHALL describe NFSKit's four-layer stack: NFSClient → NFSEventLoop → C bridge module → Libnfs.xcframework.

#### Scenario: Contributor reads layer stack section
- **WHEN** a contributor reads the layer stack section
- **THEN** they see a Mermaid diagram showing the four layers with directional relationships and a text description of each layer's responsibility

### Requirement: Architecture document describes the event loop design
The architecture document SHALL explain NFSEventLoop's DispatchSource-based I/O model, serial queue confinement, and continuation registry.

#### Scenario: Contributor understands event loop
- **WHEN** a contributor reads the event loop section
- **THEN** they understand: DispatchSources monitor NFS file descriptors, all mutable state runs on a serial queue, and async/await continuations are registered and resumed via C callbacks through Unmanaged pointers

#### Scenario: Event loop flow is visualized
- **WHEN** a contributor views the event loop section
- **THEN** they see a Mermaid sequence or flow diagram showing: caller → async method → continuation registered → DispatchSource fires → C callback → continuation resumed → result returned

### Requirement: Architecture document describes the pipeline system
The architecture document SHALL explain the adaptive pipelining design with AIMD congestion control and bulk/metadata operation classification.

#### Scenario: Contributor understands pipelining
- **WHEN** a contributor reads the pipeline section
- **THEN** they understand: operations are classified as bulk or metadata, each category has a separate pipeline with AIMD-controlled depth, and the PipelineController adjusts window size based on success/failure signals

### Requirement: Architecture document describes the connection lifecycle
The architecture document SHALL document the NFS connection sequence including portmapper, mountd, and nfsd steps.

#### Scenario: Connection flow is visualized
- **WHEN** a contributor views the connection lifecycle section
- **THEN** they see a Mermaid sequence diagram showing: client → portmapper → mountd → nfsd with fd changes at each step and DispatchSource recreation

### Requirement: Architecture document describes the C bridge module
The architecture document SHALL explain how the `nfs` C module bridges Swift code to libnfs.

#### Scenario: Contributor understands C bridge
- **WHEN** a contributor reads the C bridge section
- **THEN** they understand: the `Sources/nfs/` target uses a shim header to aggregate libnfs headers, cSettings define required compile flags, and the XCFramework provides pre-built libnfs binaries

### Requirement: Architecture document describes memory management patterns
The architecture document SHALL document how NFSKit manages unsafe C pointers, callback data lifetime, and zero-copy read buffers.

#### Scenario: Contributor understands memory safety
- **WHEN** a contributor reads the memory management section
- **THEN** they understand: CallbackData objects are passed to C via Unmanaged pointers and released after callback, ReadBuffer provides ARC-managed wrappers for zero-copy buffers, and file handles are closed on deinit

### Requirement: Architecture document describes thread safety model
The architecture document SHALL document NFSKit's concurrency guarantees: Sendable types, serial queue confinement, and non-thread-safe components.

#### Scenario: Contributor understands thread safety
- **WHEN** a contributor reads the thread safety section
- **THEN** they understand: NFSClient and NFSFileHandle are Sendable, all mutable NFS state is confined to NFSEventLoop's serial queue, and NFSDirectory is explicitly not thread-safe

### Requirement: Architecture document is linked from README
The architecture document SHALL be reachable via a link in README.md.

#### Scenario: Navigation from README
- **WHEN** a developer clicks the architecture link in README
- **THEN** they navigate to `docs/ARCHITECTURE.md`
