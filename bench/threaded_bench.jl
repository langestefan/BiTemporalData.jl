# Does multithreading help the batch read path? Run with:
#   julia -t auto --project=bench bench/threaded_bench.jl
#
# `as_of_batch` answers many independent point-in-time lookups; grouped by key it
# is embarrassingly parallel (disjoint result slots, read-only record access). We
# sweep the batch size to find where threading starts to pay off and what speedup
# is real.

using BiTemporalData, Dates, Printf, Random
using BenchmarkTools

const N = 5_000                       # entities
const TX = [DateTime(2024, 1, d) for d in 1:3]

store = ColumnarStore{String, Float64}()
for i in 1:N
    k = "e$i"
    insert!(store, k, float(i); valid_from = Date(2024, 1, 1), ts = TX[1])
    correct!(store, k, float(i) + 0.1; valid_from = Date(2024, 1, 1), ts = TX[2])
    correct!(store, k, float(i) + 0.2; valid_from = Date(2024, 1, 1), ts = TX[3])
end

# Threaded `as_of_batch`: one task group over the distinct keys. Each key's query
# indices are disjoint, so `result[i]` writes never collide; `get_records` is a
# read, safe to run concurrently while nothing writes to the store.
function as_of_batch_threaded(s::BitemporalStore{K, V}, keys, valid_ats, tx_ats) where {K, V}
    n = length(keys)
    result = Vector{Union{V, Nothing}}(undef, n)
    bykey = Dict{K, Vector{Int}}()
    for i in 1:n
        push!(get!(() -> Int[], bykey, keys[i]), i)
    end
    groups = collect(bykey)
    Threads.@threads for g in eachindex(groups)
        key, idxs = groups[g]
        recs = get_records(s, key)
        for i in idxs
            va, ta = valid_ats[i], tx_ats[i]
            best = nothing
            for r in recs
                if r.tx_from <= ta < r.tx_to && r.valid_from <= va < r.valid_to &&
                        (best === nothing || r.tx_from > best.tx_from)
                    best = r
                end
            end
            result[i] = best === nothing ? nothing : best.value
        end
    end
    return result
end

# Ungrouped: thread straight over the queries (get_records per query). More total
# work, but no serial grouping step.
function as_of_batch_flat(s::BitemporalStore{K, V}, keys, valid_ats, tx_ats) where {K, V}
    n = length(keys)
    result = Vector{Union{V, Nothing}}(undef, n)
    Threads.@threads for i in 1:n
        va, ta = valid_ats[i], tx_ats[i]
        best = nothing
        for r in get_records(s, keys[i])
            if r.tx_from <= ta < r.tx_to && r.valid_from <= va < r.valid_to &&
                    (best === nothing || r.tx_from > best.tx_from)
                best = r
            end
        end
        result[i] = best === nothing ? nothing : best.value
    end
    return result
end

# How much of the serial time is just the (unthreadable) key grouping?
function group_only(keys::Vector{K}) where {K}
    bykey = Dict{K, Vector{Int}}()
    for i in eachindex(keys)
        push!(get!(() -> Int[], bykey, keys[i]), i)
    end
    return length(bykey)
end

function batch(q, rng)
    keys = ["e$(rand(rng, 1:N))" for _ in 1:q]
    valid_ats = fill(Date(2024, 6, 1), q)
    tx_ats = fill(TX[3], q)
    return keys, valid_ats, tx_ats
end

println("threads available: ", Threads.nthreads(), "   |   $N entities x 3 records\n")
@printf "%10s %11s %11s %9s %11s %9s %10s\n" "batch" "serial" "grouped" "speedup" "flat" "speedup" "group/serial"
rng = MersenneTwister(1)
for q in (1_000, 10_000, 100_000, 1_000_000)
    k, v, t = batch(q, rng)
    @assert as_of_batch(store, k, v, t) == as_of_batch_threaded(store, k, v, t) == as_of_batch_flat(store, k, v, t)
    ts = @belapsed as_of_batch($store, $k, $v, $t)
    tg = @belapsed as_of_batch_threaded($store, $k, $v, $t)
    tf = @belapsed as_of_batch_flat($store, $k, $v, $t)
    tgrp = @belapsed group_only($k)
    u(x) = x < 1.0e-3 ? (@sprintf "%.0f µs" x * 1.0e6) : (@sprintf "%.1f ms" x * 1.0e3)
    @printf "%10d %11s %11s %8.1fx %11s %8.1fx %9.0f%%\n" q u(ts) u(tg) (ts / tg) u(tf) (ts / tf) (100tgrp / ts)
end
