## Context

NFSKit's documentation consists of a single README.md with outdated callback-based examples from the original AMSMB2-inspired API. The library has since been rewritten around an async/await event-loop architecture with adaptive pipelining, zero-copy reads, and Sendable concurrency guarantees — none of which are documented for users.

The CLAUDE.md file contains detailed architectural knowledge but is designed for AI coding assistants, not library consumers. There is no human-facing architecture document or API reference.

## Goals / Non-Goals

**Goals:**
- Provide a README that accurately represents NFSKit's current async/await API and capabilities
- Create an architecture document with visual diagrams that explains the internal design for contributors and advanced users
- Create a comprehensive API reference that serves both human developers and AI coding assistants
- All documentation renders correctly on GitHub (Mermaid diagrams, markdown)

**Non-Goals:**
- DocC or generated API documentation (too heavy for the current project size)
- Tutorials or step-by-step guides beyond the README examples
- Documentation for internal/non-public types (NFSEventLoop, PipelineController, etc.) in the API reference
- Versioned documentation or documentation site hosting

## Decisions

### D1: Documentation lives in `docs/` directory

Architecture and API docs go in `docs/ARCHITECTURE.md` and `docs/API.md`, linked from README.

**Rationale**: Keeps README focused on getting started while providing depth for those who need it. The `docs/` convention is widely understood on GitHub. Alternative considered: putting everything in README — rejected because it would make the README too long and hard to navigate.

### D2: Mermaid for diagrams

Use GitHub-native Mermaid syntax for all flow diagrams and architecture visuals.

**Rationale**: No external tooling, no image files to maintain, renders inline on GitHub. Alternatives considered: ASCII art (limited expressiveness), PlantUML (requires rendering pipeline), PNG images (hard to maintain). Mermaid is the standard for GitHub-rendered diagrams.

### D3: API reference as hand-written Markdown, not generated docs

Write `docs/API.md` manually with structured sections per public type.

**Rationale**: The public API surface is small (4 public types, ~30 methods). Hand-written docs allow us to include usage context, gotchas, and cross-references that generated docs miss. AI assistants can parse structured Markdown more reliably than DocC output. Alternative considered: DocC — rejected because it requires Xcode tooling, adds build complexity, and the API surface doesn't justify it.

### D4: Dual-audience API docs with machine-readable structure

Structure API docs with consistent heading hierarchy (`## Type` → `### Method Group` → `#### Method`) and code blocks with full signatures.

**Rationale**: This heading structure is parseable by both humans scanning the TOC and AI assistants looking for method signatures. Each method gets its signature in a Swift code block, a description, parameter table, and error documentation.

### D5: README examples use async/await exclusively

Drop all callback-based examples. Show only the modern async/await API.

**Rationale**: The callback API was the original AMSMB2-inspired interface and is no longer the recommended usage pattern. Showing both would confuse users. The async/await API is the only supported path.

## Risks / Trade-offs

- **[Docs drift from code]** → Mitigate by keeping CLAUDE.md as the source of truth for AI-assisted development. Human docs reference the same architecture but at a higher level. Contributors updating the API should update `docs/API.md` — add a note about this in the architecture doc.
- **[Mermaid rendering limitations]** → Some GitHub mobile clients render Mermaid poorly. Mitigate by keeping diagrams simple and ensuring the text around them is self-sufficient without the visuals.
- **[Over-documenting internals]** → The architecture doc describes internal design (event loop, pipeline) for contributors. Risk of documenting implementation details that change frequently. Mitigate by focusing on stable abstractions (layer stack, callback pattern) rather than implementation specifics.
