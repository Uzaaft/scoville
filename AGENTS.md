# Agent Instructions

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library AND any third-party dependencies (modules). Assume training data is out of date.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix
zigdoc std.net
zigdoc std.os.linux
```

## Zig Tooling

- Run `ziglint` on changed Zig files before finishing.
- Fix lint errors or document why they are acceptable in the PR/summary.

## Zig Code Style

**Naming:**
- `camelCase` for functions and methods
- `snake_case` for variables and parameters
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

**Struct initialization:** Prefer explicit type annotation with anonymous literals:
```zig
const foo: Type = .{ .field = value };  // Good
const foo = Type{ .field = value };     // Avoid
```

**File structure:**
1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`

**Functions:** Order methods as `init` → `deinit` → public API → private helpers

**Memory:** Pass allocators explicitly, use `errdefer` for cleanup on error

**Documentation:** Use `///` for public API, `//` for implementation notes. Always explain *why*, not just *what*.

**Tests:** Inline in the same file, register in src/root.zig test block

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

**Assertions:**
- Add assertions that catch real bugs, not trivially true statements
- Focus on API boundaries and state transitions where invariants matter
- Good: bounds checks, null checks before dereference, state machine transitions
- Avoid: asserting something immediately after setting it, checking internal function arguments

**Limits:**
- Put explicit bounds on all collections and resources
- Define limits as named constants, not magic numbers
- Assert limits are respected before operations

**Function size:**
- Hard limit of 70 lines per function
- Centralize control flow (switch/if) in parent functions
- Push pure computation to helper functions

**Comments:**
- Explain *why* the code exists, not *what* it does
- Document non-obvious thresholds, timing values, protocol details

## Nix / NixOS

- This project uses a Nix flake for packaging and NixOS configuration.
- The flake produces a Zig library package, a dev shell, and a NixOS module.
- Use `nix develop` to enter the dev shell with zig, zls, zigdoc, and ziglint.
- Use `nix build` to build the library.
- Never edit `flake.lock` manually; use `nix flake update` or `nix flake lock --update-input <name>`.

## Project Architecture

Scoville is a Zig library that bridges VMware's guest-host communication (backdoor/RPCI) with Wayland clipboard protocols. The goal is to replace or augment open-vm-tools clipboard functionality for Wayland compositors.

**Key subsystems:**
- `vmware/` — VMware backdoor I/O port (0x5658) and GuestRPC interface
- `wayland/` — Wayland `wl_data_device` / `wl_data_source` / `wl_data_offer` clipboard integration
- `bridge/` — Bidirectional clipboard synchronization between VMware host and Wayland clients

**Protocol notes:**
- VMware uses port 0x5658 for the backdoor interface and RPCI for clipboard RPC
- Wayland clipboard requires focus-gated `wl_data_device.set_selection` with keyboard serial
- Primary selection uses `zwp_primary_selection_device_manager_v1` (VMware syncs primary on Linux)

## Build Commands

- Build: `zig build`
- Format code: `zig build fmt`
- Run tests: `zig build test`

## Testing

Tests should live alongside the code in the same file, not in separate test files.

When creating a new source file with tests, add it to the test block in src/root.zig:
```zig
test {
    _ = @import("new_file.zig");
}
```

## Pre-commit Verification

Before committing changes, always run:
1. `zig build fmt`
2. `zig build`
3. `zig build test`

## Commit Message Format

**Title (first line):**
- Limit to 60 characters maximum
- Use a short prefix for readability with git log --oneline (do not use "fix:" or "feature:" prefixes)
- Use only lowercase letters except when quoting symbols or known acronyms
- Address only one issue/topic per commit
- Use imperative mood (e.g. "make xyzzy do frotz" instead of "makes xyzzy do frotz")

**Body:**
- Explain what the patch does and why it is useful
- Use proper English syntax, grammar and punctuation
- Write in imperative mood as if giving orders to the codebase

**Trailers:**
- If fixing a ticket, use appropriate commit trailers
- If fixing a regression, add a "Fixes:" trailer with the commit id and title
