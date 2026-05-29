"""
    MemoryStore{K,V}()

In-memory reference backend. Records are kept per key in append order; `id` is
`(key, index)` so [`close_tx!`](@ref) is an O(1) lookup. Not thread-safe; wrap
in [`ThreadSafe`](@ref) for concurrent use.
"""
mutable struct MemoryStore{K, V} <: BitemporalStore{K, V}
    records::Dict{K, Vector{Record{V}}}
end

MemoryStore{K, V}() where {K, V} = MemoryStore{K, V}(Dict{K, Vector{Record{V}}}())

get_records(s::MemoryStore{K, V}, key) where {K, V} = get(() -> Record{V}[], s.records, key)

function put_record!(s::MemoryStore{K, V}, key, r::Record{V}) where {K, V}
    vec = get!(() -> Record{V}[], s.records, key)
    stored = Record{V}((key, length(vec) + 1), r.value, r.valid_from, r.valid_to, r.tx_from, r.tx_to)
    push!(vec, stored)
    return stored
end

function close_tx!(s::MemoryStore, (key, idx)::Tuple, ts::DateTime)
    r = s.records[key][idx]
    _believed(r) && (s.records[key][idx] = _close(r, ts))
    return nothing
end

entities(s::MemoryStore) = keys(s.records)
