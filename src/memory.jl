"""
    MemoryStore{K,V}()

In-memory reference backend for [`BitemporalStore`](@ref). Records are kept in
append order per key in a `Dict{K,Vector{Record{V}}}`. The record `id` is a
`Tuple{K,Int}` (key plus 1-based position), so [`close_tx!`](@ref) is an O(1)
lookup. Not thread-safe; wrap in a `ReentrantLock` if needed.
"""
mutable struct MemoryStore{K, V} <: BitemporalStore{K, V}
    records::Dict{K, Vector{Record{V}}}
end

MemoryStore{K, V}() where {K, V} = MemoryStore{K, V}(Dict{K, Vector{Record{V}}}())

get_records(s::MemoryStore{K, V}, key) where {K, V} =
    get(() -> Record{V}[], s.records, key)

function put_record!(s::MemoryStore{K, V}, key, record::Record{V}) where {K, V}
    vec = get!(() -> Record{V}[], s.records, key)
    idx = length(vec) + 1
    populated = Record{V}(
        (key, idx),
        record.value,
        record.valid_from,
        record.valid_to,
        record.tx_from,
        record.tx_to,
    )
    push!(vec, populated)
    return populated
end

function close_tx!(s::MemoryStore, id::Tuple, ts::DateTime)
    key, idx = id
    vec = s.records[key]
    r = vec[idx]
    if r.tx_to == MAX_DT
        vec[idx] = _close(r, ts)
    end
    return nothing
end

entities(s::MemoryStore) = keys(s.records)
