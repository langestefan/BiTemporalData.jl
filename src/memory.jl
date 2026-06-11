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
    stored = Record{V}((key, length(vec) + 1), r.value, r.effective_from, r.effective_to, r.assertive_from, r.assertive_to)
    push!(vec, stored)
    return stored
end

function close_tx!(s::MemoryStore, (key, idx)::Tuple, asserted_at::DateTime)
    r = s.records[key][idx]
    _asserted(r) && (s.records[key][idx] = _close(r, asserted_at))
    return nothing
end

# Snapshot the keys (not the live `KeySet`): callers, including those behind
# `ThreadSafe`, iterate the result after the lock is released.
entities(s::MemoryStore) = collect(keys(s.records))

supports_parallel_reads(::MemoryStore) = true
