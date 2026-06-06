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

- **Valid time**: when a fact is true in the world.
- **Transaction time**: when the system believed it was true.

This separates *the world changed* from *we changed our mind*. Writes are
append-only, so you can reproduce exactly what was known at any past point.

Concretely:

- **Forecasting**: build a training set from only the data available at each
  forecast time, so a backtest never sees values that were corrected later.
- **Finance and insurance**: reproduce a report exactly as it was filed, even
  after prices are restated or reserves revised.
- **Reproducibility**: re-run an analysis exactly as it stood at an earlier date,
  even after the inputs have since been revised.
- **Auditing**: answer "what value did we believe on date X, and when did it change?"

## Installation

```julia
using Pkg; Pkg.add(url = "https://github.com/langestefan/BiTemporalData.jl")
```

## Quick start

`ts` pins the transaction time for reproducible examples; omit it and it defaults
to `now()`.

A read picks one point on each axis. `valid_at` is the world date you ask about;
`tx_at` is the belief you want, i.e. as of when the system knew it. Either can be
omitted:

| `valid_at`        | `tx_at`         | `as_of` returns                                     |
| ----------------- | --------------- | --------------------------------------------------- |
| a date            | a date          | the value believed at `tx_at` to hold on `valid_at` |
| a date            | omitted (`now`) | what we believe now about `valid_at`                |
| omitted (`today`) | a date          | what we believed at `tx_at` about today             |
| omitted           | omitted         | what we believe now about today                     |

```julia
using BiTemporalData, Dates

store = MemoryStore{String, Float64}()                    # String keys, Float64 values

# Record a fact valid from 2024-01-01 onward.
insert!(store, "AAPL", 100.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))

as_of(store, "AAPL"; valid_at = Date(2024, 6, 1))
# 100.0
```

### Correct: we were wrong

`correct!` supersedes a value. The old record is closed in transaction time, not
deleted, so earlier beliefs stay reproducible.

```julia
correct!(store, "AAPL", 110.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 3))

as_of(store, "AAPL"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 4))
# 110.0  (now)
as_of(store, "AAPL"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 2))
# 100.0  (before)
```

### Amend: the world changed

`amend!` splits the timeline on a date, keeping the old value before it.

```julia
amend!(store, "AAPL", 130.0; effective = Date(2024, 7, 1), ts = DateTime(2024, 8, 1))

as_of(store, "AAPL"; valid_at = Date(2024, 3, 1), tx_at = DateTime(2024, 8, 2))
# 110.0  (before)
as_of(store, "AAPL"; valid_at = Date(2024, 9, 1), tx_at = DateTime(2024, 8, 2))
# 130.0  (after)
```

### Snapshots

`snapshot` materializes the whole store as one flat table fixed at a transaction
time, in a single pass. Every row reflects only what was known at that `tx_at`,
so the same `tx_at` always yields the same table: hand it to any downstream tool
(a `DataFrame`, a model, a report) and the result is fixed to that point in time.

```julia
# With valid_at: one value per entity.
snapshot(store; valid_at = Date(2024, 9, 1), tx_at = DateTime(2024, 8, 2))
# (entity = ["AAPL"], value = [130.0])

# Without valid_at: one row per record believed at tx_at.
snapshot(store; tx_at = DateTime(2024, 8, 2))
# (entity = ["AAPL", "AAPL"], value = [110.0, 130.0], valid_from = [...], valid_to = [...])
```

Open-ended ranges use the exported sentinels `MAX_DATE` and `MAX_DT`
(`typemax(Date)` / `typemax(DateTime)`). The result of `snapshot`, `history`, and
the analytical functions is a [Tables.jl](https://github.com/JuliaData/Tables.jl)
column table.

## Operations

| Function      | Purpose                                                       |
| ------------- | ------------------------------------------------------------- |
| `load!`       | Bulk-ingest a Tables.jl source (`DataFrame`, `CSV.File`)      |
| `insert!`     | Record a new fact over a valid range                          |
| `correct!`    | Supersede a value we now believe was wrong (history kept)     |
| `amend!`      | Split the timeline when the world changes on a date           |
| `as_of`       | Read the value believed at `tx_at` to hold at `valid_at`      |
| `history`     | Full audit trail for a key                                    |
| `snapshot`    | Columnar point-in-time view of the whole store                |
| `asof_join`   | Inner-join two stores on `entity` at one point in time        |
| `diff`        | Records whose believed value changed between two `tx_at`      |
| `as_of_batch` | Vectorised `as_of` for many `(key, valid_at, tx_at)` triples  |

## Backends and concurrency

`MemoryStore` is the in-memory reference backend. Stores are single-threaded;
wrap one in `ThreadSafe` to serialize whole operations behind a store-wide lock:

```julia
safe = ThreadSafe(MemoryStore{String, Float64}())
```

`SQLiteStore` is a persistent backend, loaded as an extension when you add
SQLite. Pass a file path (or `":memory:"`):

```julia
using SQLite, DBInterface
store = SQLiteStore{String, Float64}("data.db")
```

Like `MemoryStore`, its multi-step writes (`correct!`, `amend!`) are not atomic
across a crash.

The data model is defined against an abstract `BitemporalStore` interface (four
primitives: `get_records`, `put_record!`, `close_tx!`, `entities`), so new
backends ship without changing the core.

## How to Cite

If you use BiTemporalData.jl in your work, please cite using [CITATION.cff](https://github.com/langestefan/BiTemporalData.jl/blob/main/CITATION.cff).

## Contributing

See the [contributing guide](docs/src/contributing.md) or the [contributing page](https://langestefan.github.io/BiTemporalData.jl/dev/contributing/).
