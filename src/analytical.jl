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
    as_of_batch(s, keys, valid_ats, tx_ats) -> Vector{Union{V,Nothing}}

Vectorised [`as_of`](@ref): position `i` holds the value believed at `tx_ats[i]`
to hold at `valid_ats[i]` for `keys[i]`, or `nothing`. Equivalent to broadcasting
`as_of`, but fetches each key's records once instead of per call.
"""
function as_of_batch(
        s::BitemporalStore{K, V}, keys::Vector{K},
        valid_ats::Vector{Date}, tx_ats::Vector{DateTime},
    ) where {K, V}
    n = length(keys)
    (length(valid_ats) == n && length(tx_ats) == n) ||
        throw(DimensionMismatch("keys, valid_ats, and tx_ats must have equal length"))
    result = Vector{Union{V, Nothing}}(undef, n)
    bykey = Dict{K, Vector{Int}}()
    for i in 1:n
        push!(get!(() -> Int[], bykey, keys[i]), i)
    end
    for (key, idxs) in bykey
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
