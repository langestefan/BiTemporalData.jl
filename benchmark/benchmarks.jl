"""
Benchmarks for BiTemporalData.jl, in the AirspeedVelocity.jl `SUITE` format so
the GitHub Actions workflow can compare a PR against `main` and across versions.

Run locally with the package manager driver:

    using Pkg; Pkg.add("AirspeedVelocity")   # provides `benchpkg`
    benchpkg BiTemporalData --rev=main,dirty --bench-on=dirty

Or directly via the Julia API:

    using BenchmarkTools
    include("benchmark/benchmarks.jl")
    run(SUITE)

The two headline read paths are covered: `snapshot` (the ML / bulk-analytics read
boundary) across every backend, and `as_of_batch` serial vs threaded for the
in-memory backends (where the `supports_parallel_reads` strategy actually threads
over queries).
"""

using BenchmarkTools
using BiTemporalData
using Dates: Date, DateTime
using Random: MersenneTwister
using SQLite, DuckDB

const SUITE = BenchmarkGroup()

# Kept modest so the suite stays fast enough to run on every PR across versions.
const N = 1_000                  # entities
const Q = 10_000                 # queries per as_of_batch
const TX = [DateTime(2024, 1, d) for d in 1:3]
const VALID_FROM = Date(2024, 1, 1)
const READ_VALID = Date(2024, 6, 1)

# Each entity gets an insert plus two corrections (3 records, one believed now).
function build!(s)
    for i in 1:N
        k = "e$i"
        insert!(s, k, float(i); valid_from = VALID_FROM, ts = TX[1])
        correct!(s, k, float(i) + 0.1; valid_from = VALID_FROM, ts = TX[2])
        correct!(s, k, float(i) + 0.2; valid_from = VALID_FROM, ts = TX[3])
    end
    return s
end

const BACKENDS = [
    "MemoryStore" => () -> MemoryStore{String, Float64}(),
    "ColumnarStore" => () -> ColumnarStore{String, Float64}(),
    "SQLiteStore" => () -> SQLiteStore{String, Float64}(":memory:"),
    "DuckDBStore" => () -> DuckDBStore{String, Float64}(":memory:"),
]

# A fixed (seeded) query batch so every backend and revision sees the same work.
function querybatch(q)
    rng = MersenneTwister(q)
    return (["e$(rand(rng, 1:N))" for _ in 1:q], fill(READ_VALID, q), fill(TX[3], q))
end

# `snapshot`: full tx-slice and collapsed cross-section, for every backend.
SUITE["snapshot"] = BenchmarkGroup()
for (name, make) in BACKENDS
    s = build!(make())
    SUITE["snapshot"][name]["full"] = @benchmarkable snapshot($s; tx_at = $(TX[3]))
    SUITE["snapshot"][name]["cross"] =
        @benchmarkable snapshot($s; valid_at = $READ_VALID, tx_at = $(TX[3]))
end

# `as_of_batch`: serial vs threaded for the in-memory backends, whose
# `supports_parallel_reads` strategy threads straight over the queries.
SUITE["as_of_batch"] = BenchmarkGroup()
let (keys, valids, txs) = querybatch(Q)
    for (name, make) in BACKENDS[1:2]
        s = build!(make())
        SUITE["as_of_batch"][name]["serial"] =
            @benchmarkable as_of_batch($s, $keys, $valids, $txs)
        SUITE["as_of_batch"][name]["threaded"] =
            @benchmarkable as_of_batch($s, $keys, $valids, $txs; threaded = true)
    end
end
