# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Julia package for **bitemporal** fact storage: every fact is tracked along two
independent time axes — *valid time* (when it is true in the world) and
*transaction time* (when the system believed it). This lets the store distinguish
"the world changed" from "we changed our mind."

The package is scaffolded from [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl).
`src/BiTemporalData.jl` is currently a `hello_world` stub — the real architecture
to build out is fully specified in **`DESIGN.md`**, which is the source of truth
for types, the backend interface, operation semantics, and the planned file
layout. Read it before implementing anything. (Note: `DESIGN.md` calls the module
`Bitemporal`; the actual package/module is `BiTemporalData`.)

## Architecture (per DESIGN.md)

The design separates an **abstract store interface** from concrete backends:

- `BitemporalStore{K,V}` (abstract) — `K` is the entity key type, `V` the value type.
- A backend implements **four primitives**: `get_records`, `put_record!`,
  `close_tx!`, `entities`.
- All higher-level operations (`insert!`, `correct!`, `amend!`, `as_of`,
  `history`, `snapshot`) are **default methods on the abstract type** built from
  those primitives, so every backend gets them for free and may override any one
  with a faster native path.
- `MemoryStore` is the reference backend and the contract reference for the
  semantic test suite.

Key invariants that shape the whole design: records are **append-only** (only
`tx_to` may be mutated, to close it), all intervals are **half-open `[from, to)`**,
and open-ended ranges use the `MAX_DATE` / `MAX_DT` sentinels. "Currently believed"
means `tx_to == MAX_DT`.

The **snapshot** is the intended read boundary for read-heavy workloads (ML, bulk
analytics): a single linear pass producing a flat columnar table frozen at a fixed
`tx_at`, which makes reads reproducible and point-in-time leakage-proof. Do not
query the live store per-record for those workloads; materialize a snapshot.

All write operations take an optional `ts=` keyword purely for test determinism —
production callers omit it. Tests must pass explicit `ts=` and never rely on `sleep`
or wall-clock timing.

## Commands

Run from the repository root. Tests use the [TestItemRunner](https://github.com/julia-vscode/TestItemRunner)
framework (`@testitem` / `@testsnippet` / `@testmodule` blocks in `test/test-*.jl`,
discovered by `test/runtests.jl`).

```bash
# Run the full test suite
julia --project=. -e 'using Pkg; Pkg.test()'

# Build docs locally with live reload (then open the served URL)
julia --project=docs -e 'using Pkg; Pkg.develop(path=".")'   # first time only
julia --project=docs -e 'using LiveServer; servedocs()'
```

The `[workspace]` in `Project.toml` declares `test` and `docs` as sub-projects,
each with its own `Project.toml`.

To run a single test item interactively, open Julia with `--project=.`, `using
TestItemRunner`, and use `@run_package_tests filter=...` to select by name or tag.
Test items are tagged (`:unit`, `:fast`, `:integration`, `:slow`, `:validation`);
filter on tags to run a subset.

## Linting & formatting

Linting/formatting is enforced via [pre-commit](https://pre-commit.com) hooks
(this repo runs them through `prek`) — **commits only succeed if all hooks pass**.
Julia code is formatted with both JuliaFormatter (config in `.JuliaFormatter.toml`:
4-space indent, 92-char margin) and Runic. ExplicitImports checks that imports are
explicit.

**Always run `prek run -a` after making changes** (before considering work done /
committing). It reformats and lints in place, so it may modify files — re-check and
re-run until clean:

```bash
prek run -a
```

Link-check locally with `lychee --no-progress --config lychee.toml .`.

## Releasing

Bump `version` in `Project.toml`, move the `CHANGELOG.md` "Unreleased" section to a
dated version section, merge to `main`, then comment `@JuliaRegistrator register` on
the release commit. TagBot handles the git tag and docs deploy. Full steps in
`docs/src/91-developer.md`.
