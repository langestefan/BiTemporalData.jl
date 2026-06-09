# Benchmarks

`benchmarks.jl` defines an [AirspeedVelocity.jl](https://github.com/MilesCranmer/AirspeedVelocity.jl)
`SUITE`. The `Benchmark PR` GitHub Actions workflow runs it to compare each pull
request against `main` (and across Julia versions) and posts the comparison as a
PR comment.

It covers the two headline read paths:

- `snapshot`, full tx-slice and collapsed cross-section, across every backend (the
  ML / bulk-analytics read boundary).
- `as_of_batch`, serial vs threaded, for the in-memory backends, where the
  `supports_parallel_reads` strategy threads straight over the queries.

## Running locally

Compare the working tree against `main` with the AirspeedVelocity driver:

```bash
julia -e 'using Pkg; Pkg.add("AirspeedVelocity")'   # provides `benchpkg`
benchpkg BiTemporalData --rev=main,dirty --bench-on=dirty
```

Or run the suite directly in the workspace (`benchmark` is a workspace member, so
it shares the root manifest):

```julia
using BenchmarkTools
include("benchmark/benchmarks.jl")
run(SUITE)
```

## What to expect

`ColumnarStore` lays records out as parallel column vectors, so a `snapshot`'s
`value` column is built contiguously in one pass (no per-record objects, no
`Serialization` decode): the fastest backend on the read path, ~7-24x faster than
`MemoryStore`. For `as_of_batch`, the in-memory backends thread straight over the
queries for a near-linear speedup, and the threaded scan is allocation-free on
`ColumnarStore` because it reads the columns by index without building a `Record`.
