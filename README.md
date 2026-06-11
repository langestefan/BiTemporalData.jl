# BiTemporalData.jl

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://langestefan.github.io/BiTemporalData.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://langestefan.github.io/BiTemporalData.jl/dev)

[![Test workflow status](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/langestefan/BiTemporalData.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/langestefan/BiTemporalData.jl)
[![Lint workflow Status](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/langestefan/BiTemporalData.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![tested with JET.jl](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)

BiTemporalData.jl stores facts along two time axes:

- **Effective time**: when a fact is true in the world.
- **Assertive time**: when the system asserted it was true.

This separates *the world changed* from *we changed our mind*. Writes are
append-only, so you can reproduce exactly what was known at any past point.

Concretely:

- **Forecasting**: build a training set from only the data available at each
  forecast time, so a backtest never sees values that were corrected later.
- **Finance and insurance**: reproduce a report exactly as it was filed, even
  after prices are restated or reserves revised.
- **Reproducibility**: re-run an analysis exactly as it stood at an earlier date,
  even after the inputs have since been revised.
- **Auditing**: answer "what value did we assert on date X, and when did it change?"

## Backends

BiTemporalData.jl implements the bitemporal logic; a backend stores the records.
The persistent backends load when you add their package:

| Backend             | Storage             | Best for                                | Load with      |
| ------------------- | ------------------- | --------------------------------------- | -------------- |
| 🧠 `MemoryStore`    | in-memory           | tests, single runs, embedding           | built in       |
| 📊 `ColumnarStore`  | in-memory, columnar | fast `snapshot` for ML / bulk reads     | built in       |
| 🗃️ `SQLiteStore`    | on-disk, row store  | durable single-file storage, audit logs | `using SQLite` |
| 🦆 `DuckDBStore`    | on-disk, columnar   | persistent bulk analytics               | `using DuckDB` |

🔒 Wrap any backend in `ThreadSafe(store)` for concurrent access.

`ColumnarStore` lays records out as parallel column vectors, so a `snapshot`'s
`value` column is a contiguous `Vector{V}` built in one pass: ~7–24× faster than
`MemoryStore` for the snapshot read path (see `benchmark/`).

## Installation

```julia
using Pkg; Pkg.add(url = "https://github.com/langestefan/BiTemporalData.jl")
```

## Quick start

`asserted_at` pins the assertive time for reproducible examples; omit it and it defaults
to `now(UTC)` (assertive time is UTC by convention, so it never goes backwards
across a DST boundary).

A read picks one point on each axis. `effective_at` is the world date you ask about;
`assertive_at` is the assertion you want, i.e. as of when the system knew it. Either can be
omitted:

| `effective_at`        | `assertive_at`         | `as_of` returns                                     |
| ----------------- | --------------- | --------------------------------------------------- |
| a date            | a date          | the value asserted at `assertive_at` to hold on `effective_at` |
| a date            | omitted (`now`) | what we assert now about `effective_at`                |
| omitted (`today`) | a date          | what we asserted at `assertive_at` about today             |
| omitted           | omitted         | what we assert now about today                     |

```julia
using BiTemporalData, Dates

store = MemoryStore{String, Float64}()                    # String keys, Float64 values

# Record a fact valid from 2024-01-01 onward.
insert!(store, "AAPL", 100.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))

as_of(store, "AAPL"; effective_at = Date(2024, 6, 1))
# 100.0
```

### Correct: we were wrong

`correct!` supersedes a value. The old record is closed in assertive time, not
deleted, so earlier assertions stay reproducible.

```julia
correct!(store, "AAPL", 110.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 3))

as_of(store, "AAPL"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 4))
# 110.0  (now)
as_of(store, "AAPL"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 2))
# 100.0  (before)
```

Correcting only part of a record preserves the rest: the assertion outside the
corrected range is kept (the surrounding slivers are re-inserted with the old
value), so a subrange correction never silently drops the surrounding assertion.

To state that *no* value holds over a range (rather than a replacement value),
use `retract!`; the prior assertion stays reproducible at an earlier `assertive_at`.

```julia
retract!(store, "AAPL"; effective_from = Date(2024, 1, 1), effective_to = Date(2024, 2, 1),
         asserted_at = DateTime(2024, 1, 5))

as_of(store, "AAPL"; effective_at = Date(2024, 1, 15), assertive_at = DateTime(2024, 1, 6))
# nothing  (retracted)
```

### Amend: the world changed

`amend!` splits the timeline on a date, keeping the old value before it.

```julia
amend!(store, "AAPL", 130.0; effective = Date(2024, 7, 1), asserted_at = DateTime(2024, 8, 1))

as_of(store, "AAPL"; effective_at = Date(2024, 3, 1), assertive_at = DateTime(2024, 8, 2))
# 110.0  (before)
as_of(store, "AAPL"; effective_at = Date(2024, 9, 1), assertive_at = DateTime(2024, 8, 2))
# 130.0  (after)
```

### Snapshots

`snapshot` materializes the whole store as one flat table fixed at a transaction
time, in a single pass. Every row reflects only what was known at that `assertive_at`,
so the same `assertive_at` always yields the same table: hand it to any downstream tool
(a `DataFrame`, a model, a report) and the result is fixed to that point in time.

```julia
# With effective_at: one value per entity.
snapshot(store; effective_at = Date(2024, 9, 1), assertive_at = DateTime(2024, 8, 2))
# (entity = ["AAPL"], value = [130.0])

# Without effective_at: one row per record asserted at assertive_at.
snapshot(store; assertive_at = DateTime(2024, 8, 2))
# (entity = ["AAPL", "AAPL"], value = [110.0, 130.0], effective_from = [...], effective_to = [...])
```

Both time axes are `DateTime`. Effective-time arguments accept any `TimeType`: a
`Date` is taken as midnight, a `DateTime` gives intraday precision, and a
`ZonedDateTime` (with `using TimeZones`) is stored as its UTC instant so times
across zones still order correctly. Open-ended ranges use the exported sentinel
`MAX_DT` (`typemax(DateTime)`). The result of `snapshot`, `history`, and the
analytical functions is a [Tables.jl](https://github.com/JuliaData/Tables.jl)
column table.

## Operations

| Function      | Purpose                                                       |
| ------------- | ------------------------------------------------------------- |
| `load!`       | Bulk-ingest a Tables.jl source (`DataFrame`, `CSV.File`)      |
| `insert!`     | Record a new fact over a valid range                          |
| `correct!`    | Supersede a value we now assert was wrong (history kept)     |
| `retract!`    | State that no value holds over a range (history kept)         |
| `amend!`      | Split the timeline when the world changes on a date           |
| `as_of`       | Read the value asserted at `assertive_at` to hold at `effective_at`      |
| `history`     | Full audit trail for a key                                    |
| `snapshot`    | Columnar point-in-time view of the whole store                |
| `asof_join`   | Inner-join two stores on `entity` at one point in time        |
| `diff`        | Records whose asserted value changed between two `assertive_at`      |
| `as_of_batch` | Vectorised `as_of` for many `(key, effective_at, assertive_at)` triples  |

## Backends and concurrency

Every backend has the same `{K, V}` constructor; the persistent ones take a file
path (or `":memory:"`):

```julia
mem = MemoryStore{String, Float64}()             # in-memory

using SQLite
sqlite = SQLiteStore{String, Float64}("data.db")

using DuckDB
duck = DuckDBStore{String, Float64}("data.duckdb")

safe = ThreadSafe(mem)                           # wrap any backend for concurrency
```

`ThreadSafe` serializes whole operations behind one store-wide lock, so
multi-primitive writes and compound reads (`as_of_batch`, `diff`, `load!`) cannot
interleave with a concurrent writer. On the persistent backends, multi-step
writes (`correct!`, `amend!`, `retract!`) run inside a SQLite/DuckDB transaction,
so a crash mid-write rolls back rather than leaving the file half-updated.

The data model is defined against an abstract `BitemporalStore` interface (four
primitives: `get_records`, `put_record!`, `close_tx!`, `entities`), so new
backends ship without changing the core.

## How to Cite

If you use BiTemporalData.jl in your work, please cite using [CITATION.cff](https://github.com/langestefan/BiTemporalData.jl/blob/main/CITATION.cff).

## Contributing

See the [contributing guide](docs/src/contributing.md) or the [contributing page](https://langestefan.github.io/BiTemporalData.jl/dev/contributing/).
