# Benchmark the `snapshot` read path across backends. Run with:
#   julia --project=bench bench/snapshot_bench.jl
#
# `snapshot` is the read boundary for ML / bulk-analytics workloads, so this is
# the path that matters for those use cases. `ColumnarStore` lays the records out
# as a struct-of-arrays, so a snapshot's `value` column is built contiguously with
# no per-record objects and no deserialization.

using BiTemporalData, Dates, Printf
using SQLite, DuckDB
using BenchmarkTools

# Synthetic store: `n` entities, each an insert + two corrections (3 records each,
# one currently believed). Tiny per-entity history; the point is many entities.
const N = 2_000
const TX = [DateTime(2024, 1, d) for d in 1:3]

function build!(s)
    for i in 1:N
        k = "e$i"
        insert!(s, k, float(i); valid_from = Date(2024, 1, 1), ts = TX[1])
        correct!(s, k, float(i) + 0.1; valid_from = Date(2024, 1, 1), ts = TX[2])
        correct!(s, k, float(i) + 0.2; valid_from = Date(2024, 1, 1), ts = TX[3])
    end
    return s
end

backends = [
    "MemoryStore"   => () -> MemoryStore{String, Float64}(),
    "ColumnarStore" => () -> ColumnarStore{String, Float64}(),
    "SQLiteStore"   => () -> SQLiteStore{String, Float64}(":memory:"),
    "DuckDBStore"   => () -> DuckDBStore{String, Float64}(":memory:"),
]

println("Building stores: $N entities x 3 records = $(3N) records ...")
stores = [name => build!(make()) for (name, make) in backends]

# `tx_at = TX[3]` sees the latest belief; the cross-section collapses to one value
# per entity (a training row per entity).
full(s) = snapshot(s; tx_at = TX[3])
cross(s) = snapshot(s; valid_at = Date(2024, 6, 1), tx_at = TX[3])

function report(title, f)
    println("\n## $title")
    @printf "%-15s %12s %14s %10s\n" "backend" "time" "allocations" "vs Memory"
    base = nothing
    for (name, s) in stores
        t = @belapsed $f($s)
        a = @allocated f(s)
        base === nothing && (base = t)
        unit, scale = t < 1e-3 ? ("µs", 1e6) : ("ms", 1e3)
        rel = t <= base ? "$(round(base / t; digits = 1))x" : "$(round(t / base; digits = 0))x slower"
        @printf "%-15s %9.1f %2s %11.1f KiB  %-14s\n" name (t * scale) unit (a / 1024) rel
    end
end

report("full tx-slice snapshot  (entity, value, valid_from, valid_to)", full)
report("cross-section snapshot  (entity, value)  - one training row per entity", cross)

# Sanity: every backend returns the same number of believed records / entities.
println("\nfull rows: ", join(["$name=$(length(full(s).entity))" for (name, s) in stores], "  "))
println("cross rows: ", join(["$name=$(length(cross(s).entity))" for (name, s) in stores], "  "))
