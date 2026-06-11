"""
    snapshot(s; effective_at = nothing, assertive_at = now(UTC)) -> NamedTuple of column vectors

Columnar point-in-time view of the whole store, the read boundary for bulk
workloads, since freezing `assertive_at` is reproducible and leakage-proof. With
`effective_at = nothing`, one row per record asserted at `assertive_at`, columns
`entity, value, effective_from, effective_to`. With a `effective_at` (any `TimeType`), the
collapsed cross-section: columns `entity, value`, one row per entity that has a
value there. Tables.jl-compatible.

Row order is backend-defined: a backend with a native `snapshot` (e.g.
`DuckDBStore`) may return rows in a different order than the generic path. Do not
rely on it; sort or index by `entity` if you need a stable order.
"""
function snapshot(
        s::BitemporalStore{K, V};
        effective_at::Union{TimeType, Nothing} = nothing, assertive_at::TimeType = now(UTC),
    ) where {K, V}
    txd = _instant(assertive_at)
    if effective_at === nothing
        rows = [
            (key, r) for key in entities(s) for r in get_records(s, key)
                if r.assertive_from <= txd < r.assertive_to
        ]
        return (
            entity = K[p[1] for p in rows],
            value = V[p[2].value for p in rows],
            effective_from = DateTime[p[2].effective_from for p in rows],
            effective_to = DateTime[p[2].effective_to for p in rows],
        )
    else
        va = _instant(effective_at)
        rows = [(key, as_of(s, key; effective_at = va, assertive_at = txd)) for key in entities(s)]
        present = [p for p in rows if p[2] !== nothing]
        return (entity = K[p[1] for p in present], value = V[p[2] for p in present])
    end
end
