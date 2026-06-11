"""
    SQLiteStore{K,V}(path::AbstractString; table = "records")
    SQLiteStore{K,V}(db::SQLite.DB; table = "records")

SQLite-backed bitemporal store. Requires the SQLite extension: run
`using SQLite` to load it. Pass a file `path` for a persistent store, or
`":memory:"` for an ephemeral one.

Keys and values are stored via `Serialization` (so any `K`/`V` work); dates are
stored as integers (`Dates.value`). The record `id` is the SQLite rowid.
Multi-step writes (`correct!`, `amend!`, `retract!`) run inside a SQLite
transaction (see [`with_write_tx`](@ref)), so a crash mid-write rolls back.

Two things to note:

  - The on-disk format is tied to the Julia serialization version, so a database
    file is not guaranteed to be readable by a different major Julia version.
  - Key lookups compare the *serialized bytes* of the key, so keys are reliable
    for types whose serialization is a pure function of equality (`String`,
    `Symbol`, integers, ...) within one serializer version. Avoid keys whose
    bytes can differ between two equal values.
"""
struct SQLiteStore{K, V, DB} <: BitemporalStore{K, V}
    db::DB
    table::String
end

# Friendly error when the SQLite extension is not loaded. The extension defines
# the real (more specific) `::AbstractString` / `::SQLite.DB` constructors.
function SQLiteStore{K, V}(args...; kwargs...) where {K, V}
    return error("SQLiteStore requires the SQLite extension; run `using SQLite` first.")
end
