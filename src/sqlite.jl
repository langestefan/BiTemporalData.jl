"""
    SQLiteStore{K,V}(path::AbstractString; table = "records")
    SQLiteStore{K,V}(db::SQLite.DB; table = "records")

SQLite-backed bitemporal store. Requires the SQLite extension: run
`using SQLite` to load it. Pass a file `path` for a persistent store, or
`":memory:"` for an ephemeral one.

Keys and values are stored via `Serialization` (so any `K`/`V` work); dates are
stored as integers (`Dates.value`). The record `id` is the SQLite rowid.

Two limitations to note:

  - The on-disk format is tied to the Julia serialization version, so a database
    file is not guaranteed to be readable by a different major Julia version.
  - Like [`MemoryStore`](@ref), multi-step writes (`correct!`, `amend!`) are not
    atomic across a crash.
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
