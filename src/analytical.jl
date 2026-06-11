# Analytical operations built on `snapshot`. Each is a default method on
# `BitemporalStore`; a backend may override any one with a faster native path.

"""
    asof_join(a, b; effective_at = now(UTC), assertive_at = now(UTC)) -> NamedTuple of column vectors

Inner-join two stores on `entity` at one `(effective_at, assertive_at)` point. The stores
must share the key type `K`. Columns `entity`, `a`, `b`, with one row per entity
that has a value in both stores at that point (entities in only one store are
dropped). Tables.jl-compatible.

Reads each store with its own `snapshot`, so wrapping the inputs in
[`ThreadSafe`](@ref) makes each snapshot atomic but not the join as a whole: a
join across two concurrently-written stores is not a single point-in-time read.
"""
function asof_join(
        a::BitemporalStore{K, Va}, b::BitemporalStore{K, Vb};
        effective_at::TimeType = now(UTC), assertive_at::TimeType = now(UTC),
    ) where {K, Va, Vb}
    sa = snapshot(a; effective_at, assertive_at)
    sb = snapshot(b; effective_at, assertive_at)
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
    diff(s; assertive_at_old, assertive_at_new) -> NamedTuple of column vectors

Records whose currently-asserted value changed between two assertive times.
Columns `entity`, `effective_from`, `effective_to`, `old_value`, `new_value`, `kind`,
where `kind` is one of `:inserted` (present only at `assertive_at_new`), `:retracted`
(present only at `assertive_at_old`), or `:corrected` (same `(entity, effective_from,
effective_to)`, different value). Unchanged rows are omitted, so the result is empty
iff nothing the store believes changed. Extends `Base.diff`. Tables.jl-compatible.
"""
function Base.diff(
        s::BitemporalStore{K, V}; assertive_at_old::TimeType, assertive_at_new::TimeType,
    ) where {K, V}
    asmap(snap) = Dict{Tuple{K, DateTime, DateTime}, V}(
        (snap.entity[i], snap.effective_from[i], snap.effective_to[i]) => snap.value[i]
            for i in eachindex(snap.entity)
    )
    oldmap = asmap(snapshot(s; assertive_at = assertive_at_old))
    newmap = asmap(snapshot(s; assertive_at = assertive_at_new))

    entity = K[]
    effective_from = DateTime[]
    effective_to = DateTime[]
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
        push!(effective_from, k[2])
        push!(effective_to, k[3])
        push!(old_value, ov)
        push!(new_value, nv)
        push!(kind, kd)
    end
    return (
        entity = entity, effective_from = effective_from, effective_to = effective_to,
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

"""
    as_of_batch(s, keys, effective_ats, assertive_ats; threaded = false) -> Vector{Union{V,Nothing}}

Vectorised [`as_of`](@ref): position `i` holds the value asserted at `assertive_ats[i]`
to hold at `effective_ats[i]` for `keys[i]`, or `nothing`. Fetches each key's records
once instead of per call.

With `threaded = true` the batch is split across threads (running serially when
only one is available), picking a strategy from [`supports_parallel_reads`](@ref):
backends with parallel reads fetch one query per thread; the others fetch records
serially (one per distinct key, connection-safe) and thread only the per-query
scan.
"""
function as_of_batch(
        s::BitemporalStore{K, V}, keys::Vector{K},
        effective_ats::Vector{<:TimeType}, assertive_ats::Vector{<:TimeType}; threaded::Bool = false,
    ) where {K, V}
    n = length(keys)
    (length(effective_ats) == n && length(assertive_ats) == n) ||
        throw(DimensionMismatch("keys, effective_ats, and assertive_ats must have equal length"))
    valid_dts = _instant.(effective_ats)
    tx_dts = _instant.(assertive_ats)
    if !threaded
        return _batch_grouped(s, keys, valid_dts, tx_dts)
    elseif supports_parallel_reads(s)
        return _batch_flat(s, keys, valid_dts, tx_dts)
    else
        return _batch_prefetch(s, keys, valid_dts, tx_dts)
    end
end

# One `get_records` per distinct key, then scan its queries.
function _batch_grouped(s::BitemporalStore{K, V}, keys, effective_ats, assertive_ats) where {K, V}
    result = Vector{Union{V, Nothing}}(undef, length(keys))
    bykey = Dict{K, Vector{Int}}()
    for i in eachindex(keys)
        push!(get!(() -> Int[], bykey, keys[i]), i)
    end
    for (key, idxs) in bykey
        recs = get_records(s, key)
        for i in idxs
            result[i] = _pick(recs, effective_ats[i], assertive_ats[i])
        end
    end
    return result
end

# Thread over the queries. Only safe when `get_records` is cheap and thread-safe.
function _batch_flat(s::BitemporalStore{K, V}, keys, effective_ats, assertive_ats) where {K, V}
    result = Vector{Union{V, Nothing}}(undef, length(keys))
    @threads for i in eachindex(keys)
        result[i] = _pick(get_records(s, keys[i]), effective_ats[i], assertive_ats[i])
    end
    return result
end

# Fetch serially (safe on one connection), then thread the scan over the cache.
function _batch_prefetch(s::BitemporalStore{K, V}, keys, effective_ats, assertive_ats) where {K, V}
    result = Vector{Union{V, Nothing}}(undef, length(keys))
    cache = Dict{K, Vector{Record{V}}}()
    for k in keys
        haskey(cache, k) || (cache[k] = get_records(s, k))
    end
    @threads for i in eachindex(keys)
        result[i] = _pick(cache[keys[i]], effective_ats[i], assertive_ats[i])
    end
    return result
end
