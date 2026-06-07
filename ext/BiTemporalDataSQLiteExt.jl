module BiTemporalDataSQLiteExt

# SQLite re-exports DBInterface, so loading SQLite is enough to load the
# extension; we reach `execute`/`lastrowid` through it.
using SQLite: SQLite, DB
using SQLite.DBInterface: execute, lastrowid
using Serialization: serialize, deserialize
using Dates: Dates, DateTime
using BiTemporalData: SQLiteStore, Record, MAX_DT
import BiTemporalData: get_records, put_record!, close_tx!, entities

# Generic (de)serialization of keys and values to/from SQLite BLOBs.
_blob(x) = (io = IOBuffer(); serialize(io, x); take!(io))
_unblob(b) = deserialize(IOBuffer(b))

# All four times are `DateTime`, stored as their integer `Dates.value`.
_dt(n) = DateTime(Dates.UTM(n))

# --- constructors ---------------------------------------------------------

function SQLiteStore{K, V}(db::DB; table::AbstractString = "records") where {K, V}
    # `table` is developer-controlled, so interpolating it is safe; all data is
    # bound as parameters.
    execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS $table (
            id INTEGER PRIMARY KEY,
            key BLOB NOT NULL,
            value BLOB NOT NULL,
            valid_from INTEGER NOT NULL,
            valid_to INTEGER NOT NULL,
            tx_from INTEGER NOT NULL,
            tx_to INTEGER NOT NULL
        )
        """,
    )
    execute(db, "CREATE INDEX IF NOT EXISTS idx_$(table)_key ON $table (key)")
    return SQLiteStore{K, V, typeof(db)}(db, String(table))
end

function SQLiteStore{K, V}(path::AbstractString; table::AbstractString = "records") where {K, V}
    return SQLiteStore{K, V}(DB(path); table)
end

# --- primitives -----------------------------------------------------------

function put_record!(s::SQLiteStore{K, V}, key, r::Record{V}) where {K, V}
    res = execute(
        s.db,
        "INSERT INTO $(s.table) (key, value, valid_from, valid_to, tx_from, tx_to) " *
            "VALUES (?, ?, ?, ?, ?, ?)",
        (
            # Normalize the key to `K` first: serialization is type-sensitive, so
            # the blob must not depend on the caller's concrete argument type
            # (e.g. an `InlineString` from CSV vs a `String`).
            _blob(convert(K, key)), _blob(r.value),
            Dates.value(r.valid_from), Dates.value(r.valid_to),
            Dates.value(r.tx_from), Dates.value(r.tx_to),
        ),
    )
    id = lastrowid(res)
    return Record{V}(id, r.value, r.valid_from, r.valid_to, r.tx_from, r.tx_to)
end

function get_records(s::SQLiteStore{K, V}, key) where {K, V}
    out = Record{V}[]
    for row in execute(
            s.db,
            "SELECT id, value, valid_from, valid_to, tx_from, tx_to " *
                "FROM $(s.table) WHERE key = ? ORDER BY id",
            (_blob(convert(K, key)),),
        )
        push!(
            out,
            Record{V}(
                row.id, _unblob(row.value),
                _dt(row.valid_from), _dt(row.valid_to),
                _dt(row.tx_from), _dt(row.tx_to),
            ),
        )
    end
    return out
end

function close_tx!(s::SQLiteStore, id, ts::DateTime)
    # Idempotent: the `tx_to = MAX_DT` guard means a second call matches no rows.
    execute(
        s.db,
        "UPDATE $(s.table) SET tx_to = ? WHERE id = ? AND tx_to = ?",
        (Dates.value(ts), id, Dates.value(MAX_DT)),
    )
    return nothing
end

function entities(s::SQLiteStore{K, V}) where {K, V}
    return K[_unblob(row.key) for row in execute(s.db, "SELECT DISTINCT key FROM $(s.table)")]
end

end # module
