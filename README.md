# BiTemporalData

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://langestefan.github.io/BiTemporalData.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://langestefan.github.io/BiTemporalData.jl/dev)
[![Test workflow status](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/langestefan/BiTemporalData.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/langestefan/BiTemporalData.jl)
[![Lint workflow Status](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![tested with JET.jl](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)

BiTemporalData.jl stores facts along two independent time axes:

- **valid time**: when a fact is true in the world;
- **transaction time**: when the system believed it.

Tracking both lets you separate *the world changed* from *we changed our mind*,
and reproduce exactly what was known at any past point in time. Writes are
append-only (a correction never destroys what it supersedes), so the store is
also a complete audit trail.

This is useful for:

- Financial and sensor time series with restatements, backfills, and late data
- Reproducible, leakage-proof ML training sets (freeze a transaction time and re-run)
- Audit trails and "what did we know, and when?" regulatory queries
- Slowly-changing dimensions in analytics and data warehousing

## Installation

BiTemporalData.jl is not yet registered. Install it from GitHub:

```julia
julia> using Pkg; Pkg.add(url = "https://github.com/langestefan/BiTemporalData.jl")
```

## Example Usage

```julia
julia> using BiTemporalData, Dates

# A store of Float64 values keyed by String entities.
julia> store = MemoryStore{String, Float64}();

# Record a fact: AAPL = 100.0, valid from 2024-01-01 (open-ended).
# `ts` pins the transaction time; omit it in real use and it defaults to `now()`.
julia> insert!(store, "AAPL", 100.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1));

# What do we currently believe holds on 2024-06-01?
julia> as_of(store, "AAPL"; valid_at = Date(2024, 6, 1))
100.0
```

### Correcting a mistake

`correct!` supersedes a value we now believe was wrong. The old record is closed
in transaction time, not deleted, so earlier beliefs stay reproducible:

```julia
julia> correct!(store, "AAPL", 110.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 3));

# Current belief:
julia> as_of(store, "AAPL"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 4))
110.0

# What we believed *before* the correction landed:
julia> as_of(store, "AAPL"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 2))
100.0
```

### Amending when the world changes

`amend!` is different: the past value was *right*, but the world changed on a
date. It splits the timeline, keeping the old value before the change:

```julia
julia> amend!(store, "AAPL", 130.0; effective = Date(2024, 7, 1), ts = DateTime(2024, 8, 1));

julia> as_of(store, "AAPL"; valid_at = Date(2024, 3, 1), tx_at = DateTime(2024, 8, 2))   # before
110.0

julia> as_of(store, "AAPL"; valid_at = Date(2024, 9, 1), tx_at = DateTime(2024, 8, 2))   # after
130.0
```

### History and snapshots

Open-ended ranges are marked with the exported sentinels `MAX_DATE` and `MAX_DT`
(`typemax` of `Date`/`DateTime`):

```julia
julia> MAX_DATE, MAX_DT
(Date("252522163911149-12-31"), DateTime("146138512-12-31T23:59:59"))
```

`history` returns every record ever written for a key (superseded ones
included) as a [Tables.jl](https://github.com/JuliaData/Tables.jl)-compatible
column table:

```julia
julia> history(store, "AAPL").value
4-element Vector{Float64}:
 100.0
 110.0
 110.0
 130.0
```

`snapshot` is the read boundary for bulk/analytics workloads: a flat, columnar,
point-in-time view of the whole store. Freezing `tx_at` makes it reproducible and
leakage-proof. With a `valid_at`, it collapses to one value per entity:

```julia
julia> snapshot(store; valid_at = Date(2024, 9, 1), tx_at = DateTime(2024, 8, 2))
(entity = ["AAPL"], value = [130.0])

# Without `valid_at`: one row per record believed at `tx_at`.
julia> snapshot(store; tx_at = DateTime(2024, 8, 2))
(entity = ["AAPL", "AAPL"], value = [110.0, 130.0], valid_from = [Date("2024-01-01"), Date("2024-07-01")], valid_to = [Date("2024-07-01"), Date("252522163911149-12-31")])
```

## Operations

| Function   | Purpose                                                            |
| ---------- | ------------------------------------------------------------------ |
| `insert!`  | Record a new fact over a valid range                               |
| `correct!` | Supersede a value we now believe was wrong (history preserved)     |
| `amend!`   | Split the timeline when the world changes on a date                |
| `as_of`    | Read the value believed at `tx_at` to hold at `valid_at`           |
| `history`  | Full audit trail for a key, as a Tables.jl column table            |
| `snapshot` | Columnar point-in-time view of the whole store                     |

Three more operations build on `snapshot`:

| Function      | Purpose                                                         |
| ------------- | --------------------------------------------------------------- |
| `asof_join`   | Inner-join two stores on `entity` at one point in time          |
| `diff`        | Records whose believed value changed between two `tx_at` times  |
| `as_of_batch` | Vectorised `as_of` for many `(key, valid_at, tx_at)` triples    |

## Backends and concurrency

`MemoryStore` is the in-memory reference backend. Stores are single-threaded by
default; wrap one in `ThreadSafe` for concurrent access. It serializes whole
operations behind a store-wide lock, so multi-step writes stay atomic:

```julia
julia> safe = ThreadSafe(MemoryStore{String, Float64}());
```

The data model is defined against an abstract `BitemporalStore` interface (four
primitives: `get_records`, `put_record!`, `close_tx!`, `entities`), so additional
backends will ship as package extensions without changing the core.

## How to Cite

If you use BiTemporalData.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/langestefan/BiTemporalData.jl/blob/main/CITATION.cff).

## Contributing

If you want to make contributions of any kind, please first that a look into our [contributing guide directly on GitHub](docs/src/contributing.md) or the [contributing page on the website](https://langestefan.github.io/BiTemporalData.jl/dev/contributing/)
