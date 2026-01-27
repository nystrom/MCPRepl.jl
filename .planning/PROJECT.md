# MCPRepl.jl MCP.jl Migration

## What This Is

A migration project to replace custom JSON-RPC and stdio handling in MCPPlex.jl with the MCP.jl package, reducing maintenance burden while preserving existing multiplexer functionality for routing requests to project-specific Julia REPL servers.

## Core Value

Less custom protocol code to maintain - delegate JSON-RPC and MCP protocol details to MCP.jl while keeping the unique socket routing logic that makes multiplexing work.

## Requirements

### Validated

<!-- Existing capabilities from current codebase -->

- ✓ Multiplexer routes requests to project-specific Julia servers via Unix sockets — existing
- ✓ Socket discovery walks directory tree from project_dir to find .mcp-repl.sock — existing
- ✓ Dual transport support (stdio and HTTP modes) for multiplexer — existing
- ✓ Tool schemas include project_dir parameter for routing — existing
- ✓ Socket server handles multiple concurrent clients with timeout protection — existing
- ✓ MCPServer.jl implements JSON-RPC 2.0 protocol for HTTP and socket modes — existing
- ✓ Tools module provides exec_repl, investigate_environment, usage_instructions, remove-trailing-whitespace — existing

### Active

<!-- Migration work to be done -->

- [ ] Replace custom stdio JSON-RPC handling in MCPPlex with MCP.jl
- [ ] Replace custom HTTP JSON-RPC handling in MCPPlex with MCP.jl (if applicable)
- [ ] Preserve socket routing behavior (project_dir → .mcp-repl.sock discovery)
- [ ] Preserve tool schema format (project_dir parameter in multiplexed tools)
- [ ] Update MCPServer.jl for integration with MCP.jl-based multiplexer
- [ ] All existing tests pass after migration
- [ ] Claude connects with existing configuration (no client-side changes)

### Out of Scope

- Migrating MCPServer.jl to MCP.jl — keeping custom implementation for now
- Changing external API or command-line interface — external behavior unchanged
- Adding new features — pure refactoring/migration
- Supporting additional transports — stdio and HTTP remain the only options

## Context

**Current Architecture:**
- MCPPlex.jl implements custom JSON-RPC message handling for both stdio and HTTP transports
- Custom code handles: parsing JSON-RPC envelopes, method routing, error responses, timeout handling
- Socket routing logic is the unique value: project_dir parameter → walk tree → find .mcp-repl.sock → forward request
- MCPServer.jl has similar custom JSON-RPC handling but will stay mostly unchanged

**Motivation:**
- Custom JSON-RPC code is maintenance burden (debugging, protocol compliance, edge cases)
- MCP.jl provides battle-tested protocol handling
- Socket routing is the real value - protocol handling is undifferentiated work

**Deadlock Fixes:**
- Recent work added timeouts to prevent hangs (socket reads, task cleanup, multiplexer operations)
- Need to ensure MCP.jl integration doesn't reintroduce deadlock risks

## Constraints

- **Compatibility**: External behavior must stay the same — Claude/Gemini configs should work without changes
- **Tech Stack**: Must use MCP.jl package (official Julia MCP implementation)
- **Approach**: Clean cut replacement — no gradual migration or dual implementation
- **Testing**: Existing test suite must pass — behavior verified through tests

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Migrate only MCPPlex, not MCPServer | Multiplexer has most custom protocol code; server is working well | — Pending |
| Clean cut replacement | Simpler than maintaining two implementations during transition | — Pending |
| Preserve socket routing logic | This is the unique value - MCP.jl handles the rest | — Pending |

---
*Last updated: 2026-01-27 after initialization*
