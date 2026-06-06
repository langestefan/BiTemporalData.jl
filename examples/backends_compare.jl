# Load the same data into each backend and compare. Run with:
#   julia --project=examples examples/backends_compare.jl
#
# Same store interface, three backends: every one answers identically; the
# timings just show in-memory vs on-disk cost.

using BiTemporalData, CSV, DataFrames, Dates
using SQLite, DuckDB

df = CSV.read(joinpath(@__DIR__, "weather_forecasts.csv"), DataFrame)

ingest!(s) = load!(
    s, df;
    key = :city, value = :temp_c,
    valid_from = :target_date, valid_to = r -> r.target_date + Day(1),
    ts = r -> DateTime(r.issued_on),
)
function read_snapshot(s)
    snap = snapshot(s; valid_at = Date(2026, 6, 2), tx_at = DateTime(2026, 5, 30))
    return sort(collect(zip(snap.entity, snap.value)))
end

backends = [
    "MemoryStore" => () -> MemoryStore{String, Float64}(),
    "SQLiteStore" => () -> SQLiteStore{String, Float64}(":memory:"),
    "DuckDBStore" => () -> DuckDBStore{String, Float64}(":memory:"),
]

reference = nothing
println(rpad("backend", 13), rpad("load", 11), rpad("snapshot", 11), "vs MemoryStore")
for (name, make) in backends
    let s = make()           # warm up (compile) for this backend type, then time a fresh one
        ingest!(s)
        read_snapshot(s)
    end
    s = make()
    t_load = @elapsed ingest!(s)
    t_snap = @elapsed r = read_snapshot(s)
    reference === nothing && (global reference = r)
    println(
        rpad(name, 13),
        rpad("$(round(t_load * 1.0e3; digits = 1)) ms", 11),
        rpad("$(round(t_snap * 1.0e3; digits = 1)) ms", 11),
        r == reference ? "same ✓" : "DIFFERS ✗",
    )
end
