# Analytical operations built on `snapshot`. Each is a default method on
# `BitemporalStore`; a backend may override any one with a faster native path.

"""
    asof_join(a, b; valid_at = today(), tx_at = now()) -> NamedTuple of column vectors

Inner-join two stores on `entity` at one `(valid_at, tx_at)` point. The stores
must share the key type `K`. Columns `entity`, `a`, `b`, with one row per entity
that has a value in both stores at that point (entities in only one store are
dropped). Tables.jl-compatible.
"""
function asof_join(
        a::BitemporalStore{K, Va}, b::BitemporalStore{K, Vb};
        valid_at::Date = today(), tx_at::DateTime = now(),
    ) where {K, Va, Vb}
    sa = snapshot(a; valid_at, tx_at)
    sb = snapshot(b; valid_at, tx_at)
    bvals = Dict{K, Vb}(zip(sb.entity, sb.value))
    entity = K[]
    avalue = Va[]
    bvalue = Vb[]
    for (e, va) in zip(sa.entity, sa.value)
        haskey(bvals, e) || continue
        push!(entity, e)
        push!(avalue, va)
        push!(bvalue, bvals[e])
    end
    return (entity = entity, a = avalue, b = bvalue)
end

"""
    diff(s; tx_at_old, tx_at_new) -> NamedTuple of column vectors

Records whose currently-believed value changed between two transaction times.
Columns `entity`, `valid_from`, `valid_to`, `old_value`, `new_value`, `kind`,
where `kind` is one of `:inserted` (present only at `tx_at_new`), `:retracted`
(present only at `tx_at_old`), or `:corrected` (same `(entity, valid_from,
valid_to)`, different value). Unchanged rows are omitted, so the result is empty
iff nothing the store believes changed. Extends `Base.diff`. Tables.jl-compatible.
"""
function Base.diff(
        s::BitemporalStore{K, V}; tx_at_old::DateTime, tx_at_new::DateTime,
    ) where {K, V}
    asmap(snap) = Dict{Tuple{K, Date, Date}, V}(
        (snap.entity[i], snap.valid_from[i], snap.valid_to[i]) => snap.value[i]
            for i in eachindex(snap.entity)
    )
    oldmap = asmap(snapshot(s; tx_at = tx_at_old))
    newmap = asmap(snapshot(s; tx_at = tx_at_new))

    entity = K[]
    valid_from = Date[]
    valid_to = Date[]
    old_value = Union{V, Nothing}[]
    new_value = Union{V, Nothing}[]
    kind = Symbol[]
    for k in union(keys(oldmap), keys(newmap))
        old_hit = haskey(oldmap, k)
        new_hit = haskey(newmap, k)
        if old_hit && new_hit
            oldmap[k] == newmap[k] && continue
            ov, nv, kd = oldmap[k], newmap[k], :corrected
        elseif new_hit
            ov, nv, kd = nothing, newmap[k], :inserted
        else
            ov, nv, kd = oldmap[k], nothing, :retracted
        end
        push!(entity, k[1])
        push!(valid_from, k[2])
        push!(valid_to, k[3])
        push!(old_value, ov)
        push!(new_value, nv)
        push!(kind, kd)
    end
    return (
        entity = entity, valid_from = valid_from, valid_to = valid_to,
        old_value = old_value, new_value = new_value, kind = kind,
    )
end

"""
    supports_parallel_reads(s) -> Bool

Whether [`get_records`](@ref) on `s` is cheap and safe to call from many threads
at once. In-memory backends (`MemoryStore`, `ColumnarStore`) return `true`;
backends over a single mutable connection (`SQLiteStore`, `DuckDBStore`) keep the
`false` default. This selects the strategy `as_of_batch(...; threaded = true)`
uses, so a new backend only overrides it when concurrent `get_records` is safe.
"""
supports_parallel_reads(::BitemporalStore) = false

# The believed value for one query, scanned from a key's records (the `as_of`
# pick: latest `tx_from` among records covering both `tx_at` and `valid_at`).
function _pick(recs, valid_at::Date, tx_at::DateTime)
    best = nothing
    for r in recs
        if r.tx_from <= tx_at < r.tx_to && r.valid_from <= valid_at < r.valid_to &&
                (best === nothing || r.tx_from > best.tx_from)
            best = r
        end
    end
    return best === nothing ? nothing : best.value
end

"""
    as_of_batch(s, keys, valid_ats, tx_ats; threaded = false) -> Vector{Union{V,Nothing}}

Vectorised [`as_of`](@ref): position `i` holds the value believed at `tx_ats[i]`
to hold at `valid_ats[i]` for `keys[i]`, or `nothing`. Fetches each key's records
once instead of per call.

With `threaded = true` (and `Threads.nthreads() > 1`) the batch is split across
threads, picking a strategy from [`supports_parallel_reads`](@ref): backends with
parallel reads fetch one query per thread; the others fetch records serially (one
per distinct key, connection-safe) and thread only the per-query scan.
"""
function as_of_batch(
        s::BitemporalStore{K, V}, keys::Vector{K},
        valid_ats::Vector{Date}, tx_ats::Vector{DateTime}; threaded::Bool = false,
    ) where {K, V}
    n = length(keys)
    (length(valid_ats) == n && length(tx_ats) == n) ||
        throw(DimensionMismatch("keys, valid_ats, and tx_ats must have equal length"))
    if !threaded || nthreads() == 1
        return _batch_grouped(s, keys, valid_ats, tx_ats)
    elseif supports_parallel_reads(s)
        return _batch_flat(s, keys, valid_ats, tx_ats)
    else
        return _batch_prefetch(s, keys, valid_ats, tx_ats)
    end
end

# Serial: one `get_records` per distinct key, then scan that key's queries.
function _batch_grouped(s::BitemporalStore{K, V}, keys, valid_ats, tx_ats) where {K, V}
    result = Vector{Union{V, Nothing}}(undef, length(keys))
    bykey = Dict{K, Vector{Int}}()
    for i in eachindex(keys)
        push!(get!(() -> Int[], bykey, keys[i]), i)
    end
    for (key, idxs) in bykey
        recs = get_records(s, key)
        for i in idxs
            result[i] = _pick(recs, valid_ats[i], tx_ats[i])
        end
    end
    return result
end

# Parallel reads: thread straight over the queries (no serial grouping step).
# Only valid when `get_records` is cheap and concurrency-safe.
function _batch_flat(s::BitemporalStore{K, V}, keys, valid_ats, tx_ats) where {K, V}
    result = Vector{Union{V, Nothing}}(undef, length(keys))
    @threads for i in eachindex(keys)
        result[i] = _pick(get_records(s, keys[i]), valid_ats[i], tx_ats[i])
    end
    return result
end

# Serial connection-safe fetch (one `get_records` per distinct key) into a cache,
# then a parallel scan that only touches the cache, never the store.
function _batch_prefetch(s::BitemporalStore{K, V}, keys, valid_ats, tx_ats) where {K, V}
    result = Vector{Union{V, Nothing}}(undef, length(keys))
    cache = Dict{K, Vector{Record{V}}}()
    for k in keys
        haskey(cache, k) || (cache[k] = get_records(s, k))
    end
    @threads for i in eachindex(keys)
        result[i] = _pick(cache[keys[i]], valid_ats[i], tx_ats[i])
    end
    return result
end
