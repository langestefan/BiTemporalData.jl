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
    valid_from::Vector{Date}
    valid_to::Vector{Date}
    tx_from::Vector{DateTime}
    tx_to::Vector{DateTime}
    index::Dict{K, Vector{Int}}   # key -> row positions, in append order
end

function ColumnarStore{K, V}() where {K, V}
    return ColumnarStore{K, V}(
        K[], V[], Date[], Date[], DateTime[], DateTime[], Dict{K, Vector{Int}}(),
    )
end

# Build the i-th row back into a `Record`. `id` is the row position.
_row(s::ColumnarStore{K, V}, i::Int) where {K, V} =
    Record{V}(i, s.value[i], s.valid_from[i], s.valid_to[i], s.tx_from[i], s.tx_to[i])

function get_records(s::ColumnarStore{K, V}, key) where {K, V}
    rows = get(() -> Int[], s.index, key)
    return Record{V}[_row(s, i) for i in rows]
end

function put_record!(s::ColumnarStore{K, V}, key, r::Record{V}) where {K, V}
    push!(s.key, key)             # `Vector{K}` / `Dict{K,…}` normalize the key type
    push!(s.value, r.value)
    push!(s.valid_from, r.valid_from)
    push!(s.valid_to, r.valid_to)
    push!(s.tx_from, r.tx_from)
    push!(s.tx_to, r.tx_to)
    i = length(s.key)
    push!(get!(() -> Int[], s.index, key), i)
    return Record{V}(i, r.value, r.valid_from, r.valid_to, r.tx_from, r.tx_to)
end

function close_tx!(s::ColumnarStore, i::Int, ts::DateTime)
    s.tx_to[i] == MAX_DT && (s.tx_to[i] = ts)   # idempotent
    return nothing
end

entities(s::ColumnarStore) = keys(s.index)

# Native snapshot: one linear scan over the columns; the `value` column is built
# contiguously without rebuilding any `Record`.
function snapshot(
        s::ColumnarStore{K, V};
        valid_at::Union{Date, Nothing} = nothing, tx_at::DateTime = now(),
    ) where {K, V}
    if valid_at === nothing
        rows = findall(i -> s.tx_from[i] <= tx_at < s.tx_to[i], eachindex(s.key))
        return (
            entity = s.key[rows],
            value = s.value[rows],
            valid_from = s.valid_from[rows],
            valid_to = s.valid_to[rows],
        )
    else
        ent = K[]
        val = V[]
        for (key, rows) in s.index
            best = 0
            for i in rows
                if s.tx_from[i] <= tx_at < s.tx_to[i] &&
                        s.valid_from[i] <= valid_at < s.valid_to[i] &&
                        (best == 0 || s.tx_from[i] > s.tx_from[best])
                    best = i
                end
            end
            best != 0 && (push!(ent, key); push!(val, s.value[best]))
        end
        return (entity = ent, value = val)
    end
end
