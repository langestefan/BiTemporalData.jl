"""
    ColumnarStore{K,V}()

In-memory **struct-of-arrays** backend: every record field is a column in one
contiguous vector, with a per-key index of row positions. Same semantics as
[`MemoryStore`](@ref), but laid out so that [`snapshot`](@ref) is a single linear
pass that builds the value column directly (no per-record objects, no
deserialization).

This is the read path for ML / bulk-analytics workloads: a `snapshot`'s `value`
column comes out as a contiguous `Vector{V}`, ready to hand to a model or copy to
a device in one shot. Not thread-safe; wrap in [`ThreadSafe`](@ref) for concurrent
use.
"""
struct ColumnarStore{K, V} <: BitemporalStore{K, V}
    key::Vector{K}
    value::Vector{V}
    effective_from::Vector{DateTime}
    effective_to::Vector{DateTime}
    assertive_from::Vector{DateTime}
    assertive_to::Vector{DateTime}
    index::Dict{K, Vector{Int}}   # key -> row positions, in append order
end

function ColumnarStore{K, V}() where {K, V}
    return ColumnarStore{K, V}(
        K[], V[], DateTime[], DateTime[], DateTime[], DateTime[], Dict{K, Vector{Int}}(),
    )
end

# Build the i-th row back into a `Record`. `id` is the row position.
_row(s::ColumnarStore{K, V}, i::Int) where {K, V} =
    Record{V}(i, s.value[i], s.effective_from[i], s.effective_to[i], s.assertive_from[i], s.assertive_to[i])

function get_records(s::ColumnarStore{K, V}, key) where {K, V}
    rows = get(() -> Int[], s.index, key)
    return Record{V}[_row(s, i) for i in rows]
end

# The as_of value for `key`, read from the columns. `nothing` if absent.
function _value_at(s::ColumnarStore{K, V}, key, effective_at::DateTime, assertive_at::DateTime) where {K, V}
    rows = get(s.index, key, nothing)
    rows === nothing && return nothing
    best = 0
    for i in rows
        # `>=` so a later write at the same assertive_from wins the tie (append order; T6).
        if s.assertive_from[i] <= assertive_at < s.assertive_to[i] && s.effective_from[i] <= effective_at < s.effective_to[i] &&
                (best == 0 || s.assertive_from[i] >= s.assertive_from[best])
            best = i
        end
    end
    return best == 0 ? nothing : s.value[best]
end

function put_record!(s::ColumnarStore{K, V}, key, r::Record{V}) where {K, V}
    push!(s.key, key)             # `Vector{K}` / `Dict{K,…}` normalize the key type
    push!(s.value, r.value)
    push!(s.effective_from, r.effective_from)
    push!(s.effective_to, r.effective_to)
    push!(s.assertive_from, r.assertive_from)
    push!(s.assertive_to, r.assertive_to)
    i = length(s.key)
    push!(get!(() -> Int[], s.index, key), i)
    return Record{V}(i, r.value, r.effective_from, r.effective_to, r.assertive_from, r.assertive_to)
end

function close_tx!(s::ColumnarStore, i::Int, asserted_at::DateTime)
    s.assertive_to[i] == MAX_DT && (s.assertive_to[i] = asserted_at)   # idempotent
    return nothing
end

# Snapshot the keys (not the live `KeySet`): see `entities(::MemoryStore)`. The
# native `snapshot`/`as_of` below iterate `keys(s.index)` directly, internally.
entities(s::ColumnarStore) = collect(keys(s.index))

supports_parallel_reads(::ColumnarStore) = true

# One pass over the columns, so `value` comes out contiguous.
function snapshot(
        s::ColumnarStore{K, V};
        effective_at::Union{TimeType, Nothing} = nothing, assertive_at::TimeType = now(UTC),
    ) where {K, V}
    txd = _instant(assertive_at)
    if effective_at === nothing
        rows = findall(i -> s.assertive_from[i] <= txd < s.assertive_to[i], eachindex(s.key))
        return (
            entity = s.key[rows],
            value = s.value[rows],
            effective_from = s.effective_from[rows],
            effective_to = s.effective_to[rows],
        )
    else
        va = _instant(effective_at)
        ent = K[]
        val = V[]
        for key in keys(s.index)
            v = _value_at(s, key, va, txd)
            v === nothing || (push!(ent, key); push!(val, v))
        end
        return (entity = ent, value = val)
    end
end

# as_of/as_of_batch read the columns directly to skip building Records.
function as_of(
        s::ColumnarStore{K, V}, key;
        effective_at::TimeType = now(UTC), assertive_at::TimeType = now(UTC),
    ) where {K, V}
    return _value_at(s, key, _instant(effective_at), _instant(assertive_at))
end

function as_of_batch(
        s::ColumnarStore{K, V}, keys::Vector{K},
        effective_ats::Vector{<:TimeType}, assertive_ats::Vector{<:TimeType}; threaded::Bool = false,
    ) where {K, V}
    n = length(keys)
    (length(effective_ats) == n && length(assertive_ats) == n) ||
        throw(DimensionMismatch("keys, effective_ats, and assertive_ats must have equal length"))
    valid_dts = _instant.(effective_ats)
    tx_dts = _instant.(assertive_ats)
    result = Vector{Union{V, Nothing}}(undef, n)
    if threaded
        @threads for i in eachindex(keys)
            result[i] = _value_at(s, keys[i], valid_dts[i], tx_dts[i])
        end
    else
        for i in eachindex(keys)
            result[i] = _value_at(s, keys[i], valid_dts[i], tx_dts[i])
        end
    end
    return result
end
