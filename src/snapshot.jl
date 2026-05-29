"""
    snapshot(s::BitemporalStore; valid_at = nothing, tx_at = now()) -> NamedTuple of column vectors

A flat, columnar, immutable materialized view of the whole store, built in one
linear pass over [`entities`](@ref) and [`get_records`](@ref). This is the
intended read boundary for read-heavy workloads (ML training, bulk analytics):
freezing `tx_at` makes the result reproducible and point-in-time leakage-proof.

Two modes, selected by `valid_at`:

- **`valid_at = nothing` (default)** — the full transaction-time slice. One row
  per record believed at `tx_at` (`tx_from <= tx_at < tx_to`), with columns
  `entity`, `value`, `valid_from`, `valid_to`.
- **`valid_at::Date`** — a collapsed cross-section: one value per entity at the
  single point `(valid_at, tx_at)`, with columns `entity`, `value`. Entities
  with no value at that point are omitted.

The returned `NamedTuple` of equal-length vectors is a Tables.jl-compatible
column table.
"""
function snapshot(
        s::BitemporalStore{K, V};
        valid_at::Union{Date, Nothing} = nothing,
        tx_at::DateTime = now(),
    ) where {K, V}
    if valid_at === nothing
        entity = K[]
        value = V[]
        valid_from = Date[]
        valid_to = Date[]
        for key in entities(s)
            for r in get_records(s, key)
                if r.tx_from <= tx_at < r.tx_to
                    push!(entity, key)
                    push!(value, r.value)
                    push!(valid_from, r.valid_from)
                    push!(valid_to, r.valid_to)
                end
            end
        end
        return (entity = entity, value = value, valid_from = valid_from, valid_to = valid_to)
    else
        entity = K[]
        value = V[]
        for key in entities(s)
            v = as_of(s, key; valid_at = valid_at, tx_at = tx_at)
            if v !== nothing
                push!(entity, key)
                push!(value, v)
            end
        end
        return (entity = entity, value = value)
    end
end
