"""
    DuckDBStore{K,V}(path::AbstractString; table = "records")
    DuckDBStore{K,V}(db::DuckDB.DB; table = "records")

DuckDB-backed bitemporal store. Requires the DuckDB extension: run `using DuckDB`
to load it. Pass a file `path` for a persistent store, or `":memory:"` for an
ephemeral one.

DuckDB is columnar, so it overrides [`snapshot`](@ref) with a single native query:
the read boundary for bulk/analytics workloads is one indexed scan rather than a
per-entity walk. Keys and values are stored via `Serialization` (so any `K`/`V`
work); dates are stored as integers (`Dates.value`). The record `id` comes from a
DuckDB sequence. Multi-step writes (`correct!`, `amend!`, `retract!`) run inside a
DuckDB transaction (see [`with_write_tx`](@ref)), so a crash mid-write rolls back.

Two things to note:

  - The on-disk format is tied to the Julia serialization version, so a database
    file is not guaranteed to be readable by a different major Julia version.
  - Key lookups compare the *serialized bytes* of the key, so keys are reliable
    for types whose serialization is a pure function of equality (`String`,
    `Symbol`, integers, ...) within one serializer version. Avoid keys whose
    bytes can differ between two equal values.
"""
struct DuckDBStore{K, V, DB} <: BitemporalStore{K, V}
    db::DB
    table::String
end

# Friendly error when the DuckDB extension is not loaded. The extension defines
# the real (more specific) `::AbstractString` / `::DuckDB.DB` constructors.
function DuckDBStore{K, V}(args...; kwargs...) where {K, V}
    return error("DuckDBStore requires the DuckDB extension; run `using DuckDB` first.")
end
