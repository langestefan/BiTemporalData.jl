# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Julia package for **bitemporal** fact storage: every fact is tracked along two
independent time axes: *valid time* (when it is true in the world) and
*transaction time* (when the system believed it). This lets the store distinguish
"the world changed" from "we changed our mind."

The package is scaffolded from [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl).
The v1 data model is implemented: the abstract interface, the default operations,
and the `MemoryStore` reference backend. **`DESIGN.md`** is the original spec and
remains the rationale reference for the semantics and invariants. (Note: `DESIGN.md`
calls the module `Bitemporal`; the actual package/module is `BiTemporalData`.)

Source layout under `src/` (each `include`d by `BiTemporalData.jl`):

- `types.jl`: `Record`, `BitemporalStore`, the `MAX_DATE`/`MAX_DT` sentinels, and
  the internal `_close`/`_overlaps`/`_believed` helpers.
- `interface.jl`: the four backend primitive declarations.
- `defaults.jl`: `insert!` (extends `Base.insert!`), `correct!`, `amend!`,
  `as_of`, `history`, and `load!` (bulk-ingest a Tables.jl source via `correct!`).
- `snapshot.jl`: `snapshot`.
- `analytical.jl`: `asof_join`, `diff` (extends `Base.diff`), `as_of_batch`, all built on `snapshot`/`get_records`.
- `memory.jl`: `MemoryStore` and its four primitive methods.
- `sqlite.jl`: the `SQLiteStore` struct (DB handle as a type parameter) plus a
  catch-all error constructor; the real constructors and the four primitive
  methods live in `ext/BiTemporalDataSQLiteExt.jl` (loaded by `using SQLite`;
  SQLite re-exports `DBInterface`, which the extension uses). The struct sits in
  `src/` so its name is exportable
  and `@autodocs` picks up its docstring; the extension holds all SQLite-touching
  code (keys/values serialized to BLOBs, dates as `Dates.value` integers, `id` =
  rowid).
- `threadsafe.jl`: `ThreadSafe`, an operation-level locking wrapper.
- `display.jl`: `Base.show` (compact and `text/plain`) for any store, built only
  on the `entities`/`get_records` primitives so every backend prints identically.

## Architecture (per DESIGN.md)

The design separates an **abstract store interface** from concrete backends:

- `BitemporalStore{K,V}` (abstract): `K` is the entity key type, `V` the value type.
- A backend implements **four primitives**: `get_records`, `put_record!`,
  `close_tx!`, `entities`.
- All higher-level operations (`insert!`, `correct!`, `amend!`, `as_of`,
  `history`, `snapshot`) are **default methods on the abstract type** built from
  those primitives, so every backend gets them for free and may override any one
  with a faster native path.
- `MemoryStore` is the reference backend and the contract reference for the
  semantic test suite.
- `SQLiteStore` is a persistent backend shipped as a **package extension**
  (`[weakdeps]`/`[extensions]` on `SQLite`, plus `Serialization` which SQLite
  loads transitively). It runs the same
  semantic suite (`test/test-sqlite.jl`), so the suite is the shared correctness
  check for every backend. New backends follow this pattern: struct in `src/`,
  primitives in `ext/`.
- `ThreadSafe(store)` wraps any backend with a store-wide `ReentrantLock`. It
  locks at the **operation** layer (not per-primitive), so multi-primitive writes
  like `correct!`/`amend!` stay atomic; it delegates each operation to the inner
  store, whose primitive calls then run inside that one lock. It also passes the
  full semantic suite, so the suite doubles as its correctness check.

Key invariants that shape the whole design: records are **append-only** (only
`tx_to` may be mutated, to close it), all intervals are **half-open `[from, to)`**,
and open-ended ranges use the `MAX_DATE` / `MAX_DT` sentinels. "Currently believed"
means `tx_to == MAX_DT`.

The **snapshot** is the intended read boundary for read-heavy workloads (ML, bulk
analytics): a single linear pass producing a flat columnar table frozen at a fixed
`tx_at`, which makes reads reproducible and point-in-time leakage-proof. Do not
query the live store per-record for those workloads; materialize a snapshot.

All write operations take an optional `ts=` keyword purely for test determinism;
production callers omit it. Tests must pass explicit `ts=` and never rely on `sleep`
or wall-clock timing.

Implementation specifics worth knowing before editing:

- `history`/`snapshot` return a `NamedTuple` of equal-length column vectors, which
  is already a valid Tables.jl column table (no conversion needed on the read side).
  The package depends on `Tables` only on the **write** side: `load!` consumes any
  Tables.jl source. The test suite still uses `Tables` directly to verify the
  read-side round-trip.
- `insert!` and `diff` extend `Base` functions (to avoid export collisions), so they
  are *not* in the `export` list and `@autodocs` won't pick them up;
  `docs/src/reference.md` documents them with explicit signature-filtered `@docs` blocks.
- `snapshot` can't dispatch on keywords, so it selects its two modes via a
  `valid_at` sentinel (`nothing` → full tx-slice; a `Date` → collapsed
  cross-section).

## Commands

Run from the repository root. Tests use the [TestItemRunner](https://github.com/julia-vscode/TestItemRunner.jl)
framework (`@testitem` / `@testsnippet` / `@testmodule` blocks in `test/test-*.jl`,
discovered by `test/runtests.jl`).

```bash
# Run the full test suite
julia --project=. -e 'using Pkg; Pkg.test()'

# Build the docs once (runs the @example blocks; matches CI)
julia --project=docs -e 'using Pkg; Pkg.instantiate()'   # first time only
julia --project=docs docs/make.jl

# ...or serve with live reload while editing
julia --project=docs -e 'using LiveServer; servedocs()'
```

The `[workspace]` in `Project.toml` declares `test` and `docs` as sub-projects,
each with its own `Project.toml`. The `examples/` directory is a self-contained
runnable demo with its own environment (`julia --project=examples
examples/weather_bitemporal.jl`); it is not part of the workspace.

To run a single test item interactively, open Julia with `--project=.`, `using
TestItemRunner`, and use `@run_package_tests filter=...` to select by name or tag.
Test items are tagged `:unit` (semantics, backends, analytical) or `:quality`
(`test-quality.jl`: Aqua + JET static analysis); filter on tags to run a subset,
e.g. `@run_package_tests filter = ti -> :quality in ti.tags`.

## Linting & formatting

Linting/formatting is enforced via [pre-commit](https://pre-commit.com)-format
hooks run through [`prek`](https://github.com/j178/prek), both locally and in CI
(the `Lint.yml` workflow does `prek run --all-files`); **commits only succeed if
all hooks pass**. Julia code is formatted with Runic (opinionated, no config) and
ExplicitImports checks that imports are explicit. The Runic hook is `language:
julia`, so prek provisions Runic itself; the ExplicitImports hook is `language:
script`, so CI installs `ExplicitImports` into the default Julia environment.

**Always run `prek run -a` after making changes** (before considering work done /
committing). It reformats and lints in place, so it may modify files; re-check and
re-run until clean:

```bash
prek run -a
```

Link-check locally with `lychee --no-progress --config lychee.toml .`.

## Releasing

Bump `version` in `Project.toml`, move the `CHANGELOG.md` "Unreleased" section to a
dated version section, merge to `main`, then comment `@JuliaRegistrator register` on
the release commit. TagBot handles the git tag and docs deploy. Full steps in
`docs/src/developer.md`.
