# Backend-aware threaded `as_of_batch`, all combinations. Run with:
#   julia -t auto --project=bench bench/threaded_bench.jl
#
# `as_of_batch(...; threaded = true)` picks its strategy from
# `supports_parallel_reads`: in-memory backends thread straight over the queries
# ("parallel" reads); on-disk backends fetch records serially (connection-safe)
# and thread only the per-query scan ("serial" reads). This sweeps the batch size
# across every backend and reports the real speedup of each.

using BiTemporalData, Dates, Printf, Random
using SQLite, DuckDB
using BenchmarkTools

const N = 2_000                       # entities
const TX = [DateTime(2024, 1, d) for d in 1:2]

function build!(s)
    for i in 1:N
        k = "e$i"
        insert!(s, k, float(i); valid_from = Date(2024, 1, 1), ts = TX[1])
        correct!(s, k, float(i) + 0.1; valid_from = Date(2024, 1, 1), ts = TX[2])
    end
    return s
end

println("Building stores ($N entities x 2 records) ...")
stores = [
    "MemoryStore" => build!(MemoryStore{String, Float64}()),
    "ColumnarStore" => build!(ColumnarStore{String, Float64}()),
    "ThreadSafe(Col)" => build!(ThreadSafe(ColumnarStore{String, Float64}())),
    "SQLiteStore" => build!(SQLiteStore{String, Float64}(":memory:")),
    "DuckDBStore" => build!(DuckDBStore{String, Float64}(":memory:")),
]

function querybatch(q)
    rng = MersenneTwister(q)
    return (["e$(rand(rng, 1:N))" for _ in 1:q], fill(Date(2024, 6, 1), q), fill(TX[2], q))
end

u(x) = x < 1.0e-3 ? (@sprintf "%.0f µs" x * 1.0e6) : (@sprintf "%.1f ms" x * 1.0e3)

println("threads available: ", Threads.nthreads())
for q in (10_000, 100_000, 1_000_000)
    k, v, t = querybatch(q)
    println("\n## batch = $q")
    @printf "%-16s %9s %11s %11s %9s\n" "backend" "reads" "serial" "threaded" "speedup"
    for (name, s) in stores
        @assert as_of_batch(s, k, v, t) == as_of_batch(s, k, v, t; threaded = true)
        ts = @belapsed as_of_batch($s, $k, $v, $t) seconds = 1
        tp = @belapsed as_of_batch($s, $k, $v, $t; threaded = true) seconds = 1
        readmode = supports_parallel_reads(s) ? "parallel" : "serial"
        @printf "%-16s %9s %11s %11s %8.1fx\n" name readmode u(ts) u(tp) (ts / tp)
    end
end
