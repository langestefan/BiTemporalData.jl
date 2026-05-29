"""
    snapshot(s; valid_at = nothing, tx_at = now()) -> NamedTuple of column vectors

Columnar point-in-time view of the whole store — the read boundary for bulk
workloads, since freezing `tx_at` is reproducible and leakage-proof. With
`valid_at = nothing`, one row per record believed at `tx_at`, columns
`entity, value, valid_from, valid_to`. With a `valid_at::Date`, the collapsed
cross-section: columns `entity, value`, one row per entity that has a value
there. Tables.jl-compatible.
"""
function snapshot(
        s::BitemporalStore{K, V};
        valid_at::Union{Date, Nothing} = nothing, tx_at::DateTime = now(),
    ) where {K, V}
    if valid_at === nothing
        rows = [
            (key, r) for key in entities(s) for r in get_records(s, key)
                if r.tx_from <= tx_at < r.tx_to
        ]
        return (
            entity = K[p[1] for p in rows],
            value = V[p[2].value for p in rows],
            valid_from = Date[p[2].valid_from for p in rows],
            valid_to = Date[p[2].valid_to for p in rows],
        )
    else
        rows = [(key, as_of(s, key; valid_at, tx_at)) for key in entities(s)]
        present = [p for p in rows if p[2] !== nothing]
        return (entity = K[p[1] for p in present], value = V[p[2] for p in present])
    end
end
