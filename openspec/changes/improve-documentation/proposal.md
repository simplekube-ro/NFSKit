## Why

NFSKit's current README is minimal and outdated — it shows callback-based API examples that no longer reflect the library's modern async/await interface, provides no architectural overview, and offers no API reference. Developers evaluating or integrating NFSKit must read source code to understand capabilities, threading model, and usage patterns. This creates unnecessary friction for both human developers and AI coding assistants working with the library.

## What Changes

- **Revise README.md**: Replace the outdated callback-based examples with modern async/await usage, add badges, feature highlights, platform support matrix, performance tuning section, and links to architecture and API docs.
- **Add architecture document** (`docs/ARCHITECTURE.md`): Describe the layer stack, event loop design, pipeline system, connection lifecycle, and memory management with Mermaid flow diagrams. Link from README.
- **Add API reference** (`docs/API.md`): Comprehensive documentation of all public types (`NFSClient`, `NFSFileHandle`, `NFSSecurity`, `NFSStats`), their methods, parameters, return types, error handling, and concurrency guarantees — structured for both human reading and AI consumption.

## Capabilities

### New Capabilities
- `readme-revision`: Modernize README.md with accurate async/await examples, feature overview, platform matrix, and navigation to detailed docs.
- `architecture-guide`: New `docs/ARCHITECTURE.md` covering layer stack, event loop, pipeline, connection lifecycle, and C bridge — with Mermaid diagrams.
- `api-reference`: New `docs/API.md` providing complete public API documentation for NFSClient, NFSFileHandle, NFSSecurity, NFSStats, and public extensions.

### Modified Capabilities
<!-- No existing specs to modify -->

## Impact

- **Files created**: `docs/ARCHITECTURE.md`, `docs/API.md`
- **Files modified**: `README.md`
- **No code changes**: This is a documentation-only change — no source code, tests, or build configuration affected.
- **Dependencies**: None. Mermaid diagrams render natively on GitHub.
